// Snarf JS shim — the single, hand-written boundary between the browser and the
// WASM module (S-06 §4). It instantiates snarf.wasm, verifies the ABI version,
// calls init(), drives tick() from requestAnimationFrame, and forwards raw input
// events into the module via the pushEvent export (R-P6-10). The device import
// surface fills in per S-06 §4 as devices land; phase 5 wired the pixel path
// (env.blit) + diagnostics (env.consoleLog); phase 6 adds input capture; phase 12
// adds the `ws` trio that carries 9P to the origin (R-P12-2).

// ABI generation this shim mirrors; must equal src/shim/abi.zig `version` and
// the module's exported abi_version() (checked below). 3→4 this phase (R-P12-2).
// Drift becomes a build error once the generated checksum lands (OQ-BLD-2).
const ABI_VERSION = 4;

// EventKind, a MECHANICAL mirror of src/shim/abi.zig `EventKind` (R-P6-10). All
// input POLICY stays in Zig (ADR-0004); this shim only transliterates and tags.
const EK = {
  pointer_down: 1,
  pointer_up: 2,
  pointer_move: 3,
  wheel: 4,
  key: 5,
  mod_down: 6,
  mod_up: 7,
};

// Modifier id, mirror of dev/profiles.zig `Mod` (enum(u8){alt,meta,ctrl,shift}).
const MOD_ID = { Alt: 0, Meta: 1, Control: 2, Shift: 3 };

// WS_KIND, a MECHANICAL mirror of src/shim/abi.zig `WsKind` (R-P12-2) — the tag
// on every inbound record handed to the module's wsPush export. Zig spells the
// last one `err` (keyword); only the integers must agree.
const WS_KIND = { open: 1, data: 2, close: 3, error: 4 };

// KEYRUNE — a MECHANICAL mirror of the 4e keyboard.h special-key block (device
// authority per R-P6-7 / the devinput side contract). DOM `KeyboardEvent.key`
// string → Plan 9 rune. Printable keys are NOT in the table: they fall through
// to codePointAt below. Note Kdown = 0xF800 (R-P6-7, NOT p9p's 0x80).
const KF = 0xf000;
const KEYRUNE = {
  ArrowUp: 0xf00e, // Kup
  ArrowDown: 0xf800, // Kdown (R-P6-7)
  ArrowLeft: 0xf011, // Kleft
  ArrowRight: 0xf012, // Kright
  Home: 0xf00d, // Khome
  End: 0xf018, // Kend
  PageUp: 0xf00f, // Kpgup
  PageDown: 0xf013, // Kpgdown
  Insert: 0xf014, // Kins
  Delete: 0x7f, // Kdel
  Escape: 0x1b, // Kesc
  Backspace: 0x08, // Kbs
  Enter: 0x0a, // '\n'
  Tab: 0x09, // '\t'
  F1: KF + 1,
  F2: KF + 2,
  F3: KF + 3,
  F4: KF + 4,
  F5: KF + 5,
  F6: KF + 6,
  F7: KF + 7,
  F8: KF + 8,
  F9: KF + 9,
  F10: KF + 10,
  F11: KF + 11,
  F12: KF + 12,
};

// Set once the module is instantiated; every env callback re-reads it because the
// backing ArrayBuffer detaches whenever wasm linear memory grows (R-P5-1).
let memory;

const canvas = document.getElementById("screen");
const ctx = canvas.getContext("2d");

const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

// Live 9P sockets by connection id (R-P12-2). One entry per wsOpen; removed on
// close so a superseded socket's late events are dropped (see wsAlive).
const sockets = new Map();

// Shared empty payload for records that carry none (the open record).
const EMPTY_BYTES = new Uint8Array(0);

// Installed at boot from the module's wsStage/wsPush exports; stays null when
// the module predates them, which disables the ws imports entirely (the origin
// mount is then simply absent — R-P12-5's tolerance, seen from this side).
let wsPushRecord = null;

// Diagnostics in the same voice as the module's consoleLog import.
function warn(...args) {
  console.warn("[snarf]", ...args);
}

// The 9P endpoint, same-origin ONLY (R-P12-1/R-9P-15): scheme from the page's
// protocol, host verbatim, path /9p. The module never sees a URL and has no
// override knob — a third-party endpoint would be someone else's namespace.
function wsUrl() {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${location.host}/9p`;
}

// True while `sock` is still the socket registered for `id`. A Reconnect
// (R-P12-7) may have dialed a replacement; the old socket's trailing onclose
// must not be reported against the new connection.
function wsAlive(id, sock) {
  return sockets.get(id) === sock;
}

// Push one inbound record into the module: stage the bytes into wasm memory via
// wsStage, then hand the module the pointer (R-P12-2). wsPush only queues — the
// module drains on tick() — so there is no JS→WASM re-entrancy here.
function pushWs(id, kind, bytes) {
  if (!wsPushRecord) return;
  wsPushRecord(id, kind, bytes);
}

// Same, for the short human-readable reason on a close/error record.
function pushWsText(id, kind, text) {
  pushWs(id, kind, textEncoder.encode(text));
}

const imports = {
  env: {
    // Present a dirty rect of the framebuffer (R-P5-4/R-P5-7). `ptr` addresses
    // RGBA8888 pixels covering the whole fbW×fbH display; (x,y,w,h) is the damage
    // rect. A fresh view per call — the old buffer detaches on memory growth. The
    // display is XRGB32 with A=0xFF, so premultiplied == straight and the bytes go
    // to putImageData verbatim (byte-exact). NB: ImageData rejects a shared buffer,
    // fine on the phase-5 main thread (R-P5-2).
    blit(ptr, fbW, fbH, x, y, w, h) {
      const pixels = new Uint8ClampedArray(memory.buffer, ptr, fbW * fbH * 4);
      const img = new ImageData(pixels, fbW, fbH);
      ctx.putImageData(img, 0, 0, x, y, w, h);
    },
    // Diagnostics from the module (R-P5-6): decode a UTF-8 string from wasm memory.
    consoleLog(ptr, len) {
      const bytes = new Uint8Array(memory.buffer, ptr, len);
      console.log("[snarf]", textDecoder.decode(bytes));
    },

    // Dial the origin's 9P endpoint as connection `id` (R-P12-2). No URL crosses
    // the ABI: this side derives it (R-P12-1). Returns immediately — boot never
    // waits on the socket (R-P12-5); the module learns the outcome from the
    // open/close/error record.
    wsOpen(id) {
      if (!wsPushRecord) {
        warn("ws: module has no wsStage/wsPush exports — origin mount disabled");
        return;
      }
      // A redial on a live id supersedes the old socket (R-P12-7 normally closes
      // it first); drop it silently rather than leak it with stale handlers.
      imports.env.wsClose(id);
      let sock;
      try {
        sock = new WebSocket(wsUrl());
      } catch (err) {
        pushWsText(id, WS_KIND.error, `dial failed: ${err}`);
        return;
      }
      // Binary only: a 9P frame is bytes, and a text frame is not 9P (R-P12-3).
      sock.binaryType = "arraybuffer";
      sockets.set(id, sock);

      sock.onopen = () => {
        if (wsAlive(id, sock)) pushWs(id, WS_KIND.open, EMPTY_BYTES);
      };
      sock.onmessage = (e) => {
        if (!wsAlive(id, sock)) return;
        if (typeof e.data === "string") {
          // A text frame on the 9P socket is a protocol violation; report it and
          // let the module poison the connection (R-P12-3).
          pushWsText(id, WS_KIND.error, "text frame on a 9P socket");
          sockets.delete(id);
          sock.close();
          return;
        }
        // One binary message == exactly one 9P frame; the module checks size[4].
        pushWs(id, WS_KIND.data, new Uint8Array(e.data));
      };
      sock.onclose = (e) => {
        if (!wsAlive(id, sock)) return;
        sockets.delete(id);
        pushWsText(id, WS_KIND.close, `${e.code} ${e.reason || "closed"}`);
      };
      sock.onerror = () => {
        // onerror carries no detail by design (the browser hides the cause); a
        // close event follows, and the module ignores the second death.
        if (wsAlive(id, sock)) pushWsText(id, WS_KIND.error, "socket error");
      };
    },

    // Send one 9P frame as one binary WebSocket message (R-P12-3). The bytes are
    // copied out of wasm memory first: send() must never hold a view of a buffer
    // that detaches when linear memory grows (R-P5-1). A send on a dead or
    // not-yet-open socket is dropped — the module already has, or is about to
    // get, the close record that explains it.
    wsSend(id, ptr, len) {
      const sock = sockets.get(id);
      if (!sock || sock.readyState !== WebSocket.OPEN) return;
      sock.send(new Uint8Array(memory.buffer, ptr, len).slice());
    },

    // Close connection `id`. Idempotent; unknown ids are a no-op. The handlers
    // are detached first so the module gets no close record for a socket it
    // closed itself (and a Reconnect's fresh socket is never confused for it).
    wsClose(id) {
      const sock = sockets.get(id);
      if (!sock) return;
      sockets.delete(id);
      sock.onopen = null;
      sock.onmessage = null;
      sock.onclose = null;
      sock.onerror = null;
      try {
        sock.close();
      } catch (err) {
        warn("ws: close failed", err);
      }
    },
  },
};

// Device-space (x,y) from a pointer event, relative to the canvas top-left
// (getBoundingClientRect; DPR assumed 1 until canvasResize/DPR land — R-P5-3).
function xyOf(e) {
  const r = canvas.getBoundingClientRect();
  return { x: Math.round(e.clientX - r.left), y: Math.round(e.clientY - r.top) };
}

// Whole-ms timestamp for the mouse record's msec field.
function msecOf(e) {
  return Math.floor(e.timeStamp || 0) >>> 0;
}

// Pack the current modifier state into the dev/profiles.zig `Mods` bitfield
// (bit0 alt, bit1 meta, bit2 ctrl, bit3 shift).
function modsOf(e) {
  return (
    (e.altKey ? 1 : 0) |
    (e.metaKey ? 2 : 0) |
    (e.ctrlKey ? 4 : 0) |
    (e.shiftKey ? 8 : 0)
  );
}

// Wire every input listener to the module's pushEvent export (R-P6-10). Pointer
// events capture the pointer so a drag that leaves the canvas still streams;
// context menu / middle-click autoscroll / wheel are preventDefault'd so the
// browser never steals a gesture (the devinput side contract's shim sketch).
function installInput(pushEvent) {
  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    const p = xyOf(e);
    pushEvent(EK.pointer_down, p.x, p.y, e.button, msecOf(e));
    e.preventDefault();
  });
  canvas.addEventListener("pointerup", (e) => {
    const p = xyOf(e);
    pushEvent(EK.pointer_up, p.x, p.y, e.button, msecOf(e));
    e.preventDefault();
  });
  canvas.addEventListener("pointermove", (e) => {
    const p = xyOf(e);
    // The button index is irrelevant to a move (the device tracks held state);
    // pass 0 rather than the DOM's -1 for "no button changed".
    pushEvent(EK.pointer_move, p.x, p.y, e.button < 0 ? 0 : e.button, msecOf(e));
  });

  // preventDefaults: no context menu (B3), no middle-click autoscroll (B2), and
  // wheel must be non-passive to be cancellable (org is fixed — the module
  // ignores wheel, F-7, but the page must not scroll either).
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
  canvas.addEventListener("mousedown", (e) => {
    if (e.button === 1) e.preventDefault();
  });
  canvas.addEventListener("wheel", (e) => e.preventDefault(), {
    passive: false,
  });

  // Keyboard on window (the canvas is not focusable by default). A modifier key
  // itself becomes mod_down/up; every other key transliterates to a rune.
  window.addEventListener("keydown", (e) => {
    const mod = MOD_ID[e.key];
    if (mod !== undefined) {
      pushEvent(EK.mod_down, 0, 0, mod, msecOf(e));
      e.preventDefault();
      return;
    }
    let rune = KEYRUNE[e.key];
    if (rune === undefined) {
      // A single Unicode scalar (printable) maps to its code point; anything
      // else (e.g. "CapsLock", "F13") is not handled here.
      if ([...e.key].length === 1) rune = e.key.codePointAt(0);
      else return;
    }
    // Ctrl-letter folding: rune &= 0x1F for rune >= 0x40 (R-IN-10).
    if (e.ctrlKey && rune >= 0x40) rune &= 0x1f;
    pushEvent(EK.key, rune, 0, modsOf(e), msecOf(e));
    e.preventDefault();
  });
  window.addEventListener("keyup", (e) => {
    const mod = MOD_ID[e.key];
    if (mod !== undefined) {
      pushEvent(EK.mod_up, 0, 0, mod, msecOf(e));
      e.preventDefault();
    }
    // Non-modifier keyups are not forwarded: runes are edge-on-press.
  });
}

async function boot() {
  const resp = await fetch("./snarf.wasm");
  const { instance } = await WebAssembly.instantiateStreaming(resp, imports);
  const {
    memory: mem,
    abi_version,
    init,
    wake,
    tick,
    pushEvent,
    wsStage,
    wsPush,
  } = instance.exports;

  memory = mem;

  // Arm the inbound ws path only if the module exports both halves of the
  // staging pair (R-P12-2). Without them the env.ws* imports stay inert rather
  // than opening a socket nothing can read.
  if (typeof wsStage === "function" && typeof wsPush === "function") {
    wsPushRecord = (id, kind, bytes) => {
      const ptr = wsStage(bytes.length);
      if (!ptr) {
        // The module could not stage the record (no room). Dropping a 9P frame
        // desynchronizes the stream, so report the failure instead of hiding it.
        warn("ws: staging buffer unavailable, dropped a", kind, "record");
        return;
      }
      if (bytes.length > 0) {
        new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
      }
      wsPush(id, kind, ptr, bytes.length);
    };
  } else {
    warn("ws: module exports no wsStage/wsPush — no origin mount this boot");
  }

  // Verify the ABI contract BEFORE handing control to the module (R-P5-4).
  const moduleAbi = abi_version();
  if (moduleAbi !== ABI_VERSION) {
    throw new Error(
      `snarf: ABI mismatch — shim ${ABI_VERSION}, module ${moduleAbi}`,
    );
  }

  init();

  // Route browser input into the module (R-P6-10).
  installInput(pushEvent);

  // Frame pump; `wake` is reserved for the future Worker + inbound ring (R-P6-1).
  function frame(nowMs) {
    tick(Math.floor(nowMs) >>> 0);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  // Expose for console poking during bring-up.
  globalThis.snarf = { instance, wake, pushEvent, ABI_VERSION };
}

boot().catch((err) => {
  console.error("snarf: boot failed", err);
});

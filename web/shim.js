// Snarf JS shim — the single, hand-written boundary between the browser and the
// WASM module (S-06 §4). It instantiates snarf.wasm, verifies the ABI version,
// calls init(), drives tick() from requestAnimationFrame, and forwards raw input
// events into the module via the pushEvent export (R-P6-10). The device import
// surface fills in per S-06 §4 as devices land; phase 5 wired the pixel path
// (env.blit) + diagnostics (env.consoleLog); phase 6 adds input capture.

// ABI generation this shim mirrors; must equal src/shim/abi.zig `version` and
// the module's exported abi_version() (checked below). 2→3 this phase (R-P6-10).
// Drift becomes a build error once the generated checksum lands (OQ-BLD-2).
const ABI_VERSION = 3;

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
  const { memory: mem, abi_version, init, wake, tick, pushEvent } =
    instance.exports;

  memory = mem;

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

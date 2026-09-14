// smoke_wasm.mjs — MANUAL dev tool (R-P5-9). NEVER wired into `zig build`
// (R-BLD-02 stays intact); node is not a build dependency (ADR-0001). Run it by
// hand after `zig build`:
//
//     zig build && node tools/smoke_wasm.mjs
//
// It instantiates zig-out/www/snarf.wasm with a headless mirror of the shim env
// (R-P5-7: env.consoleLog(ptr,len) + env.blit(ptr,fbW,fbH,x,y,w,h)), drives the
// init(w,h)/tick/wake lifecycle, and asserts the boot rendered the phase-4 demo
// scene (R-P5-8) all the way to a blit — reading pixels straight out of wasm
// memory — then that a resize event re-sizes the display and repaints it whole.
// Any env import the module needs beyond those two is auto-stubbed (warn+record)
// so a link failure surfaces as a readable message, not a cryptic LinkError.
//
// NOTE: with B1's real dev/draw_canvas.zig absent, a placeholder backend that
// does NOT blit is in play; the blit/pixel assertions are expected to report
// "pending B1 merge" until the pixel path lands.
//
// Phase 14b adds a THIRD instance with a real env.fsOp: an in-memory filesystem
// speaking the ABI-v6 op-record contract, driven through the user's own route
// (B3 on `mnt/`, then on `opfs/`, then on a file) so the whole path — fsOp out,
// fsStage/fsPush back, 9P requests parked and retried — runs in the real wasm.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
// The shim's own OPFS record codec (phase 14b). Importing it here is half the
// test: the smoke's in-memory backend decodes with the SAME code the browser
// runs, so a drift between web/opfs.js and src/shim/FsRecord.zig shows up as a
// failed op rather than as a silent mismatch in production.
import { decodeRecord, FS_OP, FS_STATUS, FS_OP_VERSION } from "../web/opfs.js";

const WASM_PATH = fileURLToPath(new URL("../zig-out/www/snarf.wasm", import.meta.url));
const ORIGIN_BIN = fileURLToPath(new URL("../zig-out/bin/snarf-origin", import.meta.url));
const EXPECT_ABI = 6; // R-P14b-6: 5 -> 6 (env.fsOp + fsStage/fsPush).
// The boot display size, passed to init(w, h). Deliberately NOT 640×480: the
// module carries no size of its own any more (the R-P5-3 constants are gone), so
// booting at 800×600 proves the caller's numbers are honoured. The frozen
// acceptance goldens are unaffected — they build their own 640×480 headless
// backends in src/accept.zig (R-P12c-3).
const FB_W = 800;
const FB_H = 600;
// Where the resize event (EventKind.resize = 8) moves the display to.
const RESIZE_W = 1024;
const RESIZE_H = 768;

// ---- recording env -------------------------------------------------------

const logs = [];
const blits = [];
let memory = null; // set from exports after instantiation.

const decoder = new TextDecoder();
function decode(ptr, len) {
  return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
}

// Real handlers for the two known imports; everything else is auto-stubbed.
const knownEnv = {
  consoleLog(ptr, len) {
    const msg = decode(ptr, len);
    logs.push(msg);
    console.log("[snarf]", msg);
  },
  blit(ptr, fbW, fbH, x, y, w, h) {
    blits.push({ ptr, fbW, fbH, x, y, w, h });
  },
};

// Build the import object from the module's declared imports so unknown env
// functions get a warn+record stub instead of a LinkError (the "auto-stub loop").
// `extra` overrides/extends the known env for a specific instance (phase 12
// gives instance 2 real WebSocket-backed ws imports; instance 1 keeps stubs,
// which doubles as the R-P12-5 origin-absent boot).
function buildImports(module, extra = {}) {
  const env = { ...knownEnv, ...extra };
  const imports = {};
  for (const { module: mod, name, kind } of WebAssembly.Module.imports(module)) {
    imports[mod] ??= {};
    if (imports[mod][name] !== undefined) continue;
    if (mod === "env" && env[name]) {
      imports[mod][name] = env[name];
    } else if (kind === "function") {
      imports[mod][name] = (...args) => {
        console.warn(`[stub] ${mod}.${name}(${args.join(", ")})`);
        logs.push(`stub:${mod}.${name}`);
      };
    }
  }
  return imports;
}

// ---- assertion harness ---------------------------------------------------

const results = [];
function check(name, fn) {
  try {
    const r = fn();
    if (r === "pending") {
      results.push({ name, status: "PENDING" });
    } else {
      results.push({ name, status: r ? "PASS" : "FAIL" });
    }
  } catch (e) {
    results.push({ name, status: "FAIL", detail: String(e) });
  }
}

// Read a packed 0xRRGGBBAA pixel straight from wasm memory (RGBA8888 row-major).
function pixelAt(base, fbW, px, py) {
  const i = base + (py * fbW + px) * 4;
  const b = new Uint8Array(memory.buffer);
  return { r: b[i], g: b[i + 1], b: b[i + 2], a: b[i + 3] };
}

// ---- run -----------------------------------------------------------------

const bytes = await readFile(WASM_PATH);
const module = await WebAssembly.compile(bytes);
const instance = await WebAssembly.instantiate(module, buildImports(module));
const ex = instance.exports;
memory = ex.memory;

check("exports: memory/init/wake/tick present", () =>
  ex.memory instanceof WebAssembly.Memory &&
  typeof ex.init === "function" &&
  typeof ex.wake === "function" &&
  typeof ex.tick === "function");

check("exports: abi_version() present", () => typeof ex.abi_version === "function");

const abi = typeof ex.abi_version === "function" ? ex.abi_version() : undefined;
check(`abi_version() === ${EXPECT_ABI} (T14)`, () => abi === EXPECT_ABI);

let initTrapped = false;
const logsBeforeInit = logs.length;
try {
  ex.init(FB_W, FB_H); // ABI v5: the display size comes from the caller.
} catch (e) {
  initTrapped = true;
  console.error("init() trapped:", e);
}
const initLogs = logs.slice(logsBeforeInit);
check("init() returns without trap", () => !initTrapped);
check("init() logged no panic/failure", () =>
  !initLogs.some((m) => /panic|failed/i.test(m)));

check("blit called >= 1", () => (blits.length >= 1 ? true : "pending"));

const last = blits[blits.length - 1];
// The size handed to init() is the size that reaches the pixel path (R-GFX-05):
// the FIRST blit already reports it, so nothing downstream carries a size of its
// own.
check(`first blit fbW===${FB_W} && fbH===${FB_H}`, () =>
  blits[0] ? blits[0].fbW === FB_W && blits[0].fbH === FB_H : "pending");

check(`last blit fbW===${FB_W} && fbH===${FB_H}`, () =>
  last ? last.fbW === FB_W && last.fbH === FB_H : "pending");

check("dirty rect within framebuffer bounds", () =>
  last
    ? last.x >= 0 && last.y >= 0 && last.x + last.w <= last.fbW && last.y + last.h <= last.fbH
    : "pending");

// Phase 6: the boot scene is the acme-ivory ground fill over the whole
// display (empty buffer) — the initial damage covers the full surface.
check("dirty rect covers the full display", () =>
  last
    ? last.x === 0 && last.y === 0 && last.w === FB_W && last.h === FB_H
    : "pending");

check("blit ptr + fbW*fbH*4 <= memory size", () =>
  last ? last.ptr + last.fbW * last.fbH * 4 <= memory.buffer.byteLength : "pending");

check("pixel (0,0) is the row-tag pale blue (0xEAFFFF)", () => {
  if (!last) return "pending";
  const p = pixelAt(last.ptr, last.fbW, 0, 0);
  return p.r === 234 && p.g === 255 && p.b === 255;
});

// Phase 13b boot layout (acme.c:242-260): TWO columns, the left one EMPTY and
// the `/` directory window in the RIGHT one. `rowadd` steals 3/5 of the last
// column (rows.c:60-63), so at 800 px the right column starts at x = 480 and
// its only window's body frame starts at 480 + Scrollwid(12) + Scrollgap(4) =
// 496; the window's first body line runs y 59..77 (row tag 18 + border, column
// tag 18 + border, window tag 18, divider 1).
const BODY_X0 = 496, BODY_X1 = 795, BODY_Y0 = 56, BODY_Y1 = 240;
const BODY_PT = { x: 560, y: 66 }; // inside the right window's FIRST body line
// Where a command is typed and B2'd. The LEFT column's tag: it is the one
// surface whose geometry never moves — the left column stays empty (warnings
// mint `+Errors` in the RIGHTMOST column, util.c:98) and a column tag is never
// recomposed. Its caret already sits at the end of
// "New Cut Paste Snarf Sort Zerox Delcol " (38 runes, cols.c:46-47), so a typed
// word lands at x = 16 (Scrollwid+Scrollgap) + 38*9 = 358, delimited by the
// space after "Delcol". Typing into the `/` window's body instead would merge
// the word with the neighbouring `mnt/`, every rune of which is `isfilec`
// (look.c:442-450); and a directory window shrinks to its content
// (cols.c:117), so its body is only two lines tall once `+Errors` appears.
const COLTAG_PT = { x: 400, y: 28 };   // inside the left column tag, past its text
const COLTAG_WORD_X = 368;             // 2nd rune of a word typed at the caret

function bodyInk(b) {
  if (!b) return -1;
  let n = 0;
  for (let y = BODY_Y0; y < BODY_Y1; y++) {
    for (let x = BODY_X0; x < BODY_X1; x++) {
      const p = pixelAt(b.ptr, b.fbW, x, y);
      if (p.r === 0 && p.g === 0 && p.b === 0) n++;
    }
  }
  return n;
}

// Let the boot directory load finish: it is an `Editor.loads` job advanced ONE
// 9P state per frame (13b), so the `/` listing needs a handful of ticks.
for (let i = 0; i < 16; i++) ex.tick(100 + i * 16);
check("boot: the `/` directory window drew text in the right column (13b) (T15)", () =>
  bodyInk(blits[blits.length - 1]) > 0);

// Phase 6 end-to-end: inject a typed 'h' through the real input path
// (pushEvent -> devinput -> parked 9P read -> Editor -> Text -> frame -> blit)
// and watch the body region gain ink.
const blitsBefore = blits.length;
const inkBefore = bodyInk(blits[blits.length - 1]);
// Point-to-type (R-P8-9): position the pointer inside the window BODY first.
ex.pushEvent(3 /* pointer_move */, BODY_PT.x, BODY_PT.y, 0, 900);
ex.tick(8);
ex.pushEvent(5 /* key */, 0x68 /* 'h' */, 0, 0, 1000);
ex.tick(16);
check("typed key produced a new blit", () => blits.length > blitsBefore);
check("typed rune added ink somewhere in the body region", () => {
  const b = blits[blits.length - 1];
  if (!b) return "pending";
  return bodyInk(b) > inkBefore;
});

// R-GFX-05: a resize event re-sizes the framebuffer and repaints EVERYTHING —
// the browser clears the canvas when the backing store changes, so a partial
// damage rect would leave the rest of the window blank.
const blitsBeforeResize = blits.length;
let resizeTrapped = false;
try {
  ex.pushEvent(8 /* resize */, RESIZE_W, RESIZE_H, 0, 1100);
  ex.tick(1116);
} catch (e) {
  resizeTrapped = true;
  console.error("resize event trapped:", e);
}
check("resize event handled without trap", () => !resizeTrapped);

const afterResize = blits.slice(blitsBeforeResize);
check(`resize produced a blit at ${RESIZE_W}x${RESIZE_H}`, () =>
  afterResize.some((b) => b.fbW === RESIZE_W && b.fbH === RESIZE_H));

check("resize blit covers the full new display", () => {
  const b = afterResize.find((x) => x.fbW === RESIZE_W && x.fbH === RESIZE_H);
  if (!b) return false;
  return b.x === 0 && b.y === 0 && b.w === RESIZE_W && b.h === RESIZE_H;
});

check("resized display still draws the row-tag pale blue at (0,0)", () => {
  const b = afterResize.find((x) => x.fbW === RESIZE_W && x.fbH === RESIZE_H);
  if (!b) return false;
  const p = pixelAt(b.ptr, b.fbW, 0, 0);
  return p.r === 234 && p.g === 255 && p.b === 255;
});

let pumpTrapped = false;
try {
  ex.tick(16);
  ex.tick(32);
  ex.wake();
} catch (e) {
  pumpTrapped = true;
  console.error("tick/wake trapped:", e);
}
check("tick(16)/tick(32)/wake() no trap", () => !pumpTrapped);

// Phase 13a (contract §3d): the boot namespace now mounts /dev, /dev/draw and a
// LIVE in-process /mnt/snarf-self server that `tick` polls every frame. A long
// run of ticks must still trap nothing, log no panic, and leave the ABI surface
// exactly where it was (no export change this wave, R-P13a-5).
let nsTrapped = false;
const logsBeforeNsTicks = logs.length;
try {
  for (let i = 0; i < 60; i++) ex.tick(48 + i * 16);
} catch (e) {
  nsTrapped = true;
  console.error("boot-namespace tick trapped:", e);
}
check("boot namespace: 60 ticks poll the served tree without trapping (T12)", () => !nsTrapped);
check("boot namespace: those ticks logged no panic/failure (T12)", () =>
  !logs.slice(logsBeforeNsTicks).some((m) => /panic|failure/i.test(m)));
check(`boot namespace: exports unchanged (abi_version() still ${EXPECT_ABI}) (T12)`, () =>
  ex.abi_version() === EXPECT_ABI &&
  typeof ex.init === "function" &&
  typeof ex.tick === "function" &&
  typeof ex.wake === "function" &&
  typeof ex.pushEvent === "function");

// Phase 12, R-P12-5: with the ws imports stubbed the dial never completes;
// crossing the 10 s dial deadline must warn-and-carry-on, never trap.
let timeoutTrapped = false;
try {
  ex.tick(15_000);
  ex.tick(15_016);
} catch (e) {
  timeoutTrapped = true;
  console.error("origin-absent timeout tick trapped:", e);
}
check("origin absent: 10s dial timeout crossed without trap", () => !timeoutTrapped);

// ---- phase 12: /n/origin against a real snarf-origin --------------------
//
// Spawns zig-out/bin/snarf-origin (its port is baked by `zig build -Dport=`;
// the banner is parsed for the actual value — if the port is busy, e.g. your
// dev server is running, these checks report PENDING, not FAIL). A SECOND
// module instance gets real WebSocket-backed ws imports and we assert, via
// the wire frames and the server's own access log: version+attach round-trip
// and the mount handshake completes; a server kill is survived; after a
// restart, executing `Reconnect` through real injected input (typed word +
// B2 click) re-attaches. Reads of origin FILES are next wave (needs the async
// RPC ticket API — see the phase-12 contract gaps).

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function startOrigin() {
  const child = spawn(ORIGIN_BIN, [], { stdio: ["ignore", "pipe", "pipe"] });
  const out = { child, lines: [], port: 0, dead: false };
  let buf = "";
  child.stdout.on("data", (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      out.lines.push(buf.slice(0, i));
      buf = buf.slice(i + 1);
    }
  });
  child.on("exit", () => (out.dead = true));
  return out;
}

async function waitLine(srv, re, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const hit = srv.lines.find((l) => re.test(l));
    if (hit) return hit;
    if (srv.dead && !srv.lines.length) return null;
    await sleep(50);
  }
  return null;
}

let srv = startOrigin();
const banner = await waitLine(srv, /snarf-origin: http:\/\/127\.0\.0\.1:(\d+)\//, 3000);
const originUp = banner !== null && !srv.dead;
if (originUp) srv.port = Number(banner.match(/:(\d+)\//)[1]);

if (!originUp) {
  try { srv.child.kill(); } catch {}
  for (const name of [
    "origin: server spawned", "origin: Tversion+Tattach sent on the wire",
    "origin: server log shows 9p attach", "origin: server kill survived",
    "origin: Reconnect re-attached on restarted server",
  ]) check(name, () => "pending");
  console.warn("[origin] snarf-origin did not start (port busy?) — origin checks PENDING");
} else {
  check("origin: server spawned", () => true);

  // Real ws env for instance 2. `portBox` so a restarted server (new port
  // resolution is the same baked port) is dialed by Reconnect's fresh id.
  const portBox = { port: srv.port };
  const sentTypes = [];
  let ex2 = null;
  const sockets = new Map();
  function push2(id, kind, bytes) {
    if (!ex2) return;
    const ptr = bytes.length ? ex2.wsStage(bytes.length) : ex2.wsStage(0);
    if (bytes.length) {
      if (ptr === 0) return console.warn("[origin] wsStage refused", bytes.length);
      new Uint8Array(ex2.memory.buffer, ptr, bytes.length).set(bytes);
    }
    ex2.wsPush(id, kind, ptr, bytes.length);
  }
  const wsEnv = {
    wsOpen(id) {
      const sock = new WebSocket(`ws://127.0.0.1:${portBox.port}/9p`);
      sock.binaryType = "arraybuffer";
      sockets.set(id, sock);
      sock.onopen = () => sockets.get(id) === sock && push2(id, 1, new Uint8Array(0));
      sock.onmessage = (e) => sockets.get(id) === sock && push2(id, 2, new Uint8Array(e.data));
      sock.onclose = () => sockets.get(id) === sock && push2(id, 3, new Uint8Array(0));
      sock.onerror = () => sockets.get(id) === sock && push2(id, 4, new Uint8Array(0));
    },
    wsSend(id, ptr, len) {
      const bytes = ex2.memory.buffer.slice(ptr, ptr + len);
      sentTypes.push(new Uint8Array(bytes)[4]); // 9P type byte
      sockets.get(id)?.send(bytes);
    },
    wsClose(id) {
      const sock = sockets.get(id);
      sockets.delete(id);
      try { sock?.close(); } catch {}
    },
  };

  const inst2 = await WebAssembly.instantiate(module, buildImports(module, wsEnv));
  ex2 = inst2.exports;
  memory = ex2.memory; // decode()/pixelAt() now read instance 2.
  ex2.init(FB_W, FB_H);

  // Pump: the socket connects on the JS event loop, so alternate ticks/sleeps.
  let now = 100;
  for (let i = 0; i < 60 && !srv.lines.some((l) => l.includes("9p attach /")); i++) {
    ex2.tick((now += 16));
    await sleep(50);
  }
  check("origin: Tversion+Tattach sent on the wire", () =>
    sentTypes.includes(100) && sentTypes.includes(104));
  check("origin: server log shows 9p attach", () =>
    srv.lines.some((l) => l.includes("9p attach /")));

  // The `binding` phase's Twalk("bin")/Rwalk round-trip follows attach in the
  // same handshake; give it a few more ticks before asserting the module
  // logged the mount at its new (T16, phase 12d) mount point — pollOrigin in
  // src/main_wasm.zig.
  for (let i = 0; i < 40 && !logs.includes("/n/origin: mounted"); i++) {
    ex2.tick((now += 16));
    await sleep(50);
  }
  check("origin: console logs '/n/origin: mounted' (T16)", () =>
    logs.includes("/n/origin: mounted"));

  // Kill the server: the close record must be absorbed without a trap.
  srv.child.kill("SIGKILL");
  await sleep(300);
  let killTrapped = false;
  try {
    ex2.tick((now += 16));
    ex2.tick((now += 16));
  } catch (e) {
    killTrapped = true;
    console.error("post-kill tick trapped:", e);
  }
  check("origin: server kill survived", () => !killTrapped);

  // Restart, then execute `Reconnect` the way a user does: point-to-type in
  // the body, type the word, B2-click (button 1) inside it (R-P12-7).
  srv = startOrigin();
  const banner2 = await waitLine(srv, /snarf-origin: http:\/\/127\.0\.0\.1:(\d+)\//, 3000);
  if (banner2) portBox.port = Number(banner2.match(/:(\d+)\//)[1]);

  // Let this instance's own boot directory load settle first (13b).
  for (let i = 0; i < 16; i++) ex2.tick((now += 16));
  // Point-to-type into the LEFT column's tag (its caret already sits at the
  // end, cols.c:46-47 — no B1 needed), then B2 the typed word, exactly as a
  // user executes a command from a tag.
  ex2.pushEvent(3 /* pointer_move */, COLTAG_PT.x, COLTAG_PT.y, 0, (now += 16));
  ex2.tick((now += 16));
  for (const ch of "Reconnect") {
    ex2.pushEvent(5 /* key */, ch.codePointAt(0), 0, 0, (now += 16));
    ex2.tick((now += 16));
  }
  ex2.pushEvent(1 /* pointer_down */, COLTAG_WORD_X, COLTAG_PT.y, 1 /* B2 */, (now += 16));
  ex2.tick((now += 16));
  ex2.pushEvent(2 /* pointer_up */, COLTAG_WORD_X, COLTAG_PT.y, 1, (now += 16));
  ex2.tick((now += 16));
  for (let i = 0; i < 60 && !srv.lines.some((l) => l.includes("9p attach /")); i++) {
    ex2.tick((now += 16));
    await sleep(50);
  }
  check("origin: Reconnect re-attached on restarted server", () =>
    banner2 !== null && srv.lines.some((l) => l.includes("9p attach /")));

  for (const [, sock] of sockets) { try { sock.close(); } catch {} }
  try { srv.child.kill(); } catch {}
}


// ---- phase 14b: /mnt/opfs against an in-memory fsOp stub -----------------
//
// A THIRD module instance with a real env.fsOp: a tiny in-memory filesystem
// that speaks the op-record contract (src/shim/FsRecord.zig, mirrored in
// web/opfs.js, whose decoder this reuses). It proves the whole ABI-v6 path
// through the real wasm — fsOp out, fsStage/fsPush back, parked 9P ops retried
// — and that the mount is LAZY: booting touches OPFS not at all.
//
// The op log is one line per request, in arrival order:
//     "stat /"  "list /"  "read /notes.txt@0+8168"  "write /f@12+5"
//     "create_file /f"  "create_dir /d"  "remove /f"  "truncate /f@0"
// i.e. `<op> <path>` plus `@<arg0>+<count>` for the three that carry one.

function makeFsStub() {
  const enc = new TextEncoder();
  // path -> { dir, data, mtime }. "/" always exists.
  const files = new Map([["/", { dir: true, data: null, mtime: 0 }]]);
  const ops = [];
  const queued = [];
  let ex = null;

  const dirOf = (p) => {
    const i = p.lastIndexOf("/");
    return i <= 0 ? "/" : p.slice(0, i);
  };
  const baseOf = (p) => p.slice(p.lastIndexOf("/") + 1);

  function statPayload(node) {
    const out = new Uint8Array(17);
    const dv = new DataView(out.buffer);
    dv.setUint8(0, node.dir ? 1 : 0);
    dv.setBigUint64(1, BigInt(node.dir ? 0 : node.data.length), true);
    dv.setBigUint64(9, BigInt(node.mtime || 0), true);
    return out;
  }

  function listPayload(path) {
    const kids = [];
    for (const [p, n] of files) {
      if (p !== "/" && dirOf(p) === path) {
        kids.push({ b: enc.encode(baseOf(p)), dir: n.dir });
      }
    }
    let total = 0;
    for (const k of kids) total += 3 + k.b.length;
    const out = new Uint8Array(total);
    const dv = new DataView(out.buffer);
    let o = 0;
    for (const k of kids) {
      dv.setUint8(o, k.dir ? 1 : 0);
      dv.setUint16(o + 1, k.b.length, true);
      out.set(k.b, o + 3);
      o += 3 + k.b.length;
    }
    return out;
  }

  function perform(rec) {
    const node = files.get(rec.path);
    switch (rec.op) {
      case FS_OP.stat:
        return node
          ? { status: FS_STATUS.ok, payload: statPayload(node) }
          : { status: FS_STATUS.not_found, payload: new Uint8Array(0) };
      case FS_OP.list:
        if (!node) return { status: FS_STATUS.not_found, payload: new Uint8Array(0) };
        if (!node.dir) return { status: FS_STATUS.not_dir, payload: new Uint8Array(0) };
        return { status: FS_STATUS.ok, payload: listPayload(rec.path) };
      case FS_OP.read: {
        if (!node) return { status: FS_STATUS.not_found, payload: new Uint8Array(0) };
        if (node.dir) return { status: FS_STATUS.is_dir, payload: new Uint8Array(0) };
        const off = Number(rec.arg0);
        return {
          status: FS_STATUS.ok,
          payload: node.data.subarray(Math.min(off, node.data.length), Math.min(off + rec.arg1, node.data.length)),
        };
      }
      case FS_OP.write: {
        if (!node || node.dir) return { status: FS_STATUS.io, payload: new Uint8Array(0) };
        const off = Number(rec.arg0);
        const end = Math.max(node.data.length, off + rec.payload.length);
        const grown = new Uint8Array(end);
        grown.set(node.data);
        grown.set(rec.payload, off);
        node.data = grown;
        const out = new Uint8Array(4);
        new DataView(out.buffer).setUint32(0, rec.payload.length, true);
        return { status: FS_STATUS.ok, payload: out };
      }
      case FS_OP.create_file:
      case FS_OP.create_dir:
        if (files.has(rec.path)) return { status: FS_STATUS.exists, payload: new Uint8Array(0) };
        files.set(rec.path, {
          dir: rec.op === FS_OP.create_dir,
          data: rec.op === FS_OP.create_dir ? null : new Uint8Array(0),
          mtime: 0,
        });
        return { status: FS_STATUS.ok, payload: new Uint8Array(0) };
      case FS_OP.remove:
        if (!node) return { status: FS_STATUS.not_found, payload: new Uint8Array(0) };
        for (const p of files.keys()) {
          if (p !== rec.path && dirOf(p) === rec.path) {
            return { status: FS_STATUS.not_empty, payload: new Uint8Array(0) };
          }
        }
        files.delete(rec.path);
        return { status: FS_STATUS.ok, payload: new Uint8Array(0) };
      case FS_OP.truncate: {
        if (!node || node.dir) return { status: FS_STATUS.io, payload: new Uint8Array(0) };
        const n = Number(rec.arg0);
        const grown = new Uint8Array(n);
        grown.set(node.data.subarray(0, Math.min(n, node.data.length)));
        node.data = grown;
        return { status: FS_STATUS.ok, payload: new Uint8Array(0) };
      }
      // Record version 2: "that write sequence is over". This stub holds no
      // writable stream, so it is a no-op that only has to be accepted.
      case FS_OP.close:
        return { status: FS_STATUS.ok, payload: new Uint8Array(0) };
      default:
        return { status: FS_STATUS.io, payload: new Uint8Array(0) };
    }
  }

  function label(rec) {
    const name = Object.keys(FS_OP).find((k) => FS_OP[k] === rec.op) || `op${rec.op}`;
    if (rec.op === FS_OP.read) return `${name} ${rec.path}@${rec.arg0}+${rec.arg1}`;
    if (rec.op === FS_OP.write) return `${name} ${rec.path}@${rec.arg0}+${rec.payload.length}`;
    if (rec.op === FS_OP.truncate) return `${name} ${rec.path}@${rec.arg0}`;
    return `${name} ${rec.path}`;
  }

  return {
    files,
    ops,
    bind(exports) { ex = exports; },
    // env.fsOp: decode, log, and QUEUE the answer — never complete inside the
    // call (the module's no-re-entrancy rule, contract §3a).
    fsOp(ptr, len, ticket) {
      const bytes = new Uint8Array(ex.memory.buffer, ptr, len).slice();
      const rec = decodeRecord(bytes);
      if (!rec) {
        queued.push({ ticket, status: FS_STATUS.io, payload: new Uint8Array(0) });
        return;
      }
      ops.push(label(rec));
      const { status, payload } = perform(rec);
      queued.push({ ticket, status, payload });
    },
    // Deliver every queued completion. fsPush retries parked requests, which
    // may issue NEW fsOps, so loop until the queue settles.
    drain() {
      for (let guard = 0; guard < 64 && queued.length > 0; guard++) {
        const batch = queued.splice(0, queued.length);
        for (const c of batch) {
          const ptr = ex.fsStage(c.payload.length);
          if (!ptr) throw new Error("fsStage refused " + c.payload.length);
          if (c.payload.length > 0) {
            new Uint8Array(ex.memory.buffer, ptr, c.payload.length).set(c.payload);
          }
          ex.fsPush(c.ticket, c.status, ptr, c.payload.length);
        }
      }
    },
    seedFile(path, text) {
      this.files.set(path, { dir: false, data: new TextEncoder().encode(text), mtime: 1_700_000_000_000 });
    },
    seedDir(path) {
      this.files.set(path, { dir: true, data: null, mtime: 0 });
    },
  };
}

check(`opfs: web/opfs.js mirror is FS_OP_VERSION ${FS_OP_VERSION} with 9 ops / 9 statuses (T1)`, () =>
  FS_OP_VERSION === 2 &&
  Object.keys(FS_OP).length === 9 &&
  Object.keys(FS_STATUS).length === 9 &&
  FS_OP.stat === 1 && FS_OP.truncate === 8 && FS_OP.close === 9 &&
  FS_STATUS.ok === 0 && FS_STATUS.io === 8);

{
  const stub = makeFsStub();
  // Pre-seed the store: one file and one directory, so the first listing has
  // something to draw and the file has something to read.
  stub.seedFile("/notes.txt", "opfs round trip\n");
  stub.seedDir("/sub");

  const inst3 = await WebAssembly.instantiate(module, buildImports(module, {
    fsOp: (ptr, len, ticket) => stub.fsOp(ptr, len, ticket),
  }));
  const ex3 = inst3.exports;
  stub.bind(ex3);
  memory = ex3.memory; // decode()/pixelAt() now read instance 3.

  check("opfs: module exports fsStage/fsPush", () =>
    typeof ex3.fsStage === "function" && typeof ex3.fsPush === "function");

  ex3.init(FB_W, FB_H);
  let t3 = 100;
  // One "frame": deliver whatever the stub owes, then tick. fsPush retries the
  // parked 9P request, which may issue the NEXT fsOp, so drain loops.
  const step = (n) => {
    for (let i = 0; i < n; i++) {
      stub.drain();
      ex3.tick((t3 += 16));
    }
    stub.drain();
  };
  step(20);
  check("opfs: boot issues no fsOp — the mount is lazy (T13)", () => stub.ops.length === 0);

  // B3 (DOM button 2) on `mnt/` in the boot `/` listing, then on `opfs/` in the
  // window that opens, then on `notes.txt` in the window THAT opens: the user's
  // own route into the tree. Coordinates come from the 13b layout at 800x600 —
  // right column body x0 = 496, first body line y 59..77, 9 px font, directory
  // maxtab 27 — and from the same arithmetic applied to each new window, which
  // `rowadd`/`makenewwindow` stack down the right column at y 79, 118, 160.
  const B3 = 2;
  function look(x, y) {
    ex3.pushEvent(3 /* pointer_move */, x, y, 0, (t3 += 16));
    step(1);
    ex3.pushEvent(1 /* pointer_down */, x, y, B3, (t3 += 16));
    step(1);
    ex3.pushEvent(2 /* pointer_up */, x, y, B3, (t3 += 16));
    step(40);
  }
  function inkIn(b, x0, x1, y0, y1) {
    if (!b) return -1;
    let n = 0;
    for (let y = y0; y < y1; y++) {
      for (let x = x0; x < x1; x++) {
        const p = pixelAt(b.ptr, b.fbW, x, y);
        if (p.r === 0 && p.g === 0 && p.b === 0) n++;
      }
    }
    return n;
  }

  look(560, 66); // `mnt/` in the `/` listing: a namespace directory
  check("opfs: B3 on `mnt/` opens a window with NO fsOp (namespace synthesis)", () =>
    stub.ops.length === 0);

  look(500, 106); // `opfs/` in the `/mnt/` listing: into the device at last
  check("opfs: B3 on `opfs/` makes the device list its root (T13)", () =>
    stub.ops.includes("list /"));
  check("opfs: the /mnt/opfs/ window drew its listing", () =>
    inkIn(blits[blits.length - 1], 494, 660, 137, 155) > 0);

  look(520, 146); // `notes.txt` in the `/mnt/opfs/` listing: a FILE this time
  check("opfs: B3 on `notes.txt` reads the file through the device (T13)", () =>
    stub.ops.some((o) => o.startsWith("read /notes.txt@0+")));
  check("opfs: the file's text reached a window", () =>
    inkIn(blits[blits.length - 1], 494, 799, 176, 196) > 0);

  // A change made behind the editor's back shows up on the next Get, which is
  // how acme has always worked (a directory window does not auto-refresh).
  // "Get" sits at rune 21 of the tag "/mnt/opfs/ Del Snarf Get | Look ", so
  // x = 496 + 21*9 = 685; B2 is DOM button 1.
  stub.seedFile("/fresh.md", "new\n");
  const beforeGet = stub.ops.length;
  ex3.pushEvent(3, 695, 127, 0, (t3 += 16));
  step(1);
  ex3.pushEvent(1, 695, 127, 1, (t3 += 16));
  step(1);
  ex3.pushEvent(2, 695, 127, 1, (t3 += 16));
  step(40);
  check("opfs: Get re-lists the directory and sees the new file (T13)", () =>
    stub.ops.slice(beforeGet).includes("list /"));

  check("opfs: the whole drive logged no panic/failure", () =>
    !logs.some((m) => /panic|failure/i.test(m)));
  console.log(`opfs ops: ${stub.ops.length} (${stub.ops.join(", ")})`);
}

// ---- report --------------------------------------------------------------

console.log("\n--- smoke results ---");
let failed = 0;
let pending = 0;
for (const { name, status, detail } of results) {
  if (status === "FAIL") failed++;
  if (status === "PENDING") pending++;
  console.log(`  ${status.padEnd(7)} ${name}${detail ? "  (" + detail + ")" : ""}`);
}
console.log(`\nblit count: ${blits.length}`);
console.log(`wasm size:  ${bytes.length} bytes (${(bytes.length / 1024).toFixed(1)} KiB)`);
console.log(`summary:    ${results.length - failed - pending} pass, ${failed} fail, ${pending} pending`);

process.exit(failed > 0 ? 1 : 0);

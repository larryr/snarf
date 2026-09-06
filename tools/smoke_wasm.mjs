// smoke_wasm.mjs — MANUAL dev tool (R-P5-9). NEVER wired into `zig build`
// (R-BLD-02 stays intact); node is not a build dependency (ADR-0001). Run it by
// hand after `zig build`:
//
//     zig build && node tools/smoke_wasm.mjs
//
// It instantiates zig-out/www/snarf.wasm with a headless mirror of the shim env
// (R-P5-7: env.consoleLog(ptr,len) + env.blit(ptr,fbW,fbH,x,y,w,h)), drives the
// init/tick/wake lifecycle, and asserts the boot rendered the phase-4 demo scene
// (R-P5-8) all the way to a blit — reading pixels straight out of wasm memory.
// Any env import the module needs beyond those two is auto-stubbed (warn+record)
// so a link failure surfaces as a readable message, not a cryptic LinkError.
//
// NOTE: with B1's real dev/draw_canvas.zig absent, a placeholder backend that
// does NOT blit is in play; the blit/pixel assertions are expected to report
// "pending B1 merge" until the pixel path lands.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const WASM_PATH = fileURLToPath(new URL("../zig-out/www/snarf.wasm", import.meta.url));
const ORIGIN_BIN = fileURLToPath(new URL("../zig-out/bin/snarf-origin", import.meta.url));
const EXPECT_ABI = 4; // R-P12-2: 3 -> 4 (ws import surface).
const FB_W = 640;
const FB_H = 480; // R-P5-3.

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
check(`abi_version() === ${EXPECT_ABI}`, () => abi === EXPECT_ABI);

let initTrapped = false;
const logsBeforeInit = logs.length;
try {
  ex.init();
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
check("last blit fbW===640 && fbH===480", () =>
  last ? last.fbW === FB_W && last.fbH === FB_H : "pending");

check("dirty rect within framebuffer bounds", () =>
  last
    ? last.x >= 0 && last.y >= 0 && last.x + last.w <= last.fbW && last.y + last.h <= last.fbH
    : "pending");

// Phase 6: the boot scene is the acme-ivory ground fill over the whole
// display (empty buffer) — the initial damage covers the full surface.
check("dirty rect covers the full display", () =>
  last
    ? last.x === 0 && last.y === 0 && last.w === 640 && last.h === 480
    : "pending");

check("blit ptr + fbW*fbH*4 <= memory size", () =>
  last ? last.ptr + last.fbW * last.fbH * 4 <= memory.buffer.byteLength : "pending");

check("pixel (0,0) is the row-tag pale blue (0xEAFFFF)", () => {
  if (!last) return "pending";
  const p = pixelAt(last.ptr, last.fbW, 0, 0);
  return p.r === 234 && p.g === 255 && p.b === 255;
});

// Phase 6 end-to-end: inject a typed 'h' through the real input path
// (pushEvent -> devinput -> parked 9P read -> Editor -> Text -> frame -> blit)
// and watch ink appear in the first cell.
const blitsBefore = blits.length;
// Point-to-type (R-P8-9): position the pointer inside the window BODY first
// (below row tag ~18 + col tag ~18 + win tag ~18 + bands; x past the scrollbar).
ex.pushEvent(3 /* pointer_move */, 60, 80, 0, 900);
ex.tick(8);
ex.pushEvent(5 /* key */, 0x68 /* 'h' */, 0, 0, 1000);
ex.tick(16);
check("typed key produced a new blit", () => blits.length > blitsBefore);
check("typed rune added ink somewhere in the body region", () => {
  const b = blits[blits.length - 1];
  if (!b) return "pending";
  // Body region: demo text starts after the chrome strips; scan a generous band.
  for (let y = 56; y < 200; y++) {
    for (let x = 16; x < 300; x++) {
      const p = pixelAt(b.ptr, b.fbW, x, y);
      if (p.r === 0 && p.g === 0 && p.b === 0) return true;
    }
  }
  return false;
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

// ---- phase 12: /mnt/origin against a real snarf-origin --------------------
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
  ex2.init();

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

  // B1-click to place the dot at (60,80) — point-to-type inserts at the DOT,
  // not at the pointer, so the word must be anchored where we'll B2-click.
  ex2.pushEvent(1 /* pointer_down */, 60, 80, 0 /* B1 */, (now += 16));
  ex2.tick((now += 16));
  ex2.pushEvent(2 /* pointer_up */, 60, 80, 0, (now += 16));
  ex2.tick((now += 16));
  for (const ch of "Reconnect") {
    ex2.pushEvent(5 /* key */, ch.codePointAt(0), 0, 0, (now += 16));
    ex2.tick((now += 16));
  }
  ex2.pushEvent(1 /* pointer_down */, 70, 80, 1 /* B2 */, (now += 16));
  ex2.tick((now += 16));
  ex2.pushEvent(2 /* pointer_up */, 70, 80, 1, (now += 16));
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

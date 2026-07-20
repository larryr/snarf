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

const WASM_PATH = fileURLToPath(new URL("../zig-out/www/snarf.wasm", import.meta.url));
const EXPECT_ABI = 3; // R-P6-10: 2 -> 3 (input EventKind surface).
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
function buildImports(module) {
  const imports = {};
  for (const { module: mod, name, kind } of WebAssembly.Module.imports(module)) {
    imports[mod] ??= {};
    if (imports[mod][name] !== undefined) continue;
    if (mod === "env" && knownEnv[name]) {
      imports[mod][name] = knownEnv[name];
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

check("pixel (0,0) is acme ivory (0xFFFFEA)", () => {
  if (!last) return "pending";
  const p = pixelAt(last.ptr, last.fbW, 0, 0);
  return p.r === 255 && p.g === 255 && p.b === 234;
});

// Phase 6 end-to-end: inject a typed 'h' through the real input path
// (pushEvent -> devinput -> parked 9P read -> Editor -> Text -> frame -> blit)
// and watch ink appear in the first cell.
const blitsBefore = blits.length;
ex.pushEvent(5 /* key */, 0x68 /* 'h' */, 0, 0, 1000);
ex.tick(16);
check("typed key produced a new blit", () => blits.length > blitsBefore);
check("'h' cell (20..29,20..38) has a black pixel after typing", () => {
  const b = blits[blits.length - 1];
  if (!b) return "pending";
  for (let y = 20; y < 38; y++) {
    for (let x = 20; x < 29; x++) {
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

// Snarf JS shim — the single, hand-written boundary between the browser and the
// WASM module (S-06 §4). It instantiates snarf.wasm, verifies the ABI version,
// calls init(), and drives tick() from requestAnimationFrame. The device import
// surface fills in per S-06 §4 as devices land; phase 5 wires the pixel path
// (env.blit) and diagnostics (env.consoleLog).

// ABI generation this shim mirrors; must equal src/shim/abi.zig `version` and
// the module's exported abi_version() (checked below). 1→2 this phase (R-P5-4).
// Drift becomes a build error once the generated checksum lands (OQ-BLD-2).
const ABI_VERSION = 2;

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

async function boot() {
  const resp = await fetch("./snarf.wasm");
  const { instance } = await WebAssembly.instantiateStreaming(resp, imports);
  const { memory: mem, abi_version, init, wake, tick } = instance.exports;

  memory = mem;

  // Verify the ABI contract BEFORE handing control to the module (R-P5-4).
  const moduleAbi = abi_version();
  if (moduleAbi !== ABI_VERSION) {
    throw new Error(
      `snarf: ABI mismatch — shim ${ABI_VERSION}, module ${moduleAbi}`,
    );
  }

  init();

  // Minimal frame pump; `wake` will later be driven by the inbound event ring.
  function frame(nowMs) {
    tick(Math.floor(nowMs) >>> 0);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  // Expose for console poking during bring-up.
  globalThis.snarf = { instance, wake, ABI_VERSION };
}

boot().catch((err) => {
  console.error("snarf: boot failed", err);
});

// Snarf JS shim — the single, hand-written boundary between the browser and the
// WASM module (S-06 §4). Scaffold: it instantiates snarf.wasm, calls init(),
// and drives tick() from requestAnimationFrame. The real device import surface
// (draw/input/dom/host/ws/misc/time) fills in per S-06 §4 as devices land.

// ABI generation this shim mirrors; must equal src/shim/abi.zig `version`.
// Drift becomes a build error once the generated checksum lands (OQ-BLD-2).
const ABI_VERSION = 1;

const imports = {
  env: {
    // Device imports attach here, each owned by exactly one device server.
    // Intentionally empty in the scaffold.
  },
};

async function boot() {
  const resp = await fetch("./snarf.wasm");
  const { instance } = await WebAssembly.instantiateStreaming(resp, imports);
  const { init, wake, tick } = instance.exports;

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

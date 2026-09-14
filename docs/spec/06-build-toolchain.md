# S-06 — Build & Toolchain Specification

Satisfies: R-PLAT-01..04, R-BLD-01..05. Decision record:
[adr/0001-zig-toolchain-and-hosts.md](adr/0001-zig-toolchain-and-hosts.md).

## 1. Toolchain

- **Zig, pinned** (exact version recorded in `.zigversion` and `build.zig.zon`
  `minimum_zig_version`). OQ-BLD-1 **resolved 2026-07-19 → `0.16.0`** (the earlier
  "0.14.x/0.15.x" estimate predated the 0.16 release; see ADR-0001 revision log). Zig is
  a hermetic cross-compiler: the same tarball builds the WASM
  target on macOS (arm64/x86_64) and Linux (x86_64/arm64) — this alone satisfies R-BLD-01.
- Recommended install: `zvm`/`zigup` or direct tarball; `zig version` must equal the pin.
  No Homebrew/apt requirement (their versions lag).
- **Nothing else is required** (R-BLD-02): no node, no make, no system compiler. Java or
  Docker (Kroki) only if you want to render docs diagrams locally (R-BLD-05).

## 2. Targets

| Artifact | Target | Notes |
|----------|--------|-------|
| `snarf.wasm` | `wasm32-freestanding` | `ReleaseSafe` default (bounds checks are cheap insurance in v1; `ReleaseSmall` build offered for size comparison). Exports: `init`, `wake`, `tick`; imports: the shim ABI (§4). |
| unit tests | native host | `zig build test` — core, ninep, edit-language, devinput state machine, devdraw golden images (headless backend, S-03 §7). |
| `snarf-headless` | native host | optional dev tool: runs the core against headless devices for fuzzing/scripting. |

Threads/SAB: the module is built single-threaded; SAB is used only as a ring-buffer wait
target (`Atomics`), not `-fshared-memory` WASM threads, keeping both S-00 §2 modes on one
binary.

## 3. Build graph (`zig build`)

![build-flow](diagrams/build-flow.puml)

Diagram source: [diagrams/build-flow.puml](diagrams/build-flow.puml)

Steps: compile wasm → copy `web/` verbatim → embed/copy `assets/fonts` → assemble
`zig-out/www/`. `zig build serve` runs the **origin server** (`tools/origin/`, std-only,
outside the editor module graph): static `zig-out/www` with
`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`
(R-BLD-04) plus `application/wasm` MIME, **and** 9P2000 over WebSocket at `/9p`
(S-01 §3.2) exporting the tree in S-02 §5 — `-Dexport=<dir>` chooses the directory
behind `fs/` (default: the repo root), `-Dport`/`-Dbind` as before. `zig build dist` =
same tree, plus gzip/brotli precompression later.

> Revision log: 2026-09-02 (phase 11) — `tools/serve.zig` became `tools/origin/`
> (`snarf-origin`): thread per connection, `std.http.Server`'s WebSocket upgrade, the
> existing `ninep.server.Server` as the 9P engine. The `serve` step name is unchanged.

## 4. JS shim ABI (contract, R-PLAT-04)

Single `web/shim.js` (main-thread part + worker bootstrap in one reviewed file, target
< ~1500 lines). Import surface (WASM `env`), intentionally narrow — each import belongs to
exactly one device server (R-OV-03):

```
draw:    blit(imgId, x,y,w,h, ptr), flush(rectsPtr,n), canvasResize→event
input:   (no imports — events flow in via ring buffer / postMessage)
dom:     domOp(opPtr,len) → resultTicket        (batched text ops)
snarf:   clipboardRead(ticket), clipboardWrite(ptr,len,ticket)
host:    fsOp(opPtr,len,ticket)                 (FS Access / OPFS ops)
ws:      wsOpen(urlPtr,len,id), wsSend(id,ptr,len), wsClose(id)
misc:    notify, setTitle, getLocation, navigate, consoleLog, storageOp
time:    nowMs(), raf tick subscription
```

All async imports complete by pushing a completion record (ticket id + payload) into the
inbound ring; no JS→WASM re-entrancy. This ABI is versioned in one Zig file
(`src/shim/abi.zig`) and one JS mirror; drift is a build error via a generated checksum
constant (OQ-BLD-2: consider generating the JS stub from `abi.zig` with a build step —
std-only, still no node).

> Revision log: 2026-07-19 — the draw import surface shipped as ONE merged
> `blit(ptr, fb_w, fb_h, x, y, w, h)` (no separate flush import; the wasm-side
> flush IS the call site) plus `consoleLog(ptr, len)` as the panic sink. ABI
> version = 2, checked at runtime via the exported `abi_version()` before init;
> the generated-checksum build check (OQ-BLD-2) remains deferred (contract
> R-P5-4/R-P5-6).
>
> Revision log: 2026-09-05 (phase 12) — the `ws` import surface shipped as
> `wsOpen(id)`, `wsSend(id, ptr, len)`, `wsClose(id)`: the URL argument sketched
> above is DROPPED — the shim derives `ws(s)://<location.host>/9p` itself, so the
> module never sees a URL and the endpoint stays same-origin by construction
> (R-9P-15, contract R-P12-1). Inbound WS records do NOT use the ring: they
> follow the phase-6 pushEvent pattern via two new exports — `wsStage(len) → ptr`
> (module-side staging buffer; 0 = refused) and `wsPush(id, kind, ptr, len)`,
> kind ∈ {open=1, data=2, close=3, error=4} — queued only, drained on
> `tick()`/`wake()` (no JS→WASM re-entrancy). ABI version = 4 (3→4).
>
> Revision log: 2026-09-14 (phase 12c) — `canvasResize` shipped as the EVENT the
> sketch above predicted, not as an import: `init()` grew the display size
> (`init(w, h)`, device pixels) and `EventKind.resize = 8` (`a` = width,
> `b` = height) carries every later window resize. The shim sizes the canvas
> backing store from `window.innerWidth/innerHeight` — at devicePixelRatio 1
> (R-P12c-6) — before it calls either. ABI version = 5 (4→5).
>
> Revision log: 2026-09-14 (phase 14b) — the `host: fsOp` import shipped, reserved
> since phase 5 and the LAST one in the sketch above to land, as
> `fsOp(ptr, len, ticket)`: `ptr[0..len]` is ONE operation record and `ticket` is
> the module's, echoed back untouched. Record format (little-endian,
> `fs_op_version = 1`, `src/shim/FsRecord.zig` with the JS mirror in
> `web/opfs.js`):
>
> ```
> op[1] pathlen[2] path[pathlen] arg0[8] arg1[4] payloadlen[4] payload[…]
> op ∈ {stat=1, list=2, read=3, write=4,
>       create_file=5, create_dir=6, remove=7, truncate=8}
> ```
>
> `read`: arg0 = offset, arg1 = count. `write`: arg0 = offset, payload = data,
> arg1 = flags (bit0 = truncate-first, RESERVED and always 0 — OTRUNC is its own
> `truncate` op). `create_*`: arg1 = the `5/open`-masked perm (advisory; OPFS
> stores no mode). `truncate`: arg0 = the new length. `path` is absolute inside
> the OPFS root, `/`-rooted, never empty, with no `.`/`..` and no trailing slash.
>
> Completions do NOT use the ring and do not share the `ws` pair: a SECOND
> staging pair, `fsStage(len) → ptr` / `fsPush(ticket, status, ptr, len)`, so the
> two record streams cannot interleave. `status` ∈ {ok=0, not_found=1, exists=2,
> not_dir=3, is_dir=4, permission=5, quota=6, not_empty=7, io=8}; a non-`ok`
> status carries an empty payload. Payloads: `stat` ⇒ `isdir[1] size[8]
> mtime_ms[8]`; `list` ⇒ repeated `isdir[1] namelen[2] name[…]`; `read` ⇒ the
> bytes; `write` ⇒ `count[4]`; everything else empty. The shim serializes
> operations per PATH and runs different paths in parallel, and every completion
> is delivered from a microtask — never re-entrantly inside `fsOp` (the module's
> `fsPush` may call back into `fsOp`, which only enqueues). ABI version = 6
> (5→6).

## 5. CI (sketch)

GitHub Actions: matrix `{ubuntu-latest, macos-latest}` × steps: install pinned Zig (cache
tarball) → `zig build` → `zig build test` → upload `zig-out/www` artifact → (later)
Playwright smoke test (browser available in CI image; not a repo dependency) → optional
Pages deploy from main. Docs job: render `docs/spec/diagrams/*.puml` via `plantuml` action,
attach SVGs to the run — sources stay authoritative (R-BLD-05).

## 6. Repository conventions

- `zig fmt` clean is CI-enforced (`zig fmt --check .`).
- No git submodules, no vendored deps expected at all while ADR-0002 holds; `build.zig.zon`
  dependency table stays empty (fonts live in-tree under `assets/`).
- Diagram edits: change `.puml`, never commit rendered images (keeps diffs reviewable).

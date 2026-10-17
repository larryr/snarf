# dist/

Binary build artifacts, dropped here for direct download when GitHub Releases
aren't reachable (credential/permission gap — see `agents/HANDOFF.md`). This is
a workaround, not a convention: these files bloat repo history permanently, so
prune this directory (and squash/rewrite history if it grows) once Releases
work again.

## snarf-native-preview-macos-arm64.zip

Preview build of native snarf + the in-tree-built `devdraw` peer (ADR-0006).
**macOS, Apple Silicon (arm64) only** — built host==target, no cross-compile.

Built from `phase18-devdraw-build` (PR #24) at commit `005013c` — not yet
merged to `main`. Ad-hoc signed only, not notarized, so Gatekeeper will
quarantine it on download; see the `README.txt` inside the zip for the
`xattr -dr com.apple.quarantine` step and run instructions.

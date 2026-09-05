# Snarf — layered architecture (spec 00)

Mermaid review mirror of [`architecture.puml`](../architecture.puml) — the PlantUML source remains authoritative.

<!-- Divergence: PlantUML `package` / `cloud` groupings both become Mermaid `subgraph`s;
     Mermaid has no distinct cloud shape for a container. -->
<!-- Divergence: PlantUML `..>` (dependency, dashed) maps to Mermaid `-.->`. -->
<!-- Divergence: `[Visible <canvas>]` is escaped as `&lt;canvas&gt;` so the Mermaid/HTML
     label renderer does not swallow it as a tag. -->

```mermaid
flowchart TB
    subgraph MainThread["Browser main thread"]
        Shim["index.html + JS shim<br/>(canvas present, event capture,<br/>clipboard, FS Access, WebSocket)"]
        Canvas["Visible &lt;canvas&gt;"]
    end

    subgraph Worker["Web Worker — snarf.wasm (Zig, wasm32-freestanding)"]
        subgraph CoreBox["Editor core (browser-agnostic)"]
            Editor["ACME editor<br/>(windows, columns, tags,<br/>Edit language, undo)"]
            Libdraw["libdraw-like client"]
            NS["9P client + mount table<br/>(namespace)"]
        end

        subgraph DevBox["Device layer (9P servers)"]
            DevDraw["/dev/draw server"]
            DevInput["/dev/mouse /dev/kbd server"]
            DevDom["/dev/dom server"]
            DevMisc["/dev/snarf /dev/storage<br/>/dev/notify ... servers"]
            DevHost["/mnt/host server<br/>(FS Access API / OPFS)"]
        end

        Chan["9P transport: in-memory channels"]
        WS["9P transport: WebSocket framing"]
    end

    subgraph Origin["Origin web server"]
        Static["static assets"]
        Origin9P["optional 9P export<br/>wss://origin/9p"]
    end

    Editor --> Libdraw
    Editor --> NS
    Libdraw -->|"write /dev/draw/N/data"| NS
    NS --> Chan
    Chan --> DevDraw
    Chan --> DevInput
    Chan --> DevDom
    Chan --> DevMisc
    Chan --> DevHost
    NS -->|"/mnt/origin"| WS
    WS --> Origin9P
    DevDraw -.->|"hostcall imports<br/>(pixels → OffscreenCanvas)"| Shim
    DevInput -.->|"pointer/key events in"| Shim
    DevDom -.->|"DOM ops"| Shim
    DevMisc -.->|"clipboard, storage, notify"| Shim
    DevHost -.->|"FS Access handles"| Shim
    Shim --> Canvas
    Static -.->|"serves page"| Shim
```

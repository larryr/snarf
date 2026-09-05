# Build & dev flow — Zig only, macOS or Linux (spec 06, ADR-0001)

Mermaid review mirror of [`build-flow.puml`](../build-flow.puml) — the PlantUML source remains authoritative.

<!-- Divergence: PlantUML `file` / `rectangle` / `folder` / `cloud` / `actor` shapes have no
     one-to-one Mermaid equivalents. Files use the `[/.../]` parallelogram, build steps use
     rectangles, output/host containers use `subgraph`s, and the `actor Browser` is a
     stadium node. -->
<!-- Divergence: the `note bottom of ZB` becomes a standalone node linked to ZB with a
     dotted edge, since Mermaid flowcharts have no floating note element. -->

```mermaid
flowchart TB
    subgraph Host["Developer host (macOS or Linux)"]
        SRC[/"src/**/*.zig"/]
        WEB[/"web/index.html<br/>web/shim.js"/]
        FONTS[/"assets/fonts/*.subf"/]
        BZ[/"build.zig<br/>build.zig.zon<br/>.zigversion"/]

        ZB["zig build"]
        ZT["zig build test<br/>(native host target)"]
        ZS["zig build serve<br/>(dev HTTP server,<br/>COOP/COEP headers)"]
    end

    subgraph Out["zig-out/www (deployable static site)"]
        WASM[/"snarf.wasm"/]
        OUTWEB[/"index.html<br/>shim.js"/]
        OUTFONTS[/"fonts/*"/]
    end

    HOSTING["Any static host<br/>(GitHub Pages, nginx, ...)"]
    Browser(["Browser"])

    SRC --> ZB
    BZ --> ZB
    WEB -->|"copied verbatim"| ZB
    FONTS -->|"embedded or copied"| ZB
    ZB -->|"target wasm32-freestanding<br/>ReleaseSmall/ReleaseSafe"| WASM
    ZB --> OUTWEB
    ZB --> OUTFONTS
    SRC -->|"same code, native target<br/>(core is browser-free, R-CON-02)"| ZT
    ZS -.->|"http://localhost:8000"| Browser
    WASM --> HOSTING
    OUTWEB --> HOSTING
    OUTFONTS --> HOSTING
    HOSTING --> Browser

    NOTE["Only required tool: pinned Zig.<br/>No make/cmake/node/cc.<br/>Identical commands on both OSes."]
    ZB -.- NOTE
```

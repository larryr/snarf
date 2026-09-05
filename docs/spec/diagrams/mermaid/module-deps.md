# Module dependency rules — allowed imports only (spec 07 §6)

Mermaid review mirror of [`module-deps.puml`](../module-deps.puml) — the PlantUML source remains authoritative.

<!-- Divergence: PlantUML `package` groupings become Mermaid `subgraph`s. -->
<!-- Divergence: PlantUML `..>` (dependency, dashed) maps to Mermaid `-.->`. -->
<!-- Divergence: the two floating notes (`note bottom of core`, `note right of XPORT`) become
     standalone nodes tied to their subject with dotted, unlabelled edges, since Mermaid
     flowcharts have no floating note element. -->

```mermaid
flowchart TB
    subgraph core["src/core (editor, browser-free)"]
        CORE["Editor, Row, Column, Window,<br/>File, Buffer, text/, exec/,<br/>edit/, look/, served/"]
    end
    subgraph draw["src/draw (client + frame)"]
        DRAW["Display, Image, Font, proto,<br/>frame/"]
    end
    subgraph ninep["src/ninep (9P2000)"]
        MSG["msg, qid"]
        CLI["client, mount"]
        SRV["server"]
        XPORT["chan, ws"]
    end
    subgraph dev["src/dev (device servers)"]
        DEV["draw, draw_backend, input,<br/>profiles, dom, host,<br/>storage, misc"]
    end
    subgraph shim["src/shim (WASM boundary)"]
        SHIM["abi, ring"]
    end

    CORE --> DRAW
    CORE --> CLI
    DRAW --> CLI
    CLI --> MSG
    SRV --> MSG
    XPORT --> MSG
    DEV --> SRV
    DEV --> SHIM
    CORE -.->|"served/ only<br/>(/mnt/snarf-self)"| SRV

    NOTE1["core NEVER imports dev or shim<br/>(R-CON-02: natively testable).<br/>ninep and shim import std only."]
    CORE -.- NOTE1

    NOTE2["transports bind client↔server<br/>at runtime via the mount table;<br/>no compile-time coupling."]
    XPORT -.- NOTE2
```

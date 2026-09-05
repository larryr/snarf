# 9P session — editor core reading a host file via /mnt/host (spec 01)

Mermaid review mirror of [`9p-session.puml`](../9p-session.puml) — the PlantUML source remains authoritative.

<!-- Divergence: PlantUML's `== section ==` dividers have no Mermaid equivalent; they are
     rendered here as `Note over` banners spanning all participants. -->
<!-- Divergence: PlantUML `->` (solid) / `-->` (dashed reply) map to Mermaid `->>` / `-->>`. -->

```mermaid
sequenceDiagram
    participant C as Editor core<br/>(9P client)
    participant M as Mount table
    participant S as /mnt/host server<br/>(device layer)
    participant J as JS shim<br/>(FS Access API)

    Note over C,J: session setup (once per mount)
    C->>S: Tversion msize=65536 "9P2000"
    S-->>C: Rversion msize=65536 "9P2000"
    C->>S: Tattach fid=0 afid=NOFID uname="user" aname=""
    S-->>C: Rattach qid
    C->>M: mount(fid=0, "/mnt/host")

    Note over C,J: Get /mnt/host/src/main.zig
    C->>M: resolve path → (server, root fid)
    C->>S: Twalk fid=0 newfid=1 "src" "main.zig"
    S-->>C: Rwalk qid[2]
    C->>S: Topen fid=1 mode=OREAD
    S->>J: getFileHandle("src/main.zig")
    J-->>S: handle (may trigger permission prompt)
    S-->>C: Ropen qid iounit
    loop until Rread count == 0
        C->>S: Tread fid=1 offset count
        S->>J: file.read(offset, count)
        J-->>S: bytes
        S-->>C: Rread data
    end
    C->>S: Tclunk fid=1
    S-->>C: Rclunk

    Note over S,J: Permission denied by the user maps to<br/>Rerror "permission denied", never a hang.
```

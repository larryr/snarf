# Mermaid review mirrors

GitHub-renderable Mermaid copies of the PlantUML diagrams in [`../`](../), provided so the
diagrams can be read in a browser during review. Per the project documentation conventions
the `.puml` sources remain **authoritative** — when the two disagree, the PlantUML is right,
and any change must be made there first and then mirrored here.

| Mermaid mirror | PlantUML source | Diagram type |
| --- | --- | --- |
| [`9p-session.md`](9p-session.md) | [`../9p-session.puml`](../9p-session.puml) | `sequenceDiagram` |
| [`architecture.md`](architecture.md) | [`../architecture.puml`](../architecture.puml) | `flowchart` |
| [`build-flow.md`](build-flow.md) | [`../build-flow.puml`](../build-flow.puml) | `flowchart` |
| [`draw-pipeline.md`](draw-pipeline.md) | [`../draw-pipeline.puml`](../draw-pipeline.puml) | `sequenceDiagram` |
| [`module-deps.md`](module-deps.md) | [`../module-deps.puml`](../module-deps.puml) | `flowchart` |
| [`mouse-chords.md`](mouse-chords.md) | [`../mouse-chords.puml`](../mouse-chords.puml) | `stateDiagram-v2` |
| [`namespaces.md`](namespaces.md) | [`../namespaces.puml`](../namespaces.puml) | `mindmap` |

Each mirror notes, in HTML comments above its diagram block, where Mermaid cannot express
what the PlantUML source does (floating notes, section dividers, shape vocabulary, and the
character escapes Mermaid's parsers require).

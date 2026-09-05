# Input server — logical button/chord synthesis state machine (spec 04, ADR-0004)

Mermaid review mirror of [`mouse-chords.puml`](../mouse-chords.puml) — the PlantUML source remains authoritative.

<!-- Divergence: PlantUML's empty `state Idle { }` bodies carry no content and are declared
     here as plain states. -->
<!-- Divergence: PlantUML's `note bottom of Arg` becomes `note right of Arg`; Mermaid state
     notes support only `left of` / `right of`. -->

```mermaid
stateDiagram-v2
    [*] --> Idle

    state "Idle" as Idle
    state "B1 active<br/>(sweep in progress)" as B1
    state "B1+B2 chord<br/>⇒ core sees Cut gesture" as Cut
    state "B1+B3 chord<br/>⇒ core sees Paste gesture" as Paste
    state "B2 active<br/>(execute sweep)" as B2
    state "B2+B1 chord<br/>⇒ execute with argument" as Arg
    state "B3 active<br/>(look sweep)" as B3

    Idle --> B1 : phys B1 down /<br/>touch: finger 1 down
    Idle --> B2 : phys B2 down / Alt+B1 down /<br/>touch: two-finger tap / chordbar 2
    Idle --> B3 : phys B3 down / Meta+B1 down /<br/>touch: three-finger tap or long-press
    B1 --> Idle : B1 up (click or sweep done)
    B2 --> Idle : B2 up
    B3 --> Idle : B3 up

    B1 --> Cut : phys B2 down /<br/>Alt pressed mid-sweep /<br/>touch: 2nd finger tap /<br/>chordbar 2 tapped
    B1 --> Paste : phys B3 down /<br/>Meta pressed mid-sweep /<br/>touch: 2nd finger double-tap
    Cut --> B1 : chord button/modifier up<br/>(buttons=1 again)
    Paste --> B1 : chord button/modifier up
    Cut --> Paste : B3/Meta while chorded<br/>(snarf+paste idiom)

    B2 --> Arg : phys B1 down /<br/>modifier released, B1 still down? see note
    Arg --> B2 : B1 up

    note right of Cut
        Emitted on /dev/mouse as ordinary
        Plan 9 events: buttons 1 → 3 → 1.
        The core runs unmodified ACME logic;
        it cannot tell emulation from hardware.
    end note

    note right of Arg
        2-1 chord (execute with argument).
        In the modifier profile: hold Alt, press
        pointer button (=B2 sweep), release Alt
        while holding (=B1 join).
    end note
```

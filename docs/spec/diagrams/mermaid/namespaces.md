# Snarf namespace — assembled mount table (spec 02)

Mermaid review mirror of [`namespaces.puml`](../namespaces.puml) — the PlantUML source remains authoritative.

<!-- Divergence: every node carries an explicit id and a quoted `[...]` label, because bare
     Mermaid mindmap text treats `(`, `)`, `[` and `]` as shape delimiters. -->
<!-- Divergence: `<html>` is escaped as `&lt;html&gt;`, and the literal double quotes in the
     /dev/notify entry are written as `&quot;`, so the label parses. -->

```mermaid
mindmap
  root["/"]
    dev["dev"]
      draw["draw — draw device (spec 03)"]
        drawnew["new — open to allocate a client conn"]
        draw1["1/ — per-client: ctl, data, refresh, colormap"]
      mouse["mouse — logical mouse events (spec 04)"]
      cursor["cursor — write to set cursor"]
      kbd["kbd — keyboard runes (spec 04)"]
      cons["cons — console text I/O"]
      snarf["snarf — clipboard (read/write)"]
      storage["storage/ — persistent files (IndexedDB-backed)"]
      notify["notify — write &quot;title\nbody&quot; to notify"]
      location["location — read URL / write to navigate"]
      title["title — read/write tab title"]
      log["log — write → browser console"]
      inputctl["input/ctl — select profile (native/modifier/touch/chordbar)"]
      dom["dom/ — the hosting page's DOM"]
        domroot["root/ — &lt;html&gt; element as a directory"]
          domctl["ctl — mutate: create/append/remove/listen"]
          domattrs["attrs — one &quot;name value&quot; per line"]
          domstyle["style — computed style, writable subset"]
          domtext["text — textContent"]
          domhtml["html — innerHTML"]
          domkids["0/ 1/ ... — child elements, in order"]
        domevents["events — stream of subscribed DOM events"]
        domquery["query — write CSS selector, read matches"]
    mnt["mnt"]
      mnthost["host/ — user-granted local dir (FS Access API)"]
      mntopfs["opfs/ — origin-private FS (always available)"]
      mntorigin["origin/ — origin server 9P export (if present)"]
      mntself["snarf-self/ — Snarf's own state, ACME-style"]
        selfindex["index — list of windows"]
        selfnew["new/ — open to create a window"]
        self1["1/ — per-window: addr, body, tag, data, event, ctl"]
```

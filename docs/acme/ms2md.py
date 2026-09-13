#!/usr/bin/env python3
r"""Convert Plan 9 sys/doc/acme/acme.ms (troff -ms) to Markdown.

Handles exactly the macros that file uses: TL AU AB AE FS FE SH PP LP br
I R CW P1 P2 FG fg, plus inline escapes \(em \f.. \e and ``'' quotes.
"""
import re, sys

src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")

def troff_args(rest):
    """Split macro arguments troff-style ("quoted", "" empty, unterminated quote ok)."""
    args, i, n = [], 0, len(rest)
    while i < n:
        while i < n and rest[i] == " ":
            i += 1
        if i >= n:
            break
        if rest[i] == '"':
            j = rest.find('"', i + 1)
            if j < 0:
                args.append(rest[i + 1:]); break
            args.append(rest[i + 1:j]); i = j + 1
        else:
            j = rest.find(" ", i)
            if j < 0:
                j = n
            args.append(rest[i:j]); i = j
    return args

def inline(s):
    """Resolve troff inline escapes to Markdown."""
    s = s.replace("\\(em", "—").replace("\\e", "\\")
    s = s.replace("``", "“").replace("''", "”")
    s = re.sub(r"`([^`'\n]+)'", "‘\\1’", s)
    # font escapes: \f(CW \fI \f2 \f1 \fR \fP \f(Jp -- troff *switches* fonts,
    # so close the current markup before opening the next; \fP restores the previous.
    marks = {"CW": "`", "I": "*", "2": "*"}
    out, cur, prev, i = [], "", "", 0
    while i < len(s):
        if s.startswith("\\f", i):
            if s[i + 2] == "(":
                f, i = s[i + 3:i + 5], i + 5
            else:
                f, i = s[i + 2], i + 3
            if f == "P":
                new = prev
            elif f in ("1", "R"):
                new = ""
            else:
                new = marks.get(f, "")
            if new != cur:
                out.append(cur); out.append(new)
            prev, cur = cur, new
            continue
        out.append(s[i]); i += 1
    out.append(cur)
    return "".join(out)

def code_span(w):
    return "`" + w + "`" if w else ""

blocks = []          # finished markdown blocks (strings)
cur = []             # lines of the paragraph being built
italic_open = False
mode = None          # None | "abstract" | "footnote" | "code" | "figure" | "author"
footnote = []
code = []
fig_name = None
i = 0

def flush():
    global cur, italic_open
    if italic_open and cur:
        cur[-1] = cur[-1].rstrip() + "*"
        italic_open = False
    if cur:
        text = "\n".join(cur)
        if mode == "footnote":
            footnote.append(text)
        elif mode == "figure":
            blocks.append("\n".join("> " + l for l in text.split("\n")))
        else:
            blocks.append(text)
        cur = []

def add_text(t):
    global italic_open
    t = inline(t)
    if italic_open and (not cur or cur[-1].endswith("*") is False and italic_open == "pending"):
        pass
    if italic_open == "pending":
        t = "*" + t.lstrip()
        italic_open = True
    cur.append(t)

# skip preamble (macro definitions) up to .TL
while not lines[i].startswith(".TL"):
    i += 1

while i < len(lines):
    ln = lines[i]; i += 1
    if mode == "code":
        if ln.startswith(".P2"):
            blocks.append("```\n" + "\n".join(code).replace("\\e", "\\") + "\n```")
            code, mode = [], None
        else:
            code.append(ln)
        continue
    if ln.startswith(".") or ln.startswith("'"):
        m = re.match(r"^\.(\S*)\s*(.*)$", ln)
        mac, rest = m.group(1), m.group(2)
        if mac == "TL":
            flush(); blocks.append("# " + inline(lines[i]).strip()); i += 1
        elif mac == "AU":
            flush(); mode = "author"
        elif mac == "SP" or mac == "if" or mac == "html" or mac == "sp" or mac == "\\\"":
            pass
        elif mac == "AB":
            flush(); mode = "abstract"; blocks.append("## Abstract")
        elif mac == "AE":
            flush(); mode = None
        elif mac == "FS":
            flush(); mode = "footnote"
        elif mac == "FE":
            flush(); mode = "abstract"
            note = "\n".join("> " + l for l in "\n\n".join(footnote).split("\n"))
            blocks.insert(blocks.index("## Abstract"), note)
            footnote = []
        elif mac == "SH":
            flush(); blocks.append("## " + inline(lines[i]).strip()); i += 1
        elif mac in ("PP", "LP"):
            flush()
        elif mac == "br":
            flush()
        elif mac == "P1":
            flush(); mode = "code"
        elif mac == "FG":
            flush(); fig_name = troff_args(rest)[0]; mode = "figure"
            fig_no = re.sub(r"\D", "", fig_name)
            blocks.append("![Figure %s](%s.gif)" % (fig_no, fig_name))
        elif mac == "fg":
            flush(); mode = None
        elif mac == "I":
            args = troff_args(rest)
            if not args:
                italic_open = "pending"
            else:
                w = "*" + inline(args[0]).strip() + "*" + (args[1] if len(args) > 1 else "")
                if mode == "author":
                    flush(); blocks.append(w)
                else:
                    cur.append(w)
        elif mac == "R":
            if italic_open is True:
                cur[-1] = cur[-1].rstrip() + "*"
            italic_open = False
        elif mac == "CW":
            args = troff_args(rest) + ["", "", ""]
            cur.append(args[2] + code_span(inline(args[0])) + args[1])
        else:
            sys.stderr.write("unhandled macro line %d: %s\n" % (i, ln))
        continue
    if ln.strip() == "":
        continue
    if mode == "author":
        mode = None
    add_text(ln)

flush()

note = ("<!-- Converted from acme.ms (Plan 9 4th Edition, sys/doc/acme, fork larryr/plan9@ed1a9c2) "
        "by ms2md.py in this directory. The troff source is authoritative; regenerate rather than hand-edit. -->")
md = note + "\n\n" + "\n\n".join(blocks) + "\n"
# tidy: caption paragraphs directly after an image get an italic "Figure N." lead already in text
open(dst, "w", encoding="utf-8").write(md)
print("wrote", dst, len(md.split("\n")), "lines")

# Test plan: #11 Native file server

**Issue:** #11 · **Requirements:** R-EDIT-15, R-EDIT-16, R-P17-5 (spec S-02: `$home`), ADR-0005 §2 + amendment item 1, R-OV-03, R-9P-14 · **Status:** draft

Harness: in-process `hostfs` 9P server rooted at a per-test temp dir (`std.testing.tmpDir`), mounted into a headless editor namespace at the spec'd path (see Q1). No real `$HOME` writes in unit tests: `$HOME` overridden to temp.

| ID | Type | Scenario | Expected | Traces |
|---|---|---|---|---|
| NFS-01 | integration | Boot native namespace | host FS visible at agreed mount point; `/dev`, `/mnt/snarf-self` still present | #11, ADR-0005 §2 |
| NFS-02 | integration | B3 on absolute path of existing file | window opens with file contents byte-exact (incl. UTF-8, no trailing NL, CRLF) | #11, R-EDIT-15 |
| NFS-03 | integration | B3 on a directory path | dir window lists entries (trailing `/` for dirs) | R-EDIT-03 |
| NFS-04 | integration | B3 on nonexistent path | error in `+Errors`, no crash, no empty window claiming success | checklist 5 |
| NFS-05 | integration | Edit, `Put` | disk content == buffer; window clean; `putseq` updated | R-EDIT-15 |
| NFS-06 | integration | Undo after `Put` | undo still available and reverts; window dirty again | #11 "undo survives Put" |
| NFS-07 | integration | External change on disk, then `Get` | buffer reloaded; Get on dirty window follows acme two-strike warning | R-EDIT-15, R-P17-8 |
| NFS-08 | integration | `Putall` with 3 windows (2 dirty, 1 clean) | exactly the 2 dirty written; clean file mtime unchanged | R-EDIT-15 |
| NFS-09 | integration | `Put` to a new path (rename via tag, create) | file created with mode per spec | R-EDIT-15, R-P17-7 |
| NFS-10 | negative | `Put` to read-only file / dir w/o permission | honest 9P error in `+Errors`; window stays dirty; no partial write (temp + rename?) — **Q5** | checklist 6 |
| NFS-11 | integration | `Dump` | `$HOME/acme.dump` written, text format | R-EDIT-16, R-P17-5, R-9P-14 |
| NFS-12 | integration | Fresh editor, `Load` | layout/windows/addresses restored == pre-dump (compare RowDump output) | R-EDIT-16 |
| NFS-13 | negative | Load missing / corrupt dump | error, editor unchanged | R-EDIT-16 |
| NFS-14 | integration | served tree: `ctl` verbs `get`/`put` through `/mnt/snarf-self` hit disk | same effects as tag commands | roadmap process rule 1, R-EDIT-17 |
| NFS-15 | security | Paths with `..`, symlinks out of root (if mount is a sub-root) | resolved per spec, no escape beyond intended root | ADR-0005 §2 — **Q1** |
| NFS-16 | perf (smoke) | Open 5 MB file | opens < 1 s, no quadratic behaviour | — |
| NFS-17 | regression | Browser/origin path (frozen) still passes `tools/origin` acceptance tests | green | R-OV-09 |
| NFS-18 | manual | checklist steps 5–7 on Larry's Mac | pass | #11 |

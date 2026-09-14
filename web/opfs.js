// Snarf OPFS backend — the browser half of `/mnt/opfs` (ABI v6, S-06 §4).
//
// The module speaks one binary record to this file through the `env.fsOp`
// import and gets answers back through the `fsStage`/`fsPush` export pair. Both
// halves of the codec are mirrored from src/shim/FsRecord.zig; the integers
// below MUST agree with it, exactly as WS_KIND and EventKind do in shim.js.
//
// Everything here is same-origin and dependency-free: the Origin Private File
// System is reached through navigator.storage.getDirectory() and nothing else
// is loaded (ADR-0002 in spirit — no CDN, no library, no third-party endpoint).
//
// CONCURRENCY (contract §3a). Operations are serialized PER PATH and run in
// parallel across paths: a chain of promises keyed by the record's path, so two
// writes to one file cannot interleave while a read of another file proceeds
// independently. Every completion is delivered from a `.then` continuation,
// i.e. a microtask — NEVER re-entrantly inside the `fsOp` call — which is what
// the module's "no JS→WASM re-entrancy" rule requires. The module's own
// `fsPush` may call back into `fsOp` (a walk's next component); that is fine,
// because `fsOp` only enqueues.

// --- mirrors of src/shim/FsRecord.zig ------------------------------------

export const FS_OP_VERSION = 1;

export const FS_OP = {
  stat: 1,
  list: 2,
  read: 3,
  write: 4,
  create_file: 5,
  create_dir: 6,
  remove: 7,
  truncate: 8,
};

export const FS_STATUS = {
  ok: 0,
  not_found: 1,
  exists: 2,
  not_dir: 3,
  is_dir: 4,
  permission: 5,
  quota: 6,
  not_empty: 7,
  io: 8,
};

const EMPTY = new Uint8Array(0);
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

// op[1] pathlen[2] path[pathlen] arg0[8] arg1[4] payloadlen[4] payload[…],
// little-endian throughout. Returns null on anything malformed — a record this
// side cannot read is a module bug, and dropping it (with a warning) is better
// than answering a ticket we may have misidentified.
export function decodeRecord(bytes) {
  if (bytes.length < 19) return null;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const op = dv.getUint8(0);
  const pathLen = dv.getUint16(1, true);
  if (bytes.length < 3 + pathLen + 16) return null;
  const path = textDecoder.decode(bytes.subarray(3, 3 + pathLen));
  let p = 3 + pathLen;
  const arg0 = dv.getBigUint64(p, true);
  const arg1 = dv.getUint32(p + 8, true);
  const payloadLen = dv.getUint32(p + 12, true);
  p += 16;
  if (bytes.length - p !== payloadLen) return null;
  return { op, path, arg0, arg1, payload: bytes.subarray(p) };
}

// `stat` reply: isdir[1] size[8] mtime_ms[8].
function statReply(isDir, size, mtimeMs) {
  const out = new Uint8Array(17);
  const dv = new DataView(out.buffer);
  dv.setUint8(0, isDir ? 1 : 0);
  dv.setBigUint64(1, BigInt(Math.max(0, Math.floor(size))), true);
  dv.setBigUint64(9, BigInt(Math.max(0, Math.floor(mtimeMs))), true);
  return out;
}

// `list` reply: repeated isdir[1] namelen[2] name[…].
function listReply(entries) {
  const encoded = entries.map((e) => ({
    isDir: e.isDir,
    name: textEncoder.encode(e.name),
  }));
  let total = 0;
  for (const e of encoded) total += 3 + e.name.length;
  const out = new Uint8Array(total);
  const dv = new DataView(out.buffer);
  let p = 0;
  for (const e of encoded) {
    dv.setUint8(p, e.isDir ? 1 : 0);
    dv.setUint16(p + 1, e.name.length, true);
    out.set(e.name, p + 3);
    p += 3 + e.name.length;
  }
  return out;
}

// `write` reply: count[4].
function writeReply(count) {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, count >>> 0, true);
  return out;
}

// --- DOMException → FS_STATUS --------------------------------------------

// `expect` says which kind the caller was asking for, because the File System
// API reports "you asked for a file and this is a directory" and its opposite
// with the SAME name (TypeMismatchError).
function statusOf(err, expect) {
  switch (err && err.name) {
    case "NotFoundError":
      return FS_STATUS.not_found;
    case "TypeMismatchError":
      return expect === "dir" ? FS_STATUS.not_dir : FS_STATUS.is_dir;
    case "QuotaExceededError":
      return FS_STATUS.quota;
    case "InvalidModificationError":
      // removeEntry() without {recursive} on a non-empty directory.
      return FS_STATUS.not_empty;
    case "NotAllowedError":
    case "SecurityError":
      return FS_STATUS.permission;
    case "TypeError":
      // A name the File System API refuses outright ("", ".", "..", "/").
      return FS_STATUS.not_found;
    default:
      return FS_STATUS.io;
  }
}

// A thrown status, so the per-op bodies can `throw new FsError(...)` for the
// conditions the platform does not raise on its own (an already-existing name).
class FsError extends Error {
  constructor(status) {
    super(`opfs status ${status}`);
    this.status = status;
  }
}

// --- path helpers ---------------------------------------------------------

// "/a/b" -> ["a", "b"]; "/" -> []. The module guarantees absolute, `.`/`..`-free
// paths (opfs_tree.zig), so this is a split, not a resolver.
function partsOf(path) {
  return path.split("/").filter((s) => s.length > 0);
}

// --- the backend ----------------------------------------------------------

// `complete(ticket, status, bytes)` stages the payload into wasm memory and
// calls the module's fsPush; `warn` is the shim's diagnostic channel.
export function createOpfsBackend({ complete, warn }) {
  const available =
    typeof navigator !== "undefined" &&
    navigator.storage &&
    typeof navigator.storage.getDirectory === "function";
  let warnedUnavailable = false;

  // One promise chain per path: same path serializes, different paths do not.
  const chains = new Map();

  let rootPromise = null;
  function root() {
    if (!rootPromise) rootPromise = navigator.storage.getDirectory();
    return rootPromise;
  }

  // The directory handle for `parts` (the whole array), creating nothing.
  async function dirOf(parts) {
    let dir = await root();
    for (const name of parts) {
      dir = await dir.getDirectoryHandle(name);
    }
    return dir;
  }

  // Split a path into (parent directory handle, last component). Throws
  // not_found via FsError when the path is the root and a leaf was required.
  async function parentOf(parts) {
    if (parts.length === 0) throw new FsError(FS_STATUS.not_found);
    return {
      dir: await dirOf(parts.slice(0, -1)),
      name: parts[parts.length - 1],
    };
  }

  async function statOf(parts) {
    if (parts.length === 0) return statReply(true, 0, 0);
    const { dir, name } = await parentOf(parts);
    try {
      const fh = await dir.getFileHandle(name);
      const f = await fh.getFile();
      return statReply(false, f.size, f.lastModified);
    } catch (err) {
      if (err && err.name === "TypeMismatchError") {
        // It exists and is a directory. OPFS gives a directory no timestamp.
        await dir.getDirectoryHandle(name);
        return statReply(true, 0, 0);
      }
      throw err;
    }
  }

  async function listOf(parts) {
    const dir = await dirOf(parts);
    const entries = [];
    for await (const [name, handle] of dir.entries()) {
      entries.push({ name, isDir: handle.kind === "directory" });
    }
    return listReply(entries);
  }

  async function readOf(parts, offset, count) {
    const { dir, name } = await parentOf(parts);
    const fh = await dir.getFileHandle(name);
    const f = await fh.getFile();
    const start = Number(offset);
    if (start >= f.size || count === 0) return EMPTY;
    const blob = f.slice(start, start + count);
    return new Uint8Array(await blob.arrayBuffer());
  }

  async function writeOf(parts, offset, data) {
    const { dir, name } = await parentOf(parts);
    const fh = await dir.getFileHandle(name);
    // keepExistingData: a 9P write is positional, never a truncating rewrite.
    const w = await fh.createWritable({ keepExistingData: true });
    try {
      await w.write({ type: "write", position: Number(offset), data });
    } finally {
      await w.close();
    }
    return writeReply(data.length);
  }

  async function truncateOf(parts, length) {
    const { dir, name } = await parentOf(parts);
    const fh = await dir.getFileHandle(name);
    const w = await fh.createWritable({ keepExistingData: true });
    try {
      await w.truncate(Number(length));
    } finally {
      await w.close();
    }
    return EMPTY;
  }

  // 9P create is exclusive (`5/open`), but getFileHandle({create:true}) is
  // idempotent — so look first and refuse a name that is already taken.
  async function refuseExisting(dir, name) {
    try {
      await dir.getFileHandle(name);
      throw new FsError(FS_STATUS.exists);
    } catch (err) {
      if (err instanceof FsError) throw err;
      if (err && err.name === "TypeMismatchError") throw new FsError(FS_STATUS.exists);
      if (!err || err.name !== "NotFoundError") throw err;
    }
  }

  async function createOf(parts, isDir) {
    const { dir, name } = await parentOf(parts);
    await refuseExisting(dir, name);
    if (isDir) await dir.getDirectoryHandle(name, { create: true });
    else await dir.getFileHandle(name, { create: true });
    return EMPTY;
  }

  async function removeOf(parts) {
    const { dir, name } = await parentOf(parts);
    // NO {recursive}: 9P has no recursive remove, so a non-empty directory
    // must come back as "directory not empty" (R-P14b-4).
    await dir.removeEntry(name);
    return EMPTY;
  }

  async function perform(rec) {
    const parts = partsOf(rec.path);
    switch (rec.op) {
      case FS_OP.stat:
        return { status: FS_STATUS.ok, payload: await statOf(parts) };
      case FS_OP.list:
        return { status: FS_STATUS.ok, payload: await listOf(parts) };
      case FS_OP.read:
        return { status: FS_STATUS.ok, payload: await readOf(parts, rec.arg0, rec.arg1) };
      case FS_OP.write:
        return { status: FS_STATUS.ok, payload: await writeOf(parts, rec.arg0, rec.payload) };
      case FS_OP.create_file:
        return { status: FS_STATUS.ok, payload: await createOf(parts, false) };
      case FS_OP.create_dir:
        return { status: FS_STATUS.ok, payload: await createOf(parts, true) };
      case FS_OP.remove:
        return { status: FS_STATUS.ok, payload: await removeOf(parts) };
      case FS_OP.truncate:
        return { status: FS_STATUS.ok, payload: await truncateOf(parts, rec.arg0) };
      default:
        return { status: FS_STATUS.io, payload: EMPTY };
    }
  }

  // The expectation `statusOf` needs: only the two directory-shaped ops are
  // asking for a directory.
  function expectOf(op) {
    return op === FS_OP.list || op === FS_OP.create_dir ? "dir" : "file";
  }

  async function runOne(rec, ticket) {
    try {
      const { status, payload } = await perform(rec);
      complete(ticket, status, payload);
    } catch (err) {
      const status = err instanceof FsError ? err.status : statusOf(err, expectOf(rec.op));
      if (status === FS_STATUS.io) warn("opfs:", rec.path, err);
      complete(ticket, status, EMPTY);
    }
  }

  return {
    available,

    // The `env.fsOp` import. `bytes` is a COPY of the record out of wasm
    // memory (the caller slices it, because linear memory may grow under us).
    submit(bytes, ticket) {
      if (!available) {
        if (!warnedUnavailable) {
          warnedUnavailable = true;
          warn("/mnt/opfs: OPFS unavailable in this browser");
        }
        // Answer from a microtask, never inside this call.
        Promise.resolve().then(() => complete(ticket, FS_STATUS.io, EMPTY));
        return;
      }
      const rec = decodeRecord(bytes);
      if (!rec) {
        warn("opfs: undecodable op record, dropped a ticket");
        Promise.resolve().then(() => complete(ticket, FS_STATUS.io, EMPTY));
        return;
      }
      const prev = chains.get(rec.path) || Promise.resolve();
      const next = prev.then(() => runOne(rec, ticket));
      chains.set(rec.path, next);
      // Keep the map from growing forever: drop the chain once it is idle.
      next.finally(() => {
        if (chains.get(rec.path) === next) chains.delete(rec.path);
      });
    },
  };
}

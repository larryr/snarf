//! The OPFS device's READ and WRITE op bodies (R-9P-09). Namespace module
//! (S-07 P-1) over `*DevOpfs`, carved out of `opfs.zig` verbatim in phase 16a
//! so that file stays inside the ~400-line cap. `DevOpfs` keeps decl aliases
//! (`const read = opfs_io.read;`), so `self.read(...)`/`self.write(...)` and
//! the `ops` table's `readOp`/`writeOp` thunks are unchanged.
//!
//! Both are PARKABLE (`park.WouldBlock` via `DevOpfs.request`): a file read is
//! one `fsOp` round trip, a directory read is one `list` whose answer is cached
//! per fid and then served by offset (`opfs_tree.readListing`).
const ninep = @import("ninep");
const shim = @import("shim");
const tree = @import("opfs_tree.zig");
const DevOpfs = @import("opfs.zig").DevOpfs;

const Fid = ninep.server.Fid;
const ReadError = ninep.server.ReadError;
const OpBlockError = ninep.server.OpBlockError;
const FsRecord = shim.abi.FsRecord;

const Self = DevOpfs;

pub fn read(self: *Self, fid: *Fid, offset: u64, buf: []u8) ReadError!usize {
    const path = try self.pathOf(fid.qid);
    if (fid.qid.qtype.dir) {
        if (self.listings.get(fid.fid) == null) {
            const c = try self.request(fid.fid, .{ .op = .list, .path = path }, fid.qid.path);
            if (c.status != .ok) return tree.statusError(c.status);
            // A fresh listing is fresh truth: nothing memoised about a child
            // of this directory may outlive it (16b item 3).
            self.forgetChildren(path);
            const s = try tree.buildListing(self.allocator, path, c.payload, &self.path_buf);
            self.listings.put(self.allocator, fid.fid, s) catch {
                self.allocator.free(s);
                return error.IoError;
            };
        }
        return tree.readListing(self.listings.get(fid.fid).?, offset, buf);
    }
    if (buf.len == 0) return 0;
    const c = try self.request(fid.fid, .{
        .op = .read,
        .path = path,
        .arg0 = offset,
        .arg1 = @intCast(buf.len),
    }, offset);
    if (c.status != .ok) return tree.statusError(c.status);
    const n = @min(buf.len, c.payload.len);
    @memcpy(buf[0..n], c.payload[0..n]);
    return n;
}

pub fn write(self: *Self, fid: *Fid, offset: u64, data: []const u8) OpBlockError!usize {
    if (fid.qid.qtype.dir) return error.FileIsDirectory;
    const path = try self.pathOf(fid.qid);
    const c = try self.request(fid.fid, .{
        .op = .write,
        .path = path,
        .arg0 = offset,
        .payload = data,
    }, offset);
    if (c.status != .ok) return tree.statusError(c.status);
    self.forgetStat(path); // the length and mtime just changed (16b item 3)
    return @min(data.len, FsRecord.decodeWriteCount(c.payload));
}

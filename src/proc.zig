//! macOS process introspection. Used to pull the shell's current working
//! directory so tab labels can reflect the live folder.
//!
//! Hand-rolled binding to `proc_pidinfo(PROC_PIDVNODEPATHINFO, ...)` — the
//! @cImport route pulls in mach headers that don't translate.

const std = @import("std");

extern fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;

const PROC_PIDVNODEPATHINFO: c_int = 9;
const STRUCT_SIZE: usize = 2352;
const CDIR_PATH_OFFSET: usize = 152;
const MAXPATHLEN: usize = 1024;

/// Write the current working directory of `pid` into `buf` and return the
/// slice. Returns null on failure (process gone, no permission, truncated
/// buffer).
pub fn cwdOf(pid: c_int, buf: []u8) ?[]const u8 {
    var info: [STRUCT_SIZE]u8 = undefined;
    const sz = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info[0], STRUCT_SIZE);
    if (sz <= 0) return null;
    // The path field is a NUL-terminated UTF-8 string at a fixed offset.
    var end = CDIR_PATH_OFFSET;
    const limit = @min(info.len, CDIR_PATH_OFFSET + MAXPATHLEN);
    while (end < limit and info[end] != 0) end += 1;
    if (end == CDIR_PATH_OFFSET) return null;
    const path = info[CDIR_PATH_OFFSET..end];
    if (path.len > buf.len) return null;
    std.mem.copyForwards(u8, buf[0..path.len], path);
    return buf[0..path.len];
}

pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    return path[start..end];
}

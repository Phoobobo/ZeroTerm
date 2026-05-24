//! Pseudo-terminal wrapper. Uses libutil's forkpty(3) — the macOS-blessed way
//! to spawn a child with its own controlling tty. The master fd is what the
//! terminal app reads/writes to talk to the shell.

const std = @import("std");

const c = @cImport({
    @cInclude("util.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

pub const Pty = struct {
    master: c_int,
    pid: c.pid_t,

    pub fn spawn(shell: [*:0]const u8, cols: u16, rows: u16) !Pty {
        var master: c_int = -1;
        var ws = c.struct_winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        const pid = c.forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            // Child: set TERM, then exec the shell as a login shell. execvp
            // uses the parent-inherited environ; setenv updates one entry.
            _ = c.setenv("TERM", "xterm-256color", 1);
            _ = c.setenv("COLORTERM", "truecolor", 1);
            const argv = [_:null]?[*:0]const u8{ shell, "-l", null };
            _ = c.execvp(shell, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        // Parent: set master fd non-blocking so dispatch_source reads don't
        // ever stall the main queue.
        const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);
        return .{ .master = master, .pid = pid };
    }

    pub fn resize(self: Pty, cols: u16, rows: u16) !void {
        var ws = c.struct_winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.master, c.TIOCSWINSZ, &ws) < 0) return error.ResizeFailed;
    }

    pub const ReadStatus = enum { got, would_block, eof };
    pub const ReadResult = struct { n: usize, status: ReadStatus };

    pub fn read(self: Pty, buf: []u8) ReadResult {
        const n = c.read(self.master, buf.ptr, buf.len);
        if (n > 0) return .{ .n = @intCast(n), .status = .got };
        if (n == 0) return .{ .n = 0, .status = .eof };
        const e = std.c._errno().*;
        if (e == c.EAGAIN) return .{ .n = 0, .status = .would_block };
        return .{ .n = 0, .status = .eof };
    }

    pub fn write(self: Pty, buf: []const u8) !usize {
        const n = c.write(self.master, buf.ptr, buf.len);
        if (n < 0) return error.WriteFailed;
        return @intCast(n);
    }

    pub fn close(self: Pty) void {
        _ = c.close(self.master);
    }
};

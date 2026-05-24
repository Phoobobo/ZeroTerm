//! Terminal: owns the PTY, the VT parser, and the screen buffer. Acts as the
//! seam between the OS-side child process and the renderer-side grid.
//!
//! The PTY master fd is pumped by a GCD `dispatch_source` registered on the
//! main queue, so reads run on the same thread as AppKit drawing — no
//! cross-thread locking is needed for the screen.

const std = @import("std");

const objc = @import("objc.zig");
const Pty = @import("pty.zig").Pty;
const parser = @import("vt/parser.zig");
const screen = @import("vt/screen.zig");

/// Set by the UI layer; the dispatch handler calls it whenever a terminal has
/// new output so the view repaints. One global is enough while the project
/// has one window.
var g_dirty: ?*const fn () void = null;

pub fn setDirtyCallback(cb: *const fn () void) void {
    g_dirty = cb;
}

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    pty: Pty,
    parser: parser.Parser,
    primary: screen.Screen,
    alt: screen.Screen,
    use_alt: bool = false,
    bell_until_ms: i64 = 0,
    bracketed_paste: bool = false,
    source: ?objc.id = null,
    title_buf: [256]u8 = undefined,
    title_len: u16 = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        shell: [*:0]const u8,
        cols: u16,
        rows: u16,
    ) !*Terminal {
        const self = try allocator.create(Terminal);
        self.* = .{
            .allocator = allocator,
            .pty = try Pty.spawn(shell, cols, rows),
            .parser = .{},
            .primary = try screen.Screen.init(allocator, cols, rows),
            .alt = try screen.Screen.init(allocator, cols, rows),
        };
        return self;
    }

    pub fn destroy(self: *Terminal) void {
        if (self.source) |s| objc.dispatch_source_cancel(s);
        self.primary.deinit();
        self.alt.deinit();
        self.pty.close();
        self.allocator.destroy(self);
    }

    pub fn currentScreen(self: *Terminal) *screen.Screen {
        return if (self.use_alt) &self.alt else &self.primary;
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return;
        try self.primary.resize(cols, rows);
        try self.alt.resize(cols, rows);
        try self.pty.resize(cols, rows);
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        _ = try self.pty.write(bytes);
    }

    pub fn startPump(self: *Terminal) void {
        const queue = objc.dispatch_get_main_queue();
        const src = objc.dispatch_source_create(
            objc.DISPATCH_SOURCE_TYPE_READ(),
            @intCast(self.pty.master),
            0,
            queue,
        );
        if (src == null) return;
        objc.dispatch_set_context(src, @ptrCast(self));
        objc.dispatch_source_set_event_handler_f(src, &onReadable);
        objc.dispatch_resume(src);
        self.source = src;
    }
};

fn triggerDirty(_: ?*anyopaque) callconv(.c) void {
    if (g_dirty) |cb| cb();
}

fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(ctx orelse return));
    var buf: [4096]u8 = undefined;
    while (true) {
        const res = term.pty.read(&buf);
        switch (res.status) {
            .got => {
                const sink = Sink{ .term = term };
                term.parser.feed(buf[0..res.n], sink);
                if (res.n < buf.len) break;
            },
            .would_block => break,
            .eof => {
                // Shell exited — cancel the source so we stop busy-looping.
                if (term.source) |s| {
                    objc.dispatch_source_cancel(s);
                    term.source = null;
                }
                break;
            },
        }
    }
    if (g_dirty) |cb| cb();
}

const Sink = struct {
    term: *Terminal,

    pub fn print(self: Sink, cp: u21) void {
        self.term.currentScreen().put(cp);
    }

    pub fn execute(self: Sink, b: u8) void {
        const s = self.term.currentScreen();
        switch (b) {
            0x07 => {
                self.term.bell_until_ms = objc.nowMs() + 180;
                const queue = objc.dispatch_get_main_queue();
                const when = objc.dispatch_time(objc.DISPATCH_TIME_NOW, 200 * 1_000_000);
                objc.dispatch_after_f(when, queue, null, &triggerDirty);
            },
            0x08 => s.backspace(),
            0x09 => s.tab(),
            0x0A, 0x0B, 0x0C => s.linefeed(),
            0x0D => s.carriageReturn(),
            else => {},
        }
    }

    pub fn esc(self: Sink, b: u8) void {
        const s = self.term.currentScreen();
        switch (b) {
            '7' => s.saveCursor(),
            '8' => s.restoreCursor(),
            'D' => s.linefeed(),
            'E' => {
                s.linefeed();
                s.carriageReturn();
            },
            'M' => s.scrollDown(1),
            'c' => {
                s.cur_fg = .default;
                s.cur_bg = .default;
                s.cur_attrs = .{};
                s.cursor_col = 0;
                s.cursor_row = 0;
                for (s.cells) |*c| c.* = .{};
            },
            else => {},
        }
    }

    pub fn csi(self: Sink, cmd: parser.CsiCmd) void {
        const s = self.term.currentScreen();
        const params = cmd.params;
        switch (cmd.final) {
            'A' => s.moveRel(0, -csiArg(params, 0, 1)),
            'B' => s.moveRel(0, csiArg(params, 0, 1)),
            'C' => s.moveRel(csiArg(params, 0, 1), 0),
            'D' => s.moveRel(-csiArg(params, 0, 1), 0),
            'E' => {
                s.moveRel(0, csiArg(params, 0, 1));
                s.carriageReturn();
            },
            'F' => {
                s.moveRel(0, -csiArg(params, 0, 1));
                s.carriageReturn();
            },
            'G' => s.moveTo(csiArg(params, 0, 1) - 1, @intCast(s.cursor_row)),
            'H', 'f' => s.moveTo(csiArg(params, 1, 1) - 1, csiArg(params, 0, 1) - 1),
            'J' => s.eraseInDisplay(csiArg(params, 0, 0)),
            'K' => s.eraseInLine(csiArg(params, 0, 0)),
            'S' => s.scrollUp(@intCast(@max(0, csiArg(params, 0, 1)))),
            'T' => s.scrollDown(@intCast(@max(0, csiArg(params, 0, 1)))),
            'd' => s.moveTo(@intCast(s.cursor_col), csiArg(params, 0, 1) - 1),
            'm' => s.setSgr(params),
            'r' => {
                const top_raw = csiArg(params, 0, 1) - 1;
                const bot_raw = csiArg(params, 1, @as(i32, s.rows)) - 1;
                const top: u16 = @intCast(@max(0, @min(top_raw, @as(i32, s.rows) - 1)));
                const bot: u16 = @intCast(@max(0, @min(bot_raw, @as(i32, s.rows) - 1)));
                s.scroll_top = top;
                s.scroll_bot = bot;
                s.moveTo(0, 0);
            },
            'h', 'l' => self.handleMode(cmd),
            'n' => {
                // DSR — device status report. Common: 5 (status) → ESC[0n; 6 (cursor) → ESC[r;cR.
                if (cmd.prefix == 0 and params.len > 0) {
                    switch (params[0]) {
                        5 => self.term.write("\x1b[0n") catch {},
                        6 => {
                            var rbuf: [32]u8 = undefined;
                            const reply = std.fmt.bufPrint(&rbuf, "\x1b[{d};{d}R", .{ s.cursor_row + 1, s.cursor_col + 1 }) catch return;
                            self.term.write(reply) catch {};
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn handleMode(self: Sink, cmd: parser.CsiCmd) void {
        if (cmd.prefix != '?') return;
        const enable = cmd.final == 'h';
        for (cmd.params) |p| switch (p) {
            7 => self.term.currentScreen().wrap = enable,
            25 => self.term.currentScreen().cursor_visible = enable,
            1049, 1047 => {
                // Switch to/from the alternate screen buffer (with cursor save).
                if (enable and !self.term.use_alt) {
                    self.term.primary.saveCursor();
                    self.term.use_alt = true;
                    // Clear alt before showing.
                    for (self.term.alt.cells) |*c| c.* = .{};
                    self.term.alt.cursor_col = 0;
                    self.term.alt.cursor_row = 0;
                    self.term.alt.cur_fg = .default;
                    self.term.alt.cur_bg = .default;
                    self.term.alt.cur_attrs = .{};
                } else if (!enable and self.term.use_alt) {
                    self.term.use_alt = false;
                    self.term.primary.restoreCursor();
                }
            },
            1048 => {
                if (enable) self.term.currentScreen().saveCursor() else self.term.currentScreen().restoreCursor();
            },
            2004 => self.term.bracketed_paste = enable,
            else => {},
        };
    }

    pub fn osc(self: Sink, data: []const u8) void {
        if (data.len < 3) return;
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse return;
        const code = data[0..semi];
        if (std.mem.eql(u8, code, "0") or std.mem.eql(u8, code, "2")) {
            const body = data[semi + 1 ..];
            const n = @min(body.len, self.term.title_buf.len);
            std.mem.copyForwards(u8, self.term.title_buf[0..n], body[0..n]);
            self.term.title_len = @intCast(n);
        }
    }
};

fn csiArg(params: []const i32, i: usize, default: i32) i32 {
    if (i >= params.len) return default;
    const v = params[i];
    if (v < 0) return default;
    return v;
}

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
    screen: screen.Screen,
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
            .screen = try screen.Screen.init(allocator, cols, rows),
        };
        return self;
    }

    pub fn destroy(self: *Terminal) void {
        if (self.source) |s| objc.dispatch_source_cancel(s);
        self.screen.deinit();
        self.pty.close();
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return;
        try self.screen.resize(cols, rows);
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

fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(ctx orelse return));
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = term.pty.read(&buf) catch return;
        if (n == 0) break;
        const sink = Sink{ .term = term };
        term.parser.feed(buf[0..n], sink);
        if (n < buf.len) break;
    }
    if (g_dirty) |cb| cb();
}

const Sink = struct {
    term: *Terminal,

    pub fn print(self: Sink, cp: u21) void {
        self.term.screen.put(cp);
    }

    pub fn execute(self: Sink, b: u8) void {
        switch (b) {
            0x07 => {}, // BEL — visual bell will hook here later
            0x08 => self.term.screen.backspace(),
            0x09 => self.term.screen.tab(),
            0x0A, 0x0B, 0x0C => self.term.screen.linefeed(),
            0x0D => self.term.screen.carriageReturn(),
            else => {},
        }
    }

    pub fn esc(self: Sink, b: u8) void {
        switch (b) {
            '7' => self.term.screen.saveCursor(),
            '8' => self.term.screen.restoreCursor(),
            'D' => self.term.screen.linefeed(),
            'E' => {
                self.term.screen.linefeed();
                self.term.screen.carriageReturn();
            },
            'M' => self.term.screen.scrollDown(1),
            'c' => {
                self.term.screen.cur_fg = .default;
                self.term.screen.cur_bg = .default;
                self.term.screen.cur_attrs = .{};
                self.term.screen.cursor_col = 0;
                self.term.screen.cursor_row = 0;
                for (self.term.screen.cells) |*c| c.* = .{};
            },
            else => {},
        }
    }

    pub fn csi(self: Sink, cmd: parser.CsiCmd) void {
        const s = &self.term.screen;
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
            'h', 'l' => {
                // DEC private modes — most are mode toggles; common ones:
                if (cmd.prefix == '?') {
                    for (params) |p| switch (p) {
                        25 => s.cursor_visible = (cmd.final == 'h'),
                        else => {},
                    };
                }
            },
            'n' => {}, // device status report — TODO: reply via PTY write
            else => {},
        }
    }

    pub fn osc(self: Sink, data: []const u8) void {
        // OSC 0;title  or  OSC 2;title
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

//! Terminal screen buffer. Row-major flat grid with cursor, SGR state, scroll
//! region, and the standard erase / scroll / move operations. The parser in
//! `vt/parser.zig` drives mutations via the `Terminal` sink in `term.zig`.

const std = @import("std");

pub const Color = union(enum) {
    default,
    palette: u8,
    rgb: [3]u8,
};

pub const Attrs = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    _pad: u4 = 0,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cells: []Cell,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    saved_col: u16 = 0,
    saved_row: u16 = 0,
    scroll_top: u16 = 0,
    scroll_bot: u16 = 0,
    cur_fg: Color = .default,
    cur_bg: Color = .default,
    cur_attrs: Attrs = .{},
    wrap: bool = true,
    cursor_visible: bool = true,
    pending_wrap: bool = false,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const cells = try allocator.alloc(Cell, @as(usize, cols) * rows);
        for (cells) |*c| c.* = .{};
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .scroll_top = 0,
            .scroll_bot = rows - 1,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
    }

    pub fn resize(self: *Screen, cols: u16, rows: u16) !void {
        if (cols == self.cols and rows == self.rows) return;
        const new_cells = try self.allocator.alloc(Cell, @as(usize, cols) * rows);
        for (new_cells) |*c| c.* = .{};

        // Keep the bottom-most `min(old_rows, new_rows)` rows so the cursor /
        // most recent output stays visible. This matches xterm behaviour: when
        // the window shrinks, old top content scrolls off; when it grows, the
        // new room appears below.
        const keep_rows = @min(self.rows, rows);
        const old_top = self.rows - keep_rows;
        const new_top = rows - keep_rows;
        const copy_cols = @min(cols, self.cols);
        var r: u16 = 0;
        while (r < keep_rows) : (r += 1) {
            const src_start = @as(usize, old_top + r) * self.cols;
            const dst_start = @as(usize, new_top + r) * cols;
            std.mem.copyForwards(
                Cell,
                new_cells[dst_start .. dst_start + copy_cols],
                self.cells[src_start .. src_start + copy_cols],
            );
        }
        self.allocator.free(self.cells);
        self.cells = new_cells;

        // Translate cursor row by the same shift we applied to content.
        const row_shift: i32 = @as(i32, rows) - @as(i32, self.rows);
        const new_cursor_row = @as(i32, self.cursor_row) + row_shift;
        self.cursor_row = @intCast(@max(0, @min(new_cursor_row, @as(i32, rows) - 1)));
        if (self.cursor_col >= cols) self.cursor_col = cols - 1;

        self.cols = cols;
        self.rows = rows;
        self.scroll_top = 0;
        self.scroll_bot = rows - 1;
        self.pending_wrap = false;
    }

    pub fn put(self: *Screen, ch: u21) void {
        if (self.pending_wrap and self.wrap) {
            self.cursor_col = 0;
            self.linefeed();
            self.pending_wrap = false;
        }
        if (self.cursor_col >= self.cols) self.cursor_col = self.cols - 1;
        const idx = @as(usize, self.cursor_row) * self.cols + self.cursor_col;
        self.cells[idx] = .{
            .ch = ch,
            .fg = self.cur_fg,
            .bg = self.cur_bg,
            .attrs = self.cur_attrs,
        };
        if (self.cursor_col + 1 < self.cols) {
            self.cursor_col += 1;
        } else {
            self.pending_wrap = true;
        }
    }

    pub fn linefeed(self: *Screen) void {
        self.pending_wrap = false;
        if (self.cursor_row == self.scroll_bot) {
            self.scrollUp(1);
        } else if (self.cursor_row + 1 < self.rows) {
            self.cursor_row += 1;
        }
    }

    pub fn carriageReturn(self: *Screen) void {
        self.cursor_col = 0;
        self.pending_wrap = false;
    }

    pub fn backspace(self: *Screen) void {
        if (self.cursor_col > 0) self.cursor_col -= 1;
        self.pending_wrap = false;
    }

    pub fn tab(self: *Screen) void {
        const next = ((self.cursor_col / 8) + 1) * 8;
        self.cursor_col = if (next < self.cols) @intCast(next) else self.cols - 1;
        self.pending_wrap = false;
    }

    pub fn scrollUp(self: *Screen, n: u16) void {
        if (n == 0) return;
        const top = self.scroll_top;
        const bot = self.scroll_bot;
        const region_rows = bot + 1 - top;
        const shift = @min(n, region_rows);
        const row_len: usize = self.cols;
        var r = top;
        while (r + shift <= bot) : (r += 1) {
            const dst = @as(usize, r) * row_len;
            const src = @as(usize, r + shift) * row_len;
            std.mem.copyForwards(
                Cell,
                self.cells[dst .. dst + row_len],
                self.cells[src .. src + row_len],
            );
        }
        var fr: u16 = bot + 1 - shift;
        while (fr <= bot) : (fr += 1) {
            const off = @as(usize, fr) * row_len;
            for (self.cells[off .. off + row_len]) |*ce| ce.* = .{
                .bg = self.cur_bg,
            };
        }
    }

    pub fn scrollDown(self: *Screen, n: u16) void {
        if (n == 0) return;
        const top = self.scroll_top;
        const bot = self.scroll_bot;
        const region_rows = bot + 1 - top;
        const shift = @min(n, region_rows);
        const row_len: usize = self.cols;
        var r: i32 = @intCast(bot);
        while (r >= @as(i32, top) + @as(i32, shift)) : (r -= 1) {
            const dst = @as(usize, @intCast(r)) * row_len;
            const src = @as(usize, @intCast(r - @as(i32, shift))) * row_len;
            std.mem.copyForwards(
                Cell,
                self.cells[dst .. dst + row_len],
                self.cells[src .. src + row_len],
            );
        }
        var fr: u16 = top;
        while (fr < top + shift) : (fr += 1) {
            const off = @as(usize, fr) * row_len;
            for (self.cells[off .. off + row_len]) |*ce| ce.* = .{
                .bg = self.cur_bg,
            };
        }
    }

    pub fn moveTo(self: *Screen, col: i32, row: i32) void {
        var c = col;
        var r = row;
        if (c < 0) c = 0;
        if (r < 0) r = 0;
        const max_c = @as(i32, self.cols) - 1;
        const max_r = @as(i32, self.rows) - 1;
        if (c > max_c) c = max_c;
        if (r > max_r) r = max_r;
        self.cursor_col = @intCast(c);
        self.cursor_row = @intCast(r);
        self.pending_wrap = false;
    }

    pub fn moveRel(self: *Screen, dx: i32, dy: i32) void {
        self.moveTo(@as(i32, self.cursor_col) + dx, @as(i32, self.cursor_row) + dy);
    }

    pub fn saveCursor(self: *Screen) void {
        self.saved_col = self.cursor_col;
        self.saved_row = self.cursor_row;
    }

    pub fn restoreCursor(self: *Screen) void {
        self.cursor_col = self.saved_col;
        self.cursor_row = self.saved_row;
        self.pending_wrap = false;
    }

    pub fn eraseInDisplay(self: *Screen, mode: i32) void {
        const c0: usize = @as(usize, self.cursor_row) * self.cols + self.cursor_col;
        switch (mode) {
            1 => for (self.cells[0..(c0 + 1)]) |*ce| {
                ce.* = .{ .bg = self.cur_bg };
            },
            2, 3 => for (self.cells) |*ce| {
                ce.* = .{ .bg = self.cur_bg };
            },
            else => for (self.cells[c0..]) |*ce| {
                ce.* = .{ .bg = self.cur_bg };
            },
        }
    }

    pub fn eraseInLine(self: *Screen, mode: i32) void {
        const row_off = @as(usize, self.cursor_row) * self.cols;
        const row_end = row_off + self.cols;
        switch (mode) {
            1 => for (self.cells[row_off..(row_off + self.cursor_col + 1)]) |*ce| {
                ce.* = .{ .bg = self.cur_bg };
            },
            2 => for (self.cells[row_off..row_end]) |*ce| {
                ce.* = .{ .bg = self.cur_bg };
            },
            else => for (self.cells[(row_off + self.cursor_col)..row_end]) |*ce| {
                ce.* = .{ .bg = self.cur_bg };
            },
        }
    }

    pub fn setSgr(self: *Screen, params: []const i32) void {
        if (params.len == 0) {
            self.cur_fg = .default;
            self.cur_bg = .default;
            self.cur_attrs = .{};
            return;
        }
        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            const p = params[i];
            switch (p) {
                -1, 0 => {
                    self.cur_fg = .default;
                    self.cur_bg = .default;
                    self.cur_attrs = .{};
                },
                1 => self.cur_attrs.bold = true,
                3 => self.cur_attrs.italic = true,
                4 => self.cur_attrs.underline = true,
                7 => self.cur_attrs.reverse = true,
                22 => self.cur_attrs.bold = false,
                23 => self.cur_attrs.italic = false,
                24 => self.cur_attrs.underline = false,
                27 => self.cur_attrs.reverse = false,
                30...37 => self.cur_fg = .{ .palette = @intCast(p - 30) },
                38 => i += extendedColor(params, i, &self.cur_fg),
                39 => self.cur_fg = .default,
                40...47 => self.cur_bg = .{ .palette = @intCast(p - 40) },
                48 => i += extendedColor(params, i, &self.cur_bg),
                49 => self.cur_bg = .default,
                90...97 => self.cur_fg = .{ .palette = @intCast(p - 90 + 8) },
                100...107 => self.cur_bg = .{ .palette = @intCast(p - 100 + 8) },
                else => {},
            }
        }
    }
};

/// Parses `5;n` (256-color) or `2;r;g;b` (truecolor) after a `38`/`48` selector.
/// Returns the number of extra parameters consumed.
fn extendedColor(params: []const i32, idx: usize, out: *Color) usize {
    if (idx + 2 < params.len and params[idx + 1] == 5) {
        const c = params[idx + 2];
        out.* = .{ .palette = @intCast(@max(0, @min(255, c))) };
        return 2;
    }
    if (idx + 4 < params.len and params[idx + 1] == 2) {
        out.* = .{ .rgb = .{
            @intCast(@max(0, @min(255, params[idx + 2]))),
            @intCast(@max(0, @min(255, params[idx + 3]))),
            @intCast(@max(0, @min(255, params[idx + 4]))),
        } };
        return 4;
    }
    return 0;
}

test "put writes cell and advances" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();
    s.put('a');
    s.put('b');
    try std.testing.expectEqual(@as(u21, 'a'), s.cells[0].ch);
    try std.testing.expectEqual(@as(u21, 'b'), s.cells[1].ch);
    try std.testing.expectEqual(@as(u16, 2), s.cursor_col);
}

test "linefeed at bottom scrolls" {
    var s = try Screen.init(std.testing.allocator, 2, 2);
    defer s.deinit();
    s.put('a');
    s.put('b');
    s.linefeed();
    s.carriageReturn();
    s.put('c');
    s.put('d');
    s.linefeed();
    try std.testing.expectEqual(@as(u21, 'c'), s.cells[0].ch);
    try std.testing.expectEqual(@as(u21, 'd'), s.cells[1].ch);
}

test "SGR foreground palette + reset" {
    var s = try Screen.init(std.testing.allocator, 5, 1);
    defer s.deinit();
    s.setSgr(&.{31});
    try std.testing.expect(s.cur_fg == .palette);
    try std.testing.expectEqual(@as(u8, 1), s.cur_fg.palette);
    s.setSgr(&.{0});
    try std.testing.expect(s.cur_fg == .default);
}

test "moveTo clamps" {
    var s = try Screen.init(std.testing.allocator, 5, 3);
    defer s.deinit();
    s.moveTo(100, 100);
    try std.testing.expectEqual(@as(u16, 4), s.cursor_col);
    try std.testing.expectEqual(@as(u16, 2), s.cursor_row);
    s.moveTo(-5, -5);
    try std.testing.expectEqual(@as(u16, 0), s.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), s.cursor_row);
}

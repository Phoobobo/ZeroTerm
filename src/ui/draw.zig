//! Core Graphics painting. Visual goal: Kaku's calm "old paper" look — cream
//! background, slim bottom tab strip, dotted dividers between panes, monospace
//! cells inside each leaf.

const std = @import("std");
const objc = @import("../objc.zig");
const font = @import("font.zig");
const st = @import("state.zig");
const term = @import("../term.zig");
const screen_mod = @import("../vt/screen.zig");

const State = st.State;
const Pane = st.Pane;
const Rect = st.Rect;

// Palette tuned for the cream background.
const c_paper = [4]f64{ 0.953, 0.925, 0.870, 1.0 };
const c_tab_active_bg = [4]f64{ 0.890, 0.863, 0.806, 1.0 };
const c_text_active = [4]f64{ 0.180, 0.160, 0.120, 1.0 };
const c_text_muted = [4]f64{ 0.490, 0.450, 0.380, 1.0 };
const c_divider = [4]f64{ 0.580, 0.530, 0.450, 0.55 };
const c_separator = [4]f64{ 0.700, 0.660, 0.580, 0.40 };
const c_active_pane_outline = [4]f64{ 0.640, 0.580, 0.460, 0.45 };
const c_cursor = [4]f64{ 0.180, 0.160, 0.120, 0.32 };

// Default cell colors for the terminal grid.
const c_default_fg = [4]f64{ 0.130, 0.115, 0.085, 1.0 };

// 16-colour ANSI palette tuned for paper. Picked to read well at ~13pt.
const ansi_palette: [16][3]f64 = .{
    .{ 0.07, 0.20, 0.26 }, // 0 black (dark teal/ink)
    .{ 0.78, 0.18, 0.14 }, // 1 red
    .{ 0.40, 0.55, 0.00 }, // 2 green
    .{ 0.69, 0.48, 0.00 }, // 3 yellow / amber
    .{ 0.15, 0.45, 0.74 }, // 4 blue
    .{ 0.62, 0.19, 0.55 }, // 5 magenta
    .{ 0.15, 0.55, 0.55 }, // 6 cyan
    .{ 0.55, 0.50, 0.42 }, // 7 light grey
    .{ 0.45, 0.42, 0.38 }, // 8 bright black
    .{ 0.86, 0.25, 0.16 }, // 9 bright red
    .{ 0.46, 0.61, 0.13 }, // 10 bright green
    .{ 0.78, 0.55, 0.04 }, // 11 bright yellow
    .{ 0.27, 0.55, 0.83 }, // 12 bright blue
    .{ 0.70, 0.27, 0.62 }, // 13 bright magenta
    .{ 0.18, 0.62, 0.62 }, // 14 bright cyan
    .{ 0.32, 0.28, 0.22 }, // 15 bright white (deep ink)
};

const tab_bar_h: f64 = 28.0;
const tab_padding_x: f64 = 12.0;
const tab_gap: f64 = 4.0;
const tab_font_size: f64 = 11.0;

pub fn render(ctx: objc.CGContextRef, bounds: objc.NSRect, state: *State) void {
    state.tab_hits.clearRetainingCapacity();
    state.pane_hits.clearRetainingCapacity();

    // 1. Paper background.
    setFill(ctx, c_paper);
    objc.CGContextFillRect(ctx, bounds);

    // 2. Pane area — everything above the tab strip.
    const pane_area = Rect{
        .x = bounds.origin.x,
        .y = bounds.origin.y + tab_bar_h,
        .w = bounds.size.w,
        .h = bounds.size.h - tab_bar_h,
    };
    drawPane(ctx, state.currentTab().root, pane_area, state);

    // 3. Separator above the tab strip.
    strokeLine(
        ctx,
        bounds.origin.x,
        bounds.origin.y + tab_bar_h,
        bounds.origin.x + bounds.size.w,
        bounds.origin.y + tab_bar_h,
        1.0,
        c_separator,
        null,
    );

    // 4. Tab strip.
    drawTabs(ctx, bounds, state);
}

fn drawPane(ctx: objc.CGContextRef, pane: *Pane, rect: Rect, state: *State) void {
    switch (pane.*) {
        .leaf => |l| {
            state.pane_hits.append(state.allocator, .{ .id = l.id, .rect = rect }) catch {};
            if (l.terminal) |t| {
                drawTerminal(ctx, t, rect, l.id == state.currentTab().active);
            } else if (l.id == state.currentTab().active and state.pane_hits.items.len > 1) {
                strokeRect(ctx, inset(rect, 1.0), 1.0, c_active_pane_outline);
            }
        },
        .split => |s| switch (s.kind) {
            .side_by_side => {
                const left_w = rect.w * @as(f64, s.ratio);
                const left = Rect{ .x = rect.x, .y = rect.y, .w = left_w, .h = rect.h };
                const right = Rect{ .x = rect.x + left_w, .y = rect.y, .w = rect.w - left_w, .h = rect.h };
                drawPane(ctx, s.a, left, state);
                drawPane(ctx, s.b, right, state);
                strokeLine(
                    ctx,
                    rect.x + left_w,
                    rect.y + 4,
                    rect.x + left_w,
                    rect.y + rect.h - 4,
                    1.0,
                    c_divider,
                    &.{ 2.0, 3.0 },
                );
            },
            .top_bottom => {
                const top_h = rect.h * @as(f64, s.ratio);
                const top = Rect{ .x = rect.x, .y = rect.y + rect.h - top_h, .w = rect.w, .h = top_h };
                const bot = Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h - top_h };
                drawPane(ctx, s.a, top, state);
                drawPane(ctx, s.b, bot, state);
                strokeLine(
                    ctx,
                    rect.x + 4,
                    rect.y + rect.h - top_h,
                    rect.x + rect.w - 4,
                    rect.y + rect.h - top_h,
                    1.0,
                    c_divider,
                    &.{ 2.0, 3.0 },
                );
            },
        },
    }
}

fn drawTerminal(ctx: objc.CGContextRef, t: *term.Terminal, rect: Rect, focused: bool) void {
    const cell_w = font.metrics.cell_w;
    const cell_h = font.metrics.cell_h;
    // Resize the terminal to match the available rect.
    const want_cols: u16 = @intCast(@max(1, @as(i64, @intFromFloat(@floor(rect.w / cell_w)))));
    const want_rows: u16 = @intCast(@max(1, @as(i64, @intFromFloat(@floor(rect.h / cell_h)))));
    const sc_check = t.currentScreen();
    if (want_cols != sc_check.cols or want_rows != sc_check.rows) {
        t.resize(want_cols, want_rows) catch {};
    }

    const sc = t.currentScreen();

    // Background pass.
    var row: u16 = 0;
    while (row < sc.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < sc.cols) : (col += 1) {
            const cell = sc.cells[@as(usize, row) * sc.cols + col];
            const draw_bg = if (cell.attrs.reverse) cell.fg else cell.bg;
            if (draw_bg != .default) {
                const rgb = colorRgb(draw_bg);
                const x0 = rect.x + @as(f64, @floatFromInt(col)) * cell_w;
                const y0 = rect.y + rect.h - @as(f64, @floatFromInt(row + 1)) * cell_h;
                setFill(ctx, .{ rgb[0], rgb[1], rgb[2], 1.0 });
                objc.CGContextFillRect(ctx, .{
                    .origin = .{ .x = x0, .y = y0 },
                    .size = .{ .w = cell_w + 0.5, .h = cell_h + 0.5 },
                });
            }
        }
    }

    // Foreground pass — runs of equal style per row.
    var rrow: u16 = 0;
    var text_buf: [4096]u8 = undefined;
    while (rrow < sc.rows) : (rrow += 1) {
        var col: u16 = 0;
        while (col < sc.cols) {
            const start = col;
            const c0 = sc.cells[@as(usize, rrow) * sc.cols + start];
            var text_len: usize = 0;
            // Build run.
            while (col < sc.cols) : (col += 1) {
                const cn = sc.cells[@as(usize, rrow) * sc.cols + col];
                if (!sameStyle(c0, cn)) break;
                if (text_len + 4 > text_buf.len) break;
                text_len += encodeUtf8(cn.ch, text_buf[text_len..]);
            }
            if (col == start) col += 1; // safety
            const all_blank = blk: {
                var i: u16 = start;
                while (i < col) : (i += 1) {
                    const cc = sc.cells[@as(usize, rrow) * sc.cols + i];
                    if (cc.ch != ' ' or cc.attrs.underline) break :blk false;
                }
                break :blk true;
            };
            if (all_blank) continue;
            const fg_color = if (c0.attrs.reverse) c0.bg else c0.fg;
            const fg_rgb = colorFgRgb(fg_color);
            const point = objc.NSPoint{
                .x = rect.x + @as(f64, @floatFromInt(start)) * cell_w,
                .y = rect.y + rect.h - @as(f64, @floatFromInt(rrow + 1)) * cell_h,
            };
            const attrs = font.attrs(.{ fg_rgb[0], fg_rgb[1], fg_rgb[2], 1.0 });
            drawTextSlice(text_buf[0..text_len], point, attrs);
        }
    }

    // Cursor.
    if (focused and sc.cursor_visible and sc.cursor_row < sc.rows and sc.cursor_col < sc.cols) {
        const x0 = rect.x + @as(f64, @floatFromInt(sc.cursor_col)) * cell_w;
        const y0 = rect.y + rect.h - @as(f64, @floatFromInt(sc.cursor_row + 1)) * cell_h;
        setFill(ctx, c_cursor);
        objc.CGContextFillRect(ctx, .{
            .origin = .{ .x = x0, .y = y0 },
            .size = .{ .w = cell_w, .h = cell_h },
        });
    }
}

fn sameStyle(a: screen_mod.Cell, b: screen_mod.Cell) bool {
    if (@as(std.meta.Tag(screen_mod.Color), a.fg) != @as(std.meta.Tag(screen_mod.Color), b.fg)) return false;
    if (@as(std.meta.Tag(screen_mod.Color), a.bg) != @as(std.meta.Tag(screen_mod.Color), b.bg)) return false;
    return colorEql(a.fg, b.fg) and colorEql(a.bg, b.bg) and
        a.attrs.bold == b.attrs.bold and
        a.attrs.italic == b.attrs.italic and
        a.attrs.underline == b.attrs.underline and
        a.attrs.reverse == b.attrs.reverse;
}

fn colorEql(a: screen_mod.Color, b: screen_mod.Color) bool {
    return switch (a) {
        .default => b == .default,
        .palette => |x| b == .palette and b.palette == x,
        .rgb => |x| b == .rgb and std.mem.eql(u8, &x, &b.rgb),
    };
}

fn colorRgb(color: screen_mod.Color) [3]f64 {
    return switch (color) {
        .default => .{ c_paper[0], c_paper[1], c_paper[2] },
        .palette => |idx| palette256(idx),
        .rgb => |c| .{
            @as(f64, @floatFromInt(c[0])) / 255.0,
            @as(f64, @floatFromInt(c[1])) / 255.0,
            @as(f64, @floatFromInt(c[2])) / 255.0,
        },
    };
}

fn colorFgRgb(color: screen_mod.Color) [3]f64 {
    return switch (color) {
        .default => .{ c_default_fg[0], c_default_fg[1], c_default_fg[2] },
        .palette => |idx| palette256(idx),
        .rgb => |c| .{
            @as(f64, @floatFromInt(c[0])) / 255.0,
            @as(f64, @floatFromInt(c[1])) / 255.0,
            @as(f64, @floatFromInt(c[2])) / 255.0,
        },
    };
}

fn palette256(idx: u8) [3]f64 {
    if (idx < 16) return ansi_palette[idx];
    if (idx < 232) {
        // 6x6x6 cube
        const n = idx - 16;
        const r = n / 36;
        const g = (n % 36) / 6;
        const b = n % 6;
        const lvls = [_]f64{ 0.0, 0.37, 0.53, 0.69, 0.82, 1.0 };
        return .{ lvls[r], lvls[g], lvls[b] };
    }
    // 232..255 greyscale
    const g = @as(f64, @floatFromInt(idx - 232)) / 23.0;
    return .{ g, g, g };
}

fn drawTabs(ctx: objc.CGContextRef, bounds: objc.NSRect, state: *State) void {
    const bar_y = bounds.origin.y;
    var x = bounds.origin.x + tab_padding_x;
    const attrs_active = makeTextAttrs(tab_font_size, c_text_active);
    const attrs_muted = makeTextAttrs(tab_font_size, c_text_muted);

    for (state.tabs.items, 0..) |tab, idx| {
        const is_active = (idx == state.active_tab);
        const text_w = measureText(tab.name, attrs_muted);
        const slot_w = text_w + 18;
        const slot_rect = Rect{ .x = x, .y = bar_y + 4, .w = slot_w, .h = tab_bar_h - 8 };
        if (is_active) {
            setFill(ctx, c_tab_active_bg);
            objc.CGContextFillRect(ctx, .{
                .origin = .{ .x = slot_rect.x, .y = slot_rect.y },
                .size = .{ .w = slot_rect.w, .h = slot_rect.h },
            });
        }
        drawString(tab.name, .{ .x = x + 9, .y = bar_y + 7 }, if (is_active) attrs_active else attrs_muted);
        state.tab_hits.append(state.allocator, .{ .idx = idx, .rect = slot_rect }) catch {};
        x += slot_w + tab_gap;
    }
}

fn inset(r: Rect, by: f64) Rect {
    return .{ .x = r.x + by, .y = r.y + by, .w = r.w - 2 * by, .h = r.h - 2 * by };
}

fn setFill(ctx: objc.CGContextRef, c: [4]f64) void {
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], c[3]);
}

fn strokeRect(ctx: objc.CGContextRef, r: Rect, width: f64, color: [4]f64) void {
    objc.CGContextSetRGBStrokeColor(ctx, color[0], color[1], color[2], color[3]);
    objc.CGContextSetLineWidth(ctx, width);
    objc.CGContextSetLineDash(ctx, 0, null, 0);
    objc.CGContextBeginPath(ctx);
    objc.CGContextMoveToPoint(ctx, r.x, r.y);
    objc.CGContextAddLineToPoint(ctx, r.x + r.w, r.y);
    objc.CGContextAddLineToPoint(ctx, r.x + r.w, r.y + r.h);
    objc.CGContextAddLineToPoint(ctx, r.x, r.y + r.h);
    objc.CGContextAddLineToPoint(ctx, r.x, r.y);
    objc.CGContextStrokePath(ctx);
}

fn strokeLine(ctx: objc.CGContextRef, x1: f64, y1: f64, x2: f64, y2: f64, width: f64, color: [4]f64, dash: ?[]const f64) void {
    objc.CGContextSetRGBStrokeColor(ctx, color[0], color[1], color[2], color[3]);
    objc.CGContextSetLineWidth(ctx, width);
    if (dash) |d| objc.CGContextSetLineDash(ctx, 0, d.ptr, d.len) else objc.CGContextSetLineDash(ctx, 0, null, 0);
    objc.CGContextBeginPath(ctx);
    objc.CGContextMoveToPoint(ctx, x1, y1);
    objc.CGContextAddLineToPoint(ctx, x2, y2);
    objc.CGContextStrokePath(ctx);
    objc.CGContextSetLineDash(ctx, 0, null, 0);
}

fn makeTextAttrs(font_size: f64, color: [4]f64) objc.id {
    const NSFont = objc.cls("NSFont");
    const NSColor = objc.cls("NSColor");
    const NSMutableDictionary = objc.cls("NSMutableDictionary");
    const f = objc.send1(objc.id, NSFont, objc.sel("systemFontOfSize:"), font_size);
    const color_obj = objc.send4(
        objc.id,
        NSColor,
        objc.sel("colorWithSRGBRed:green:blue:alpha:"),
        color[0],
        color[1],
        color[2],
        color[3],
    );
    const dict = objc.send(objc.id, NSMutableDictionary, objc.sel("dictionary"));
    _ = objc.send2(void, dict, objc.sel("setObject:forKey:"), f, objc.NSFontAttributeName);
    _ = objc.send2(void, dict, objc.sel("setObject:forKey:"), color_obj, objc.NSForegroundColorAttributeName);
    return dict;
}

fn nsStringFromZ(text: []const u8) objc.id {
    var buf: [4096]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    std.mem.copyForwards(u8, buf[0..n], text[0..n]);
    buf[n] = 0;
    return objc.send1(
        objc.id,
        objc.cls("NSString"),
        objc.sel("stringWithUTF8String:"),
        @as([*:0]const u8, @ptrCast(&buf[0])),
    );
}

fn drawString(text: []const u8, point: objc.NSPoint, attrs: objc.id) void {
    const str = nsStringFromZ(text);
    _ = objc.send2(void, str, objc.sel("drawAtPoint:withAttributes:"), point, attrs);
}

fn drawTextSlice(text: []const u8, point: objc.NSPoint, attrs: objc.id) void {
    drawString(text, point, attrs);
}

fn measureText(text: []const u8, attrs: objc.id) f64 {
    const str = nsStringFromZ(text);
    const sz = objc.send1(objc.NSSize, str, objc.sel("sizeWithAttributes:"), attrs);
    return sz.w;
}

fn encodeUtf8(cp: u21, out: []u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

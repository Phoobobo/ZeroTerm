//! Core Graphics painting. Visual goal: Kaku's calm "old paper" look — cream
//! background, slim bottom tab strip, dotted dividers between panes, monospace
//! cells inside each leaf.

const std = @import("std");
const objc = @import("../objc.zig");
const font = @import("font.zig");
const st = @import("state.zig");
const term = @import("../term.zig");
const screen_mod = @import("../vt/screen.zig");
const proc = @import("../proc.zig");

const State = st.State;
const Pane = st.Pane;
const Rect = st.Rect;

/// Theme palette. Two presets — paper-light and ink-dark — picked at startup
/// from `NSApp.effectiveAppearance` and refreshed on macOS appearance changes.
const Palette = struct {
    paper: [4]f64,
    tab_active_bg: [4]f64,
    text_active: [4]f64,
    text_muted: [4]f64,
    divider: [4]f64,
    separator: [4]f64,
    active_pane_outline: [4]f64,
    cursor: [4]f64,
    selection: [4]f64,
    bell_flash: [4]f64,
    default_fg: [4]f64,
    ansi: [16][3]f64,
};

const palette_light: Palette = .{
    .paper = .{ 0.953, 0.925, 0.870, 1.0 },
    .tab_active_bg = .{ 0.890, 0.863, 0.806, 1.0 },
    .text_active = .{ 0.180, 0.160, 0.120, 1.0 },
    .text_muted = .{ 0.490, 0.450, 0.380, 1.0 },
    .divider = .{ 0.580, 0.530, 0.450, 0.55 },
    .separator = .{ 0.700, 0.660, 0.580, 0.40 },
    .active_pane_outline = .{ 0.640, 0.580, 0.460, 0.45 },
    .cursor = .{ 0.180, 0.160, 0.120, 0.32 },
    .selection = .{ 0.620, 0.550, 0.410, 0.28 },
    .bell_flash = .{ 0.85, 0.55, 0.10, 0.35 },
    .default_fg = .{ 0.130, 0.115, 0.085, 1.0 },
    .ansi = .{
        .{ 0.07, 0.20, 0.26 },
        .{ 0.78, 0.18, 0.14 },
        .{ 0.40, 0.55, 0.00 },
        .{ 0.69, 0.48, 0.00 },
        .{ 0.15, 0.45, 0.74 },
        .{ 0.62, 0.19, 0.55 },
        .{ 0.15, 0.55, 0.55 },
        .{ 0.55, 0.50, 0.42 },
        .{ 0.45, 0.42, 0.38 },
        .{ 0.86, 0.25, 0.16 },
        .{ 0.46, 0.61, 0.13 },
        .{ 0.78, 0.55, 0.04 },
        .{ 0.27, 0.55, 0.83 },
        .{ 0.70, 0.27, 0.62 },
        .{ 0.18, 0.62, 0.62 },
        .{ 0.32, 0.28, 0.22 },
    },
};

const palette_dark: Palette = .{
    .paper = .{ 0.090, 0.092, 0.110, 1.0 },
    .tab_active_bg = .{ 0.150, 0.152, 0.180, 1.0 },
    .text_active = .{ 0.910, 0.890, 0.820, 1.0 },
    .text_muted = .{ 0.520, 0.510, 0.470, 1.0 },
    .divider = .{ 0.420, 0.420, 0.470, 0.55 },
    .separator = .{ 0.260, 0.260, 0.310, 0.55 },
    .active_pane_outline = .{ 0.520, 0.500, 0.420, 0.40 },
    .cursor = .{ 0.910, 0.890, 0.820, 0.34 },
    .selection = .{ 0.460, 0.440, 0.360, 0.32 },
    .bell_flash = .{ 0.90, 0.55, 0.20, 0.30 },
    .default_fg = .{ 0.910, 0.890, 0.820, 1.0 },
    .ansi = .{
        .{ 0.16, 0.16, 0.20 },
        .{ 0.90, 0.30, 0.30 },
        .{ 0.55, 0.78, 0.40 },
        .{ 0.92, 0.78, 0.30 },
        .{ 0.45, 0.70, 0.95 },
        .{ 0.85, 0.50, 0.85 },
        .{ 0.40, 0.85, 0.85 },
        .{ 0.80, 0.78, 0.72 },
        .{ 0.40, 0.40, 0.46 },
        .{ 1.00, 0.45, 0.40 },
        .{ 0.65, 0.92, 0.55 },
        .{ 1.00, 0.88, 0.40 },
        .{ 0.55, 0.80, 1.00 },
        .{ 0.95, 0.60, 0.95 },
        .{ 0.50, 0.95, 0.95 },
        .{ 0.95, 0.93, 0.86 },
    },
};

var palette: *const Palette = &palette_light;

pub fn setDark(dark: bool) void {
    palette = if (dark) &palette_dark else &palette_light;
}

pub fn refreshAppearance() void {
    const NSApplication = objc.cls("NSApplication");
    const shared = objc.send(objc.id, NSApplication, objc.sel("sharedApplication"));
    const app_obj = if (shared == null) return else shared;
    const appearance = objc.send(objc.id, app_obj, objc.sel("effectiveAppearance"));
    if (appearance == null) return;
    const name_obj = objc.send(objc.id, appearance, objc.sel("name"));
    if (name_obj == null) return;
    const utf8: ?[*:0]const u8 = objc.send(?[*:0]const u8, name_obj, objc.sel("UTF8String"));
    if (utf8) |p| {
        const slice = std.mem.span(p);
        setDark(std.mem.indexOf(u8, slice, "Dark") != null);
    }
}

const tab_bar_h: f64 = 28.0;
const title_pad_h: f64 = 28.0;
const tab_padding_x: f64 = 12.0;
const tab_gap: f64 = 4.0;
const tab_font_size: f64 = 11.0;

pub fn render(ctx: objc.CGContextRef, bounds: objc.NSRect, state: *State) void {
    state.tab_hits.clearRetainingCapacity();
    state.pane_hits.clearRetainingCapacity();

    // 1. Paper background.
    setFill(ctx, palette.paper);
    objc.CGContextFillRect(ctx, bounds);

    // 2. Pane area — between the tab strip at the bottom and the area
    // reserved for the (transparent) titlebar at the top.
    const pane_area = Rect{
        .x = bounds.origin.x,
        .y = bounds.origin.y + tab_bar_h,
        .w = bounds.size.w,
        .h = bounds.size.h - tab_bar_h - title_pad_h,
    };
    if (state.zoomed_leaf) |zid| {
        // Walk to find the zoomed leaf and render only it, filling pane_area.
        if (zoomedLeafPane(state.currentTab().root, zid)) |p| {
            drawPane(ctx, p, pane_area, state);
        } else {
            // Stale zoom id (pane was closed) — fall back to normal tree.
            drawPane(ctx, state.currentTab().root, pane_area, state);
        }
    } else {
        drawPane(ctx, state.currentTab().root, pane_area, state);
    }

    // 3. Separator above the tab strip.
    strokeLine(
        ctx,
        bounds.origin.x,
        bounds.origin.y + tab_bar_h,
        bounds.origin.x + bounds.size.w,
        bounds.origin.y + tab_bar_h,
        1.0,
        palette.separator,
        null,
    );

    // 4. Tab strip.
    drawTabs(ctx, bounds, state);
}

fn zoomedLeafPane(p: *Pane, id: st.PaneId) ?*Pane {
    return switch (p.*) {
        .leaf => |l| if (l.id == id) p else null,
        .split => |s| zoomedLeafPane(s.a, id) orelse zoomedLeafPane(s.b, id),
    };
}

fn drawPane(ctx: objc.CGContextRef, pane: *Pane, rect: Rect, state: *State) void {
    switch (pane.*) {
        .leaf => |l| {
            state.pane_hits.append(state.allocator, .{ .id = l.id, .rect = rect }) catch {};
            if (l.terminal) |t| {
                const focused = l.id == state.currentTab().active;
                const sel: ?st.Selection = if (state.selection) |s| (if (s.pane_id == l.id) s else null) else null;
                drawTerminal(ctx, t, rect, focused, sel);
            } else if (l.id == state.currentTab().active and state.pane_hits.items.len > 1) {
                strokeRect(ctx, inset(rect, 1.0), 1.0, palette.active_pane_outline);
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
                    palette.divider,
                    null,
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
                    palette.divider,
                    null,
                );
            },
        },
    }
}

fn drawTerminal(ctx: objc.CGContextRef, t: *term.Terminal, rect: Rect, focused: bool, sel: ?st.Selection) void {
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
    const view_offset = sc.view_offset;
    const sb_len: i64 = @intCast(sc.scrollback.items.len);

    // Helper: fetch the cell at display row r, col c, honouring scrollback view.
    const cellAt = struct {
        fn get(scr: *const screen_mod.Screen, sb: i64, vo: u32, r: u16, c: u16) screen_mod.Cell {
            const virtual_idx: i64 = sb + @as(i64, r) - @as(i64, vo);
            if (virtual_idx < sb) {
                if (virtual_idx < 0) return .{};
                const row_data = scr.scrollback.items[@as(usize, @intCast(virtual_idx))];
                if (c < row_data.cells.len) return row_data.cells[c];
                return .{};
            }
            const live_r: usize = @intCast(virtual_idx - sb);
            if (live_r >= scr.rows) return .{};
            return scr.cells[live_r * scr.cols + c];
        }
    }.get;

    // Background pass.
    var row: u16 = 0;
    while (row < sc.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < sc.cols) : (col += 1) {
            const cell = cellAt(sc, sb_len, view_offset, row, col);
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
            const c0 = cellAt(sc, sb_len, view_offset, rrow, start);
            var text_len: usize = 0;
            // Build run.
            while (col < sc.cols) : (col += 1) {
                const cn = cellAt(sc, sb_len, view_offset, rrow, col);
                if (!sameStyle(c0, cn)) break;
                if (text_len + 4 > text_buf.len) break;
                text_len += encodeUtf8(cn.ch, text_buf[text_len..]);
            }
            if (col == start) col += 1; // safety
            const all_blank = blk: {
                var i: u16 = start;
                while (i < col) : (i += 1) {
                    const cc = cellAt(sc, sb_len, view_offset, rrow, i);
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

    // Selection overlay (drawn after text so the highlight reads on top).
    if (sel) |s| {
        const norm = st.normalizedSelection(s);
        var sr: u16 = norm.sr;
        while (sr <= norm.er and sr < sc.rows) : (sr += 1) {
            const start_col: u16 = if (sr == norm.sr) norm.sc else 0;
            const end_col: u16 = if (sr == norm.er) @min(norm.ec, sc.cols - 1) else sc.cols - 1;
            const cells_in_row: u16 = end_col + 1 - start_col;
            const x0 = rect.x + @as(f64, @floatFromInt(start_col)) * cell_w;
            const y0 = rect.y + rect.h - @as(f64, @floatFromInt(sr + 1)) * cell_h;
            setFill(ctx, palette.selection);
            objc.CGContextFillRect(ctx, .{
                .origin = .{ .x = x0, .y = y0 },
                .size = .{ .w = @as(f64, @floatFromInt(cells_in_row)) * cell_w, .h = cell_h },
            });
        }
    }

    // Visual bell — soft amber flash over the pane while bell is active.
    if (objc.nowMs() < t.bell_until_ms) {
        setFill(ctx, palette.bell_flash);
        objc.CGContextFillRect(ctx, .{
            .origin = .{ .x = rect.x, .y = rect.y },
            .size = .{ .w = rect.w, .h = rect.h },
        });
    }

    // Cursor — only when viewing the live screen.
    if (focused and view_offset == 0 and sc.cursor_visible and sc.cursor_row < sc.rows and sc.cursor_col < sc.cols) {
        const x0 = rect.x + @as(f64, @floatFromInt(sc.cursor_col)) * cell_w;
        const y0 = rect.y + rect.h - @as(f64, @floatFromInt(sc.cursor_row + 1)) * cell_h;
        setFill(ctx, palette.cursor);
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
        .default => .{ palette.paper[0], palette.paper[1], palette.paper[2] },
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
        .default => .{ palette.default_fg[0], palette.default_fg[1], palette.default_fg[2] },
        .palette => |idx| palette256(idx),
        .rgb => |c| .{
            @as(f64, @floatFromInt(c[0])) / 255.0,
            @as(f64, @floatFromInt(c[1])) / 255.0,
            @as(f64, @floatFromInt(c[2])) / 255.0,
        },
    };
}

fn palette256(idx: u8) [3]f64 {
    if (idx < 16) return palette.ansi[idx];
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
    const attrs_active = makeTextAttrs(tab_font_size, palette.text_active);
    const attrs_muted = makeTextAttrs(tab_font_size, palette.text_muted);

    var cwd_buf: [1024]u8 = undefined;

    for (state.tabs.items, 0..) |tab, idx| {
        const is_active = (idx == state.active_tab);
        const label = tabLabel(tab, &cwd_buf);
        const text_w = measureText(label, attrs_muted);
        const slot_w = text_w + 18;
        const slot_rect = Rect{ .x = x, .y = bar_y + 4, .w = slot_w, .h = tab_bar_h - 8 };
        if (is_active) {
            setFill(ctx, palette.tab_active_bg);
            objc.CGContextFillRect(ctx, .{
                .origin = .{ .x = slot_rect.x, .y = slot_rect.y },
                .size = .{ .w = slot_rect.w, .h = slot_rect.h },
            });
        }
        drawString(label, .{ .x = x + 9, .y = bar_y + 7 }, if (is_active) attrs_active else attrs_muted);
        state.tab_hits.append(state.allocator, .{ .idx = idx, .rect = slot_rect }) catch {};
        x += slot_w + tab_gap;
    }
}

/// Display name for a tab: the basename of the focused shell's cwd. Falls
/// back to the stored tab.name (e.g. "session 1") if proc_pidinfo can't
/// resolve the cwd.
fn tabLabel(tab: *st.Tab, buf: []u8) []const u8 {
    const t = findTerminal(tab.root, tab.active) orelse return tab.name;
    const cwd = proc.cwdOf(t.pty.pid, buf) orelse return tab.name;
    const name = proc.basename(cwd);
    if (name.len == 0) return tab.name;
    return name;
}

fn findTerminal(p: *st.Pane, id: st.PaneId) ?*term.Terminal {
    return switch (p.*) {
        .leaf => |l| if (l.id == id) l.terminal else null,
        .split => |s| findTerminal(s.a, id) orelse findTerminal(s.b, id),
    };
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

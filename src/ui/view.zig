//! Custom NSView subclass built via the Objective-C runtime. Overrides
//! drawRect:, keyDown:, mouseDown:, and acceptsFirstResponder to route AppKit
//! events into the Zig-side `State`.

const std = @import("std");
const objc = @import("../objc.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const st = @import("state.zig");
const term = @import("../term.zig");
const windows = @import("windows.zig");

const State = st.State;
const SplitKind = st.SplitKind;

fn ctxOf(view_self: objc.id) ?*windows.WindowCtx {
    return windows.findByView(view_self);
}

fn stateOf(view_self: objc.id) ?*State {
    if (windows.findByView(view_self)) |ctx| return &ctx.state;
    return null;
}

const NSEventModifierFlagShift: u64 = 1 << 17;
const NSEventModifierFlagControl: u64 = 1 << 18;
const NSEventModifierFlagOption: u64 = 1 << 19;
const NSEventModifierFlagCommand: u64 = 1 << 20;

// Function-key constants from NSEvent.h (the Unicode private-use codes that
// charactersIgnoringModifiers reports for special keys).
const NSUpArrowFunctionKey: u32 = 0xF700;
const NSDownArrowFunctionKey: u32 = 0xF701;
const NSLeftArrowFunctionKey: u32 = 0xF702;
const NSRightArrowFunctionKey: u32 = 0xF703;
const NSF1FunctionKey: u32 = 0xF704;
const NSF12FunctionKey: u32 = 0xF70F;
const NSHomeFunctionKey: u32 = 0xF729;
const NSEndFunctionKey: u32 = 0xF72B;
const NSPageUpFunctionKey: u32 = 0xF72C;
const NSPageDownFunctionKey: u32 = 0xF72D;
const NSDeleteFunctionKey: u32 = 0xF728;

const class_name: [*:0]const u8 = "ZTRootView";

pub fn registerClass() objc.Class {
    if (objc.objc_getClass(class_name)) |existing| return existing;
    const super = objc.cls("NSView");
    const cls = objc.objc_allocateClassPair(super, class_name, 0) orelse {
        std.debug.panic("objc_allocateClassPair failed for ZTRootView", .{});
    };
    _ = objc.class_addMethod(cls, objc.sel("drawRect:"), @as(objc.IMP, @ptrCast(&implDrawRect)), "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    _ = objc.class_addMethod(cls, objc.sel("acceptsFirstResponder"), @as(objc.IMP, @ptrCast(&implAcceptsFirstResponder)), "c@:");
    _ = objc.class_addMethod(cls, objc.sel("isFlipped"), @as(objc.IMP, @ptrCast(&implIsFlipped)), "c@:");
    _ = objc.class_addMethod(cls, objc.sel("keyDown:"), @as(objc.IMP, @ptrCast(&implKeyDown)), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("mouseDown:"), @as(objc.IMP, @ptrCast(&implMouseDown)), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("mouseDragged:"), @as(objc.IMP, @ptrCast(&implMouseDragged)), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("mouseUp:"), @as(objc.IMP, @ptrCast(&implMouseUp)), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("scrollWheel:"), @as(objc.IMP, @ptrCast(&implScrollWheel)), "v@:@");
    objc.objc_registerClassPair(cls);
    return cls;
}

pub fn install() void {
    // Register the dirty callback that Terminal.startPump will call when the
    // PTY emits output.
    term.setDirtyCallback(&markAllDirty);
}

pub fn alloc(cls: objc.Class) objc.id {
    const inst = objc.send(objc.id, cls, objc.sel("alloc"));
    return objc.send1(objc.id, inst, objc.sel("initWithFrame:"), objc.NSRect{});
}

fn markAllDirty() void {
    windows.markAllDirty();
}

// --- IMP functions ----------------------------------------------------------

fn implAcceptsFirstResponder(self: objc.id, _: objc.SEL) callconv(.c) objc.BOOL {
    _ = self;
    return 1;
}

fn implIsFlipped(self: objc.id, _: objc.SEL) callconv(.c) objc.BOOL {
    _ = self;
    return 0;
}

fn implDrawRect(self: objc.id, _: objc.SEL, _: objc.NSRect) callconv(.c) void {
    const state = stateOf(self) orelse return;
    const bounds = objc.send(objc.NSRect, self, objc.sel("bounds"));
    const ctx = currentCGContext() orelse return;
    draw.render(ctx, bounds, state);
}

fn implKeyDown(self: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const state = stateOf(self) orelse return;
    const consumed = handleKeyDown(event, state, self);
    if (consumed) markNeedsDisplay(self);
}

fn implMouseDown(self: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const state = stateOf(self) orelse return;
    const local = eventLocalPoint(self, event);
    if (handleMouseDown(local, state)) markNeedsDisplay(self);
}

fn implMouseDragged(self: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const state = stateOf(self) orelse return;
    const local = eventLocalPoint(self, event);
    if (handleMouseDragged(local, state)) markNeedsDisplay(self);
}

fn implMouseUp(self: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const state = stateOf(self) orelse return;
    _ = event;
    if (handleMouseUp(state)) markNeedsDisplay(self);
}

fn implScrollWheel(self: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const state = stateOf(self) orelse return;
    const dy = objc.send(f64, event, objc.sel("scrollingDeltaY"));
    // Roughly one line per 8 logical pixels of scroll. Up-scroll = positive
    // deltaY = view back into scrollback.
    const lines: i32 = @intFromFloat(dy / 8.0);
    if (lines == 0) return;
    const t = state.focusedTerminal() orelse return;
    t.currentScreen().scrollViewBy(lines);
    markNeedsDisplay(self);
}

fn eventLocalPoint(self: objc.id, event: objc.id) objc.NSPoint {
    const win_pt = objc.send(objc.NSPoint, event, objc.sel("locationInWindow"));
    return objc.send2(
        objc.NSPoint,
        self,
        objc.sel("convertPoint:fromView:"),
        win_pt,
        @as(objc.id, null),
    );
}

// --- helpers ----------------------------------------------------------------

fn currentCGContext() ?objc.CGContextRef {
    const NSGraphicsContext = objc.cls("NSGraphicsContext");
    const ngc = objc.send(objc.id, NSGraphicsContext, objc.sel("currentContext"));
    if (ngc == null) return null;
    return objc.send(objc.CGContextRef, ngc, objc.sel("CGContext"));
}

fn markNeedsDisplay(view: objc.id) void {
    _ = objc.send1(void, view, objc.sel("setNeedsDisplay:"), @as(objc.BOOL, 1));
}

fn handleKeyDown(event: objc.id, state: *State, view_self: objc.id) bool {
    const mods = objc.send(u64, event, objc.sel("modifierFlags"));
    const cmd = (mods & NSEventModifierFlagCommand) != 0;
    const shift = (mods & NSEventModifierFlagShift) != 0;
    const ctrl = (mods & NSEventModifierFlagControl) != 0;
    const opt = (mods & NSEventModifierFlagOption) != 0;

    const chars_im = objc.send(objc.id, event, objc.sel("charactersIgnoringModifiers"));
    var first_ch: u16 = 0;
    if (chars_im != null) {
        const len = objc.send(u64, chars_im, objc.sel("length"));
        if (len > 0) first_ch = objc.send1(u16, chars_im, objc.sel("characterAtIndex:"), @as(u64, 0));
    }

    // Command-key shortcuts.
    if (cmd) {
        switch (first_ch) {
            'q', 'Q' => {
                const NSApp = objc.send(objc.id, objc.cls("NSApplication"), objc.sel("sharedApplication"));
                _ = objc.send1(void, NSApp, objc.sel("terminate:"), @as(objc.id, null));
                return false;
            },
            't', 'T' => {
                state.newTab() catch {};
                return true;
            },
            'w', 'W' => {
                if (shift) {
                    // Cmd-Shift-W — force-close the current tab.
                    state.closeTab();
                } else if (!state.closeActivePane()) {
                    if (state.tabs.items.len > 1) {
                        state.closeTab();
                    } else {
                        // Last pane of last tab → hide the app (Kaku behaviour).
                        const NSApp = objc.send(objc.id, objc.cls("NSApplication"), objc.sel("sharedApplication"));
                        _ = objc.send1(void, NSApp, objc.sel("hide:"), @as(objc.id, null));
                    }
                }
                return true;
            },
            'n', 'N' => {
                windows.requestNewWindow();
                return false;
            },
            'h', 'H' => {
                const NSApp = objc.send(objc.id, objc.cls("NSApplication"), objc.sel("sharedApplication"));
                _ = objc.send1(void, NSApp, objc.sel("hide:"), @as(objc.id, null));
                return true;
            },
            'm', 'M' => {
                const window_obj = objc.send(objc.id, view_self, objc.sel("window"));
                _ = objc.send1(void, window_obj, objc.sel("miniaturize:"), @as(objc.id, null));
                return true;
            },
            'd', 'D' => {
                const kind: SplitKind = if (shift) .top_bottom else .side_by_side;
                state.splitActive(kind) catch {};
                return true;
            },
            '1'...'9' => {
                state.selectTab(@intCast(first_ch - '1'));
                return true;
            },
            '{', '[' => {
                state.cycleTab(-1);
                return true;
            },
            '}', ']' => {
                state.cycleTab(1);
                return true;
            },
            'k', 'K' => {
                // Clear screen + scrollback. Feed Ctrl-L to the shell so it
                // knows the screen cleared, and wipe our local scrollback.
                if (state.focusedTerminal()) |t| {
                    t.write("\x0C") catch {};
                    const sc = t.currentScreen();
                    for (sc.scrollback.items) |row| sc.allocator.free(row.cells);
                    sc.scrollback.clearRetainingCapacity();
                    sc.view_offset = 0;
                }
                return true;
            },
            'f', 'F' => {
                if (ctrl) {
                    const window_obj = objc.send(objc.id, view_self, objc.sel("window"));
                    _ = objc.send1(void, window_obj, objc.sel("toggleFullScreen:"), @as(objc.id, null));
                    return true;
                }
                return false;
            },
            'c', 'C' => {
                if (state.selection) |sel| {
                    if (state.terminalOf(sel.pane_id)) |t| {
                        var buf: [16 * 1024]u8 = undefined;
                        const n = extractSelection(t, sel, &buf);
                        if (n > 0) copyToClipboard(buf[0..n]);
                    }
                }
                return true;
            },
            'v', 'V' => {
                pasteFromClipboard(state);
                return true;
            },
            'a', 'A' => {
                // Cmd-A: select all visible cells in the focused pane.
                selectAll(state);
                return true;
            },
            else => {},
        }

        // Cmd-Opt-arrows: directional pane navigation.
        if (opt) switch (first_ch) {
            NSLeftArrowFunctionKey => {
                state.focusInDirection(.left);
                return true;
            },
            NSRightArrowFunctionKey => {
                state.focusInDirection(.right);
                return true;
            },
            NSUpArrowFunctionKey => {
                state.focusInDirection(.up);
                return true;
            },
            NSDownArrowFunctionKey => {
                state.focusInDirection(.down);
                return true;
            },
            else => {},
        };

        // Cmd-Ctrl-arrows: resize the parent split's divider.
        if (ctrl) switch (first_ch) {
            NSLeftArrowFunctionKey => {
                state.resizeActivePane(.left);
                return true;
            },
            NSRightArrowFunctionKey => {
                state.resizeActivePane(.right);
                return true;
            },
            NSUpArrowFunctionKey => {
                state.resizeActivePane(.up);
                return true;
            },
            NSDownArrowFunctionKey => {
                state.resizeActivePane(.down);
                return true;
            },
            else => {},
        };

        // Cmd-Shift-Enter zoom; Cmd-Shift-S toggle split direction.
        if (shift) switch (first_ch) {
            0x0D => {
                state.toggleZoom();
                return true;
            },
            's', 'S' => {
                state.toggleSplitDirection();
                return true;
            },
            else => {},
        };

        // Cmd-Shift-G → lazygit, Cmd-Shift-Y → yazi (Kaku quick-launch).
        if (shift) switch (first_ch) {
            'g', 'G' => {
                if (state.focusedTerminal()) |t| t.write("lazygit\n") catch {};
                return true;
            },
            'y', 'Y' => {
                if (state.focusedTerminal()) |t| t.write("yazi\n") catch {};
                return true;
            },
            else => {},
        };

        // Cmd + shell-editing keys → equivalent readline bytes.
        switch (first_ch) {
            NSLeftArrowFunctionKey => {
                if (state.focusedTerminal()) |t| t.write("\x01") catch {}; // Ctrl-A
                return true;
            },
            NSRightArrowFunctionKey => {
                if (state.focusedTerminal()) |t| t.write("\x05") catch {}; // Ctrl-E
                return true;
            },
            0x7F => {
                if (state.focusedTerminal()) |t| t.write("\x15") catch {}; // Ctrl-U
                return true;
            },
            0x0D => {
                if (state.focusedTerminal()) |t| t.write("\n") catch {}; // newline w/o execute
                return true;
            },
            else => {},
        }

        return false;
    }

    // Opt (without cmd) — left Option as Meta + word-motion shortcuts.
    if (opt) switch (first_ch) {
        NSLeftArrowFunctionKey => return sendToFocused(state, "\x1bb"),
        NSRightArrowFunctionKey => return sendToFocused(state, "\x1bf"),
        0x7F => return sendToFocused(state, "\x17"),
        else => {},
    };

    // Shift-Enter inserts a literal newline without executing.
    if (shift and first_ch == 0x0D) return sendToFocused(state, "\n");

    // Shift-PageUp/PageDown and Shift-Up/Down navigate scrollback.
    if (shift) switch (first_ch) {
        NSPageUpFunctionKey => {
            if (state.focusedTerminal()) |t_| t_.currentScreen().scrollViewBy(@as(i32, @intCast(t_.currentScreen().rows)));
            return true;
        },
        NSPageDownFunctionKey => {
            if (state.focusedTerminal()) |t_| t_.currentScreen().scrollViewBy(-@as(i32, @intCast(t_.currentScreen().rows)));
            return true;
        },
        NSUpArrowFunctionKey => {
            if (state.focusedTerminal()) |t_| t_.currentScreen().scrollViewBy(1);
            return true;
        },
        NSDownArrowFunctionKey => {
            if (state.focusedTerminal()) |t_| t_.currentScreen().scrollViewBy(-1);
            return true;
        },
        else => {},
    };

    // Non-shortcut: route to the focused terminal as input bytes.
    state.selection = null;
    const t = state.focusedTerminal() orelse return false;
    t.currentScreen().snapToLive();
    var seq_buf: [16]u8 = undefined;
    const out = translateKey(first_ch, mods, &seq_buf) orelse {
        // Fall back to whatever AppKit produced in `characters` (respects shift,
        // includes IME results).
        const chars_full = objc.send(objc.id, event, objc.sel("characters"));
        if (chars_full == null) return false;
        const utf8: ?[*:0]const u8 = objc.send(?[*:0]const u8, chars_full, objc.sel("UTF8String"));
        if (utf8) |p| {
            const slice = std.mem.span(p);
            // Apply Ctrl modifier to ASCII letters: Ctrl-A => 0x01 etc.
            if (ctrl and slice.len == 1) {
                const ch = std.ascii.toLower(slice[0]);
                if (ch >= 'a' and ch <= 'z') {
                    const b = [_]u8{ch - 'a' + 1};
                    t.write(&b) catch {};
                    return true;
                }
                if (ch == ' ') {
                    t.write(&.{0}) catch {};
                    return true;
                }
            }
            t.write(slice) catch {};
        }
        return true;
    };
    t.write(out) catch {};
    return true;
}

/// Translate special keys (arrows, function keys, etc.) into the byte sequences
/// xterm-style terminals expect. Returns null for keys with no special mapping
/// — the caller should fall back to `[event characters]`.
fn translateKey(ch: u16, mods: u64, buf: *[16]u8) ?[]const u8 {
    _ = mods;
    return switch (ch) {
        NSUpArrowFunctionKey => "\x1b[A",
        NSDownArrowFunctionKey => "\x1b[B",
        NSRightArrowFunctionKey => "\x1b[C",
        NSLeftArrowFunctionKey => "\x1b[D",
        NSHomeFunctionKey => "\x1b[H",
        NSEndFunctionKey => "\x1b[F",
        NSPageUpFunctionKey => "\x1b[5~",
        NSPageDownFunctionKey => "\x1b[6~",
        NSDeleteFunctionKey => "\x1b[3~",
        // F1..F4 use SS3 sequences; F5+ use CSI ~ with codes.
        NSF1FunctionKey => "\x1bOP",
        NSF1FunctionKey + 1 => "\x1bOQ",
        NSF1FunctionKey + 2 => "\x1bOR",
        NSF1FunctionKey + 3 => "\x1bOS",
        NSF1FunctionKey + 4 => "\x1b[15~",
        NSF1FunctionKey + 5 => "\x1b[17~",
        NSF1FunctionKey + 6 => "\x1b[18~",
        NSF1FunctionKey + 7 => "\x1b[19~",
        NSF1FunctionKey + 8 => "\x1b[20~",
        NSF1FunctionKey + 9 => "\x1b[21~",
        NSF1FunctionKey + 10 => "\x1b[23~",
        NSF1FunctionKey + 11 => "\x1b[24~",
        0x7F => blk: {
            // Backspace from the main keyboard — terminals expect ^?
            buf[0] = 0x7F;
            break :blk buf[0..1];
        },
        0x0D => "\r",
        0x1B => "\x1b",
        else => null,
    };
}

fn sendToFocused(state: *State, bytes: []const u8) bool {
    const t = state.focusedTerminal() orelse return false;
    state.selection = null;
    t.currentScreen().snapToLive();
    t.write(bytes) catch {};
    return true;
}

fn handleMouseDown(p: objc.NSPoint, state: *State) bool {
    for (state.tab_hits.items) |hit| {
        if (rectContains(hit.rect, p)) {
            state.selectTab(hit.idx);
            state.selection = null;
            return true;
        }
    }
    for (state.pane_hits.items) |hit| {
        if (rectContains(hit.rect, p)) {
            state.currentTab().active = hit.id;
            const cell = pointToCell(hit, p);
            state.selection = .{
                .pane_id = hit.id,
                .anchor_col = cell.col,
                .anchor_row = cell.row,
                .end_col = cell.col,
                .end_row = cell.row,
                .dragging = true,
            };
            return true;
        }
    }
    return false;
}

fn handleMouseDragged(p: objc.NSPoint, state: *State) bool {
    var sel = state.selection orelse return false;
    if (!sel.dragging) return false;
    const hit = findPaneHit(state, sel.pane_id) orelse return false;
    const cell = pointToCell(hit, p);
    sel.end_col = cell.col;
    sel.end_row = cell.row;
    state.selection = sel;
    return true;
}

fn handleMouseUp(state: *State) bool {
    var sel = state.selection orelse return false;
    if (!sel.dragging) return false;
    sel.dragging = false;
    state.selection = sel;
    // Empty selection (no drag movement) → drop it and treat as a focus click.
    if (sel.anchor_col == sel.end_col and sel.anchor_row == sel.end_row) {
        state.selection = null;
        return true;
    }
    // Copy the selected text to the system pasteboard.
    if (state.terminalOf(sel.pane_id)) |t| {
        var buf: [16 * 1024]u8 = undefined;
        const n = extractSelection(t, sel, &buf);
        if (n > 0) copyToClipboard(buf[0..n]);
    }
    return true;
}

const PointCell = struct { col: u16, row: u16 };

fn pointToCell(hit: st.PaneHit, p: objc.NSPoint) PointCell {
    const cell_w = font.metrics.cell_w;
    const cell_h = font.metrics.cell_h;
    const rel_x = p.x - hit.rect.x;
    // Unflipped coords: y up. Top of pane is hit.rect.y + hit.rect.h; row 0 sits there.
    const top_y = hit.rect.y + hit.rect.h;
    const rel_y_from_top = top_y - p.y;
    var col_i: i64 = @intFromFloat(@floor(rel_x / cell_w));
    var row_i: i64 = @intFromFloat(@floor(rel_y_from_top / cell_h));
    if (col_i < 0) col_i = 0;
    if (row_i < 0) row_i = 0;
    return .{ .col = @intCast(col_i), .row = @intCast(row_i) };
}

fn findPaneHit(state: *State, pane_id: st.PaneId) ?st.PaneHit {
    for (state.pane_hits.items) |hit| {
        if (hit.id == pane_id) return hit;
    }
    return null;
}

fn extractSelection(t: *term.Terminal, sel: st.Selection, buf: []u8) usize {
    const norm = st.normalizedSelection(sel);
    const sc = t.currentScreen();
    var out: usize = 0;
    var row: u16 = norm.sr;
    while (row <= norm.er and row < sc.rows) : (row += 1) {
        const start_col: u16 = if (row == norm.sr) norm.sc else 0;
        const end_col: u16 = if (row == norm.er) @min(norm.ec, sc.cols - 1) else sc.cols - 1;
        // Trim trailing default-' ' cells.
        var last_meaningful: i32 = @as(i32, start_col) - 1;
        var c: u16 = start_col;
        while (c <= end_col) : (c += 1) {
            const cell = sc.cells[@as(usize, row) * sc.cols + c];
            if (cell.ch != ' ') last_meaningful = @intCast(c);
        }
        if (last_meaningful >= @as(i32, start_col)) {
            const stop: u16 = @intCast(last_meaningful);
            var cc: u16 = start_col;
            while (cc <= stop) : (cc += 1) {
                const cell = sc.cells[@as(usize, row) * sc.cols + cc];
                out += encodeUtf8(cell.ch, buf[out..]);
                if (out >= buf.len - 4) return out;
            }
        }
        if (row < norm.er) {
            if (out >= buf.len) return out;
            buf[out] = '\n';
            out += 1;
        }
    }
    return out;
}

fn encodeUtf8(cp: u21, out: []u8) usize {
    if (out.len == 0) return 0;
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        if (out.len < 2) return 0;
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (out.len < 3) return 0;
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    if (out.len < 4) return 0;
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

fn pasteFromClipboard(state: *State) void {
    const t = state.focusedTerminal() orelse return;
    const NSPasteboard = objc.cls("NSPasteboard");
    const general = objc.send(objc.id, NSPasteboard, objc.sel("generalPasteboard"));
    const ns_str = objc.send1(objc.id, general, objc.sel("stringForType:"), objc.NSPasteboardTypeString);
    if (ns_str == null) return;
    const utf8: ?[*:0]const u8 = objc.send(?[*:0]const u8, ns_str, objc.sel("UTF8String"));
    if (utf8) |p| {
        const slice = std.mem.span(p);
        if (t.bracketed_paste) {
            t.write("\x1b[200~") catch {};
            t.write(slice) catch {};
            t.write("\x1b[201~") catch {};
        } else {
            t.write(slice) catch {};
        }
    }
}

fn selectAll(state: *State) void {
    const t = state.focusedTerminal() orelse return;
    const sc = t.currentScreen();
    const cur_tab = state.currentTab();
    state.selection = .{
        .pane_id = cur_tab.active,
        .anchor_col = 0,
        .anchor_row = 0,
        .end_col = if (sc.cols > 0) sc.cols - 1 else 0,
        .end_row = if (sc.rows > 0) sc.rows - 1 else 0,
        .dragging = false,
    };
}

fn copyToClipboard(text: []const u8) void {
    const NSPasteboard = objc.cls("NSPasteboard");
    const general = objc.send(objc.id, NSPasteboard, objc.sel("generalPasteboard"));
    _ = objc.send(c_long, general, objc.sel("clearContents"));
    // Make a NUL-terminated buffer for stringWithUTF8String:.
    var buf: [16 * 1024]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    std.mem.copyForwards(u8, buf[0..n], text[0..n]);
    buf[n] = 0;
    const ns_str = objc.send1(
        objc.id,
        objc.cls("NSString"),
        objc.sel("stringWithUTF8String:"),
        @as([*:0]const u8, @ptrCast(&buf[0])),
    );
    _ = objc.send2(objc.BOOL, general, objc.sel("setString:forType:"), ns_str, objc.NSPasteboardTypeString);
}

fn rectContains(r: st.Rect, p: objc.NSPoint) bool {
    return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h;
}

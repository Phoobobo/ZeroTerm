//! Custom NSView subclass built via the Objective-C runtime. Overrides
//! drawRect:, keyDown:, mouseDown:, and acceptsFirstResponder to route AppKit
//! events into the Zig-side `State`.

const std = @import("std");
const objc = @import("../objc.zig");
const draw = @import("draw.zig");
const st = @import("state.zig");
const term = @import("../term.zig");

const State = st.State;
const SplitKind = st.SplitKind;

// One window in this scaffold → a global state pointer is fine. Promote to an
// associated object on the view when multi-window arrives.
var g_state: ?*State = null;
var g_view: objc.id = null;

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
    objc.objc_registerClassPair(cls);
    return cls;
}

pub fn install(state: *State) void {
    g_state = state;
    // Register the dirty callback that Terminal.startPump will call when the
    // PTY emits output.
    term.setDirtyCallback(&markGlobalDirty);
}

pub fn alloc(cls: objc.Class) objc.id {
    const inst = objc.send(objc.id, cls, objc.sel("alloc"));
    return objc.send1(objc.id, inst, objc.sel("initWithFrame:"), objc.NSRect{});
}

pub fn setView(v: objc.id) void {
    g_view = v;
}

fn markGlobalDirty() void {
    if (g_view != null) markNeedsDisplay(g_view);
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
    const state = g_state orelse return;
    const bounds = objc.send(objc.NSRect, self, objc.sel("bounds"));
    const ctx = currentCGContext() orelse return;
    draw.render(ctx, bounds, state);
}

fn implKeyDown(self: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const state = g_state orelse return;
    const consumed = handleKeyDown(event, state);
    if (consumed) markNeedsDisplay(self);
}

fn implMouseDown(self: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const state = g_state orelse return;
    const win_pt = objc.send(objc.NSPoint, event, objc.sel("locationInWindow"));
    const local = objc.send2(
        objc.NSPoint,
        self,
        objc.sel("convertPoint:fromView:"),
        win_pt,
        @as(objc.id, null),
    );
    if (handleMouseDown(local, state)) markNeedsDisplay(self);
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

fn handleKeyDown(event: objc.id, state: *State) bool {
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
                // Pane-aware close: close focused pane first; close tab when the
                // tab is one pane; do nothing if it's the last tab.
                if (!state.closeActivePane()) state.closeTab();
                return true;
            },
            'n', 'N' => {
                // New window — not yet implemented (single-window scaffold).
                return false;
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
                // Clear screen — feed Ctrl-L to the shell (preferred path so
                // the shell knows the screen cleared).
                if (state.focusedTerminal()) |t| t.write("\x0C") catch {};
                return true;
            },
            else => {},
        }

        // Cmd-Opt-arrows cycle panes.
        if (opt) switch (first_ch) {
            NSLeftArrowFunctionKey, NSUpArrowFunctionKey => {
                state.cyclePane(-1);
                return true;
            },
            NSRightArrowFunctionKey, NSDownArrowFunctionKey => {
                state.cyclePane(1);
                return true;
            },
            else => {},
        };
        return false;
    }

    // Non-shortcut: route to the focused terminal as input bytes.
    const t = state.focusedTerminal() orelse return false;
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

fn handleMouseDown(p: objc.NSPoint, state: *State) bool {
    for (state.tab_hits.items) |hit| {
        if (rectContains(hit.rect, p)) {
            state.selectTab(hit.idx);
            return true;
        }
    }
    for (state.pane_hits.items) |hit| {
        if (rectContains(hit.rect, p)) {
            state.currentTab().active = hit.id;
            return true;
        }
    }
    return false;
}

fn rectContains(r: st.Rect, p: objc.NSPoint) bool {
    return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h;
}

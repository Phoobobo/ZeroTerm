//! Window registry. Each WindowCtx ties an NSWindow + content view to its
//! own UI `State` (tabs / panes / terminals). The custom NSView's IMPs look
//! up the right context by `self` so they touch the correct state.

const std = @import("std");
const objc = @import("../objc.zig");
const st = @import("state.zig");

pub const WindowCtx = struct {
    state: st.State,
    window: objc.id,
    view: objc.id,
};

pub var contexts: std.ArrayList(*WindowCtx) = .empty;
pub var new_window_fn: ?*const fn () void = null;
var g_allocator: ?std.mem.Allocator = null;

pub fn requestNewWindow() void {
    if (new_window_fn) |f| f();
}

pub fn init(alloc: std.mem.Allocator) void {
    g_allocator = alloc;
}

pub fn allocator() std.mem.Allocator {
    return g_allocator.?;
}

pub fn add(ctx: *WindowCtx) void {
    contexts.append(g_allocator.?, ctx) catch {};
}

pub fn findByView(view: objc.id) ?*WindowCtx {
    for (contexts.items) |ctx| if (ctx.view == view) return ctx;
    return null;
}

pub fn findByWindow(window: objc.id) ?*WindowCtx {
    for (contexts.items) |ctx| if (ctx.window == window) return ctx;
    return null;
}

pub fn markAllDirty() void {
    for (contexts.items) |ctx| {
        if (ctx.view != null) {
            _ = objc.send1(void, ctx.view, objc.sel("setNeedsDisplay:"), @as(objc.BOOL, 1));
        }
    }
}

/// Walk all windows and re-render — used by appearance / theme changes.
pub fn redrawAll() void {
    markAllDirty();
}

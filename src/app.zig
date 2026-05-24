//! AppKit entry point. Creates the first window, registers the shell spawner,
//! and hands control to the AppKit run loop. Additional windows are spawned
//! via Cmd-N — see `createWindow`.

const std = @import("std");
const objc = @import("objc.zig");
const view = @import("ui/view.zig");
const font = @import("ui/font.zig");
const draw = @import("ui/draw.zig");
const wm = @import("ui/windows.zig");
const term = @import("term.zig");
const state_mod = @import("ui/state.zig");
const State = state_mod.State;

const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
const NSWindowStyleMaskMiniaturizable: c_ulong = 1 << 2;
const NSWindowStyleMaskResizable: c_ulong = 1 << 3;
const NSBackingStoreBuffered: c_ulong = 2;
const NSApplicationActivationPolicyRegular: c_long = 0;
const NSViewWidthSizable: c_ulong = 1 << 1;
const NSViewHeightSizable: c_ulong = 1 << 4;

var g_screenshot_path: ?[*:0]const u8 = null;
var g_shell_buf: [256]u8 = undefined;
var g_shell_z: [:0]u8 = undefined;
var g_initial_cols: u16 = 80;
var g_initial_rows: u16 = 24;
var g_view_class: objc.Class = null;

const window_w: f64 = 960;
const window_h: f64 = 600;
const tab_bar_h: f64 = 28;

pub fn run() !void {
    const allocator = std.heap.page_allocator;
    wm.init(allocator);

    // Font metrics must come before any Terminal is created — initial cols/rows
    // are derived from them so the bootstrap shell starts at the right width
    // and doesn't render a misfitting prompt before the first SIGWINCH.
    font.init(13.0);
    g_initial_cols = @intCast(@max(20, @as(i64, @intFromFloat(@floor(window_w / font.metrics.cell_w)))));
    g_initial_rows = @intCast(@max(5, @as(i64, @intFromFloat(@floor((window_h - tab_bar_h) / font.metrics.cell_h)))));

    g_shell_z = try resolveShell(&g_shell_buf);
    view.install();
    g_view_class = view.registerClass();
    wm.new_window_fn = &createWindow;

    const NSApplication = objc.cls("NSApplication");
    const shared = objc.send(objc.id, NSApplication, objc.sel("sharedApplication"));
    _ = objc.send1(objc.BOOL, shared, objc.sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);

    // First window.
    _ = try createWindowImpl(allocator);

    _ = objc.send1(void, shared, objc.sel("activateIgnoringOtherApps:"), @as(objc.BOOL, 1));

    // Pick the palette from the current macOS appearance.
    draw.refreshAppearance();

    scheduleHarness();

    _ = objc.send(void, shared, objc.sel("run"));
}

fn resolveShell(buf: *[256]u8) ![:0]u8 {
    if (objc.getenv("SHELL")) |s| {
        const slice = std.mem.span(s);
        const n = @min(slice.len, buf.len - 1);
        std.mem.copyForwards(u8, buf[0..n], slice[0..n]);
        buf[n] = 0;
        return buf[0..n :0];
    }
    const fallback = "/bin/zsh";
    std.mem.copyForwards(u8, buf[0..fallback.len], fallback);
    buf[fallback.len] = 0;
    return buf[0..fallback.len :0];
}

fn spawnTerminal(allocator: std.mem.Allocator) anyerror!*term.Terminal {
    const t = try term.Terminal.create(allocator, g_shell_z.ptr, g_initial_cols, g_initial_rows);
    t.startPump();
    return t;
}

/// Cmd-N invokes this through `windows.new_window_fn`. Wraps the heap-aware
/// path so we don't bubble errors back to the IMP callback.
fn createWindow() void {
    _ = createWindowImpl(wm.allocator()) catch {};
}

fn createWindowImpl(allocator: std.mem.Allocator) !*wm.WindowCtx {
    const ctx = try allocator.create(wm.WindowCtx);
    ctx.* = .{
        .state = try State.init(allocator, &spawnTerminal),
        .window = null,
        .view = null,
    };

    const NSWindow = objc.cls("NSWindow");
    const NSString = objc.cls("NSString");

    // Cascade subsequent windows down-right of the first.
    const offset = @as(f64, @floatFromInt(wm.contexts.items.len)) * 24.0;
    const frame = objc.NSRect{
        .origin = .{ .x = 200 + offset, .y = 200 - offset },
        .size = .{ .w = window_w, .h = window_h },
    };
    const style: c_ulong = NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable;

    const window_alloc = objc.send(objc.id, NSWindow, objc.sel("alloc"));
    const window = objc.send4(
        objc.id,
        window_alloc,
        objc.sel("initWithContentRect:styleMask:backing:defer:"),
        frame,
        style,
        NSBackingStoreBuffered,
        @as(objc.BOOL, 0),
    );
    const title = objc.send1(
        objc.id,
        NSString,
        objc.sel("stringWithUTF8String:"),
        @as([*:0]const u8, "ZeroTerm"),
    );
    _ = objc.send1(void, window, objc.sel("setTitle:"), title);

    const content = view.alloc(g_view_class);
    _ = objc.send1(void, content, objc.sel("setAutoresizingMask:"), NSViewWidthSizable | NSViewHeightSizable);
    _ = objc.send1(void, window, objc.sel("setContentView:"), content);
    _ = objc.send1(objc.BOOL, window, objc.sel("makeFirstResponder:"), content);

    ctx.window = window;
    ctx.view = content;
    wm.add(ctx);

    _ = objc.send1(void, window, objc.sel("makeKeyAndOrderFront:"), @as(objc.id, null));
    return ctx;
}

/// Schedule a sequence of test events controlled by env vars.
///   ZT_PRESPLIT=v       — split active pane side-by-side
///   ZT_PRESPLIT=v,h     — chain splits
///   ZT_PRENEWTAB=n      — open N additional tabs
///   ZT_PRENEWWIN=n      — open N additional windows
///   ZT_INPUT="text"     — write `text` (with \n interpreted) to focused pane
///   ZT_SCREENSHOT=path  — capture the first window to a PNG at exit
///   ZT_SCREENSHOT_DELAY_MS=ms — when to take the screenshot (default 1500)
fn scheduleHarness() void {
    const queue = objc.dispatch_get_main_queue();

    if (objc.getenv("ZT_PRENEWWIN")) |p| {
        const s = std.mem.span(p);
        const n = std.fmt.parseInt(usize, s, 10) catch 0;
        var i: usize = 0;
        while (i < n) : (i += 1) createWindow();
    }

    if (wm.contexts.items.len == 0) return;
    const state = &wm.contexts.items[0].state;

    if (objc.getenv("ZT_PRENEWTAB")) |p| {
        const s = std.mem.span(p);
        const n = std.fmt.parseInt(usize, s, 10) catch 0;
        var i: usize = 0;
        while (i < n) : (i += 1) state.newTab() catch {};
        state.selectTab(0);
    }

    if (objc.getenv("ZT_PRESPLIT")) |p| {
        const s = std.mem.span(p);
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |chunk| {
            const kind: state_mod.SplitKind = if (chunk.len > 0 and chunk[0] == 'h') .top_bottom else .side_by_side;
            state.splitActive(kind) catch {};
        }
    }

    if (objc.getenv("ZT_INPUT")) |p| {
        const inp = std.mem.span(p);
        g_inject_text = injectInputAlloc(inp);
        const when = objc.dispatch_time(objc.DISPATCH_TIME_NOW, 700 * 1_000_000);
        objc.dispatch_after_f(when, queue, null, &injectInput);
    }

    if (objc.getenv("ZT_SCREENSHOT")) |path| {
        g_screenshot_path = path;
        const delay_ms: i64 = if (objc.getenv("ZT_SCREENSHOT_DELAY_MS")) |dp| blk: {
            const s = std.mem.span(dp);
            break :blk std.fmt.parseInt(i64, s, 10) catch 1500;
        } else 1500;
        const when = objc.dispatch_time(objc.DISPATCH_TIME_NOW, delay_ms * 1_000_000);
        objc.dispatch_after_f(when, queue, null, &captureAndExit);
    }
}

var g_inject_text: []const u8 = "";
var g_inject_buf: [4096]u8 = undefined;

fn injectInputAlloc(input: []const u8) []const u8 {
    var i: usize = 0;
    var out: usize = 0;
    while (i < input.len and out < g_inject_buf.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => g_inject_buf[out] = '\n',
                't' => g_inject_buf[out] = '\t',
                'r' => g_inject_buf[out] = '\r',
                '\\' => g_inject_buf[out] = '\\',
                else => {
                    g_inject_buf[out] = input[i];
                    out += 1;
                    if (out < g_inject_buf.len) g_inject_buf[out] = next;
                },
            }
            i += 1;
            out += 1;
        } else {
            g_inject_buf[out] = input[i];
            out += 1;
        }
    }
    return g_inject_buf[0..out];
}

fn injectInput(_: ?*anyopaque) callconv(.c) void {
    if (wm.contexts.items.len == 0) return;
    const t = wm.contexts.items[0].state.focusedTerminal() orelse return;
    t.write(g_inject_text) catch {};
}

fn captureAndExit(_: ?*anyopaque) callconv(.c) void {
    if (wm.contexts.items.len == 0) return terminate();
    const path_c = g_screenshot_path orelse return terminate();
    const view_obj = wm.contexts.items[0].view;
    const bounds = objc.send(objc.NSRect, view_obj, objc.sel("bounds"));
    const rep = objc.send1(objc.id, view_obj, objc.sel("bitmapImageRepForCachingDisplayInRect:"), bounds);
    _ = objc.send2(void, view_obj, objc.sel("cacheDisplayInRect:toBitmapImageRep:"), bounds, rep);
    // NSBitmapImageFileTypePNG = 4
    const data = objc.send2(objc.id, rep, objc.sel("representationUsingType:properties:"), @as(u64, 4), @as(objc.id, null));
    const ns_path = objc.send1(objc.id, objc.cls("NSString"), objc.sel("stringWithUTF8String:"), path_c);
    _ = objc.send2(objc.BOOL, data, objc.sel("writeToFile:atomically:"), ns_path, @as(objc.BOOL, 1));
    terminate();
}

fn terminate() void {
    const NSApplication = objc.cls("NSApplication");
    const shared = objc.send(objc.id, NSApplication, objc.sel("sharedApplication"));
    _ = objc.send1(void, shared, objc.sel("terminate:"), @as(objc.id, null));
}

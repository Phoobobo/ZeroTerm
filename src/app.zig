//! AppKit entry point. Creates the window, the global UI state with a shell
//! spawner, the custom NSView subclass, and hands control to the AppKit run
//! loop.

const std = @import("std");
const objc = @import("objc.zig");
const view = @import("ui/view.zig");
const font = @import("ui/font.zig");
const term = @import("term.zig");
const State = @import("ui/state.zig").State;

const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
const NSWindowStyleMaskMiniaturizable: c_ulong = 1 << 2;
const NSWindowStyleMaskResizable: c_ulong = 1 << 3;
const NSBackingStoreBuffered: c_ulong = 2;
const NSApplicationActivationPolicyRegular: c_long = 0;
const NSViewWidthSizable: c_ulong = 1 << 1;
const NSViewHeightSizable: c_ulong = 1 << 4;

var g_state: State = undefined;
var g_window: objc.id = null;
var g_view: objc.id = null;
var g_screenshot_path: ?[*:0]const u8 = null;
var g_shell_buf: [256]u8 = undefined;
var g_shell_z: [:0]u8 = undefined;
var g_initial_cols: u16 = 80;
var g_initial_rows: u16 = 24;

const window_w: f64 = 960;
const window_h: f64 = 600;
const tab_bar_h: f64 = 28;

pub fn run() !void {
    const allocator = std.heap.page_allocator;

    // Font metrics must come before any Terminal is created — initial cols/rows
    // are derived from them so the bootstrap shell starts at the right width
    // and doesn't render a misfitting prompt before the first SIGWINCH.
    font.init(13.0);
    g_initial_cols = @intCast(@max(20, @as(i64, @intFromFloat(@floor(window_w / font.metrics.cell_w)))));
    g_initial_rows = @intCast(@max(5, @as(i64, @intFromFloat(@floor((window_h - tab_bar_h) / font.metrics.cell_h)))));

    // Resolve $SHELL into a NUL-terminated buffer we'll point the spawner at.
    g_shell_z = try resolveShell(&g_shell_buf);

    g_state = try State.init(allocator, &spawnTerminal);
    view.install(&g_state);

    // Start the pump on every leaf in the initial state.
    startPumpsRecursive(g_state.currentTab().root);

    const cls = view.registerClass();

    const NSApplication = objc.cls("NSApplication");
    const NSWindow = objc.cls("NSWindow");
    const NSString = objc.cls("NSString");

    const shared = objc.send(objc.id, NSApplication, objc.sel("sharedApplication"));
    _ = objc.send1(objc.BOOL, shared, objc.sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);

    const frame = objc.NSRect{
        .origin = .{ .x = 200, .y = 200 },
        .size = .{ .w = 960, .h = 600 },
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

    const content = view.alloc(cls);
    _ = objc.send1(void, content, objc.sel("setAutoresizingMask:"), NSViewWidthSizable | NSViewHeightSizable);
    _ = objc.send1(void, window, objc.sel("setContentView:"), content);
    _ = objc.send1(objc.BOOL, window, objc.sel("makeFirstResponder:"), content);

    g_window = window;
    g_view = content;
    view.setView(content);

    _ = objc.send1(void, window, objc.sel("makeKeyAndOrderFront:"), @as(objc.id, null));
    _ = objc.send1(void, shared, objc.sel("activateIgnoringOtherApps:"), @as(objc.BOOL, 1));

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

const Pane = @import("ui/state.zig").Pane;
fn startPumpsRecursive(p: *Pane) void {
    switch (p.*) {
        .leaf => {},
        .split => |s| {
            startPumpsRecursive(s.a);
            startPumpsRecursive(s.b);
        },
    }
}

/// Schedule a sequence of test events controlled by env vars.
///   ZT_PRESPLIT=v       — split active pane side-by-side before snapshotting
///   ZT_PRESPLIT=h       — split active pane top-bottom
///   ZT_PRESPLIT=v,h     — chain multiple splits in sequence
///   ZT_PRENEWTAB=n      — open N additional tabs
///   ZT_INPUT="text"     — write `text` (with \n interpreted) to focused pane
///   ZT_SCREENSHOT=path  — capture the view to a PNG at exit
///   ZT_SCREENSHOT_DELAY_MS=ms — when to take the screenshot (default 1500)
fn scheduleHarness() void {
    const queue = objc.dispatch_get_main_queue();

    if (objc.getenv("ZT_PRENEWTAB")) |p| {
        const s = std.mem.span(p);
        const n = std.fmt.parseInt(usize, s, 10) catch 0;
        var i: usize = 0;
        while (i < n) : (i += 1) g_state.newTab() catch {};
        g_state.selectTab(0);
    }

    if (objc.getenv("ZT_PRESPLIT")) |p| {
        const s = std.mem.span(p);
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |chunk| {
            const kind: @import("ui/state.zig").SplitKind = if (chunk.len > 0 and chunk[0] == 'h') .top_bottom else .side_by_side;
            g_state.splitActive(kind) catch {};
        }
    }

    if (objc.getenv("ZT_INPUT")) |p| {
        const inp = std.mem.span(p);
        const buf = injectInputAlloc(inp);
        g_inject_text = buf;
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
    // Interpret common escapes (\n, \t, \r, \\).
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
    const t = g_state.focusedTerminal() orelse return;
    t.write(g_inject_text) catch {};
}

fn captureAndExit(_: ?*anyopaque) callconv(.c) void {
    const path_c = g_screenshot_path orelse return;
    const view_obj = g_view;
    const bounds = objc.send(objc.NSRect, view_obj, objc.sel("bounds"));
    const rep = objc.send1(objc.id, view_obj, objc.sel("bitmapImageRepForCachingDisplayInRect:"), bounds);
    _ = objc.send2(void, view_obj, objc.sel("cacheDisplayInRect:toBitmapImageRep:"), bounds, rep);
    // NSBitmapImageFileTypePNG = 4
    const data = objc.send2(objc.id, rep, objc.sel("representationUsingType:properties:"), @as(u64, 4), @as(objc.id, null));
    const ns_path = objc.send1(objc.id, objc.cls("NSString"), objc.sel("stringWithUTF8String:"), path_c);
    _ = objc.send2(objc.BOOL, data, objc.sel("writeToFile:atomically:"), ns_path, @as(objc.BOOL, 1));
    const NSApplication = objc.cls("NSApplication");
    const shared = objc.send(objc.id, NSApplication, objc.sel("sharedApplication"));
    _ = objc.send1(void, shared, objc.sel("terminate:"), @as(objc.id, null));
}

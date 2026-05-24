//! Minimal Objective-C runtime + Core Graphics bindings.
//!
//! Apple Silicon uses unified objc_msgSend for all return types (no _stret or
//! _fpret variants on arm64-darwin), so casting objc_msgSend to a typed
//! function pointer is sufficient. The C ABI handles HFA structs like NSPoint
//! and NSRect.

const std = @import("std");

pub const id = ?*opaque {};
pub const Class = ?*opaque {};
pub const SEL = ?*opaque {};
pub const IMP = ?*const anyopaque;
pub const BOOL = u8;
pub const CGFloat = f64;
pub const NSUInteger = u64;

pub const NSPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const NSSize = extern struct { w: CGFloat = 0, h: CGFloat = 0 };
pub const NSRect = extern struct { origin: NSPoint = .{}, size: NSSize = .{} };
pub const CGRect = NSRect;

pub const CGContextRef = ?*opaque {};

// Objective-C runtime.
pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "objc" fn objc_msgSend() void;
pub extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) Class;
pub extern "objc" fn objc_registerClassPair(cls_: Class) void;
pub extern "objc" fn class_addMethod(cls_: Class, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;

// AppKit attributed-string key globals — `extern NSString * const ...`.
pub extern const NSFontAttributeName: id;
pub extern const NSForegroundColorAttributeName: id;

// Grand Central Dispatch — runloop scheduling + fd event sources.
// `dispatch_get_main_queue` and `DISPATCH_SOURCE_TYPE_READ` are macros in C
// that resolve to addresses of `_dispatch_main_q` and
// `_dispatch_source_type_read`.
pub extern var _dispatch_main_q: anyopaque;
pub extern var _dispatch_source_type_read: anyopaque;

pub inline fn dispatch_get_main_queue() id {
    return @ptrCast(&_dispatch_main_q);
}
pub inline fn DISPATCH_SOURCE_TYPE_READ() id {
    return @ptrCast(&_dispatch_source_type_read);
}

pub extern fn dispatch_time(when: u64, delta: i64) u64;
pub extern fn dispatch_after_f(when: u64, queue: id, context: ?*anyopaque, work: ?*const fn (?*anyopaque) callconv(.c) void) void;
pub extern fn dispatch_source_create(t: id, handle: usize, mask: u64, queue: id) id;
pub extern fn dispatch_set_context(object: id, context: ?*anyopaque) void;
pub extern fn dispatch_source_set_event_handler_f(source: id, handler: ?*const fn (?*anyopaque) callconv(.c) void) void;
pub extern fn dispatch_resume(object: id) void;
pub extern fn dispatch_source_cancel(source: id) void;
pub const DISPATCH_TIME_NOW: u64 = 0;
pub const NSEC_PER_SEC: i64 = 1_000_000_000;

// libc env access — used by the screenshot harness.
pub extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Core Graphics — drawing primitives. Linked via CoreGraphics framework.
pub extern fn CGContextSetRGBFillColor(c: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern fn CGContextSetRGBStrokeColor(c: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern fn CGContextFillRect(c: CGContextRef, rect: CGRect) void;
pub extern fn CGContextSetLineWidth(c: CGContextRef, w: CGFloat) void;
pub extern fn CGContextSetLineDash(c: CGContextRef, phase: CGFloat, lengths: ?[*]const CGFloat, count: usize) void;
pub extern fn CGContextBeginPath(c: CGContextRef) void;
pub extern fn CGContextMoveToPoint(c: CGContextRef, x: CGFloat, y: CGFloat) void;
pub extern fn CGContextAddLineToPoint(c: CGContextRef, x: CGFloat, y: CGFloat) void;
pub extern fn CGContextStrokePath(c: CGContextRef) void;

pub inline fn cls(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

pub inline fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub inline fn send(comptime R: type, receiver: anytype, selector: SEL) R {
    const Fn = *const fn (@TypeOf(receiver), SEL) callconv(.c) R;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector);
}

pub inline fn send1(comptime R: type, receiver: anytype, selector: SEL, a: anytype) R {
    const Fn = *const fn (@TypeOf(receiver), SEL, @TypeOf(a)) callconv(.c) R;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, a);
}

pub inline fn send2(comptime R: type, receiver: anytype, selector: SEL, a: anytype, b: anytype) R {
    const Fn = *const fn (@TypeOf(receiver), SEL, @TypeOf(a), @TypeOf(b)) callconv(.c) R;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, a, b);
}

pub inline fn send4(
    comptime R: type,
    receiver: anytype,
    selector: SEL,
    a: anytype,
    b: anytype,
    c: anytype,
    d: anytype,
) R {
    const Fn = *const fn (@TypeOf(receiver), SEL, @TypeOf(a), @TypeOf(b), @TypeOf(c), @TypeOf(d)) callconv(.c) R;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, a, b, c, d);
}

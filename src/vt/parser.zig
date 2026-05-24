//! ANSI / VT escape sequence parser.
//!
//! Modelled on Paul Williams' DEC parser state diagram
//! (https://vt100.net/emu/dec_ansi_parser). Handles enough of xterm's ctlseqs
//! to drive a modern shell: printable text, C0/C1 controls, ESC dispatch, CSI
//! with params + intermediates + DEC private prefix, OSC strings, plus UTF-8
//! decoding for the print stream.

const std = @import("std");

pub const max_params = 16;
pub const max_intermediates = 4;
pub const max_osc = 1024;

pub const CsiCmd = struct {
    prefix: u8,
    params: []const i32,
    intermediates: []const u8,
    final: u8,
};

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    osc_string_esc,
};

pub const Parser = struct {
    state: State = .ground,
    params_buf: [max_params]i32 = undefined,
    params_len: u8 = 0,
    cur_param: i32 = 0,
    cur_param_set: bool = false,
    intermediates_buf: [max_intermediates]u8 = undefined,
    intermediates_len: u8 = 0,
    csi_prefix: u8 = 0,
    osc_buf: [max_osc]u8 = undefined,
    osc_len: u16 = 0,
    utf8_buf: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_remaining: u8 = 0,

    pub fn feed(self: *Parser, bytes: []const u8, sink: anytype) void {
        for (bytes) |b| self.step(b, sink);
    }

    pub fn step(self: *Parser, b: u8, sink: anytype) void {
        // Anywhere-to-anywhere transitions per Williams' parser.
        if (b == 0x18 or b == 0x1A) {
            self.flushUtf8(sink);
            self.reset();
            return;
        }
        if (b == 0x1B and self.state != .osc_string and self.state != .osc_string_esc) {
            self.flushUtf8(sink);
            self.reset();
            self.state = .escape;
            return;
        }

        switch (self.state) {
            .ground => switch (b) {
                0x20...0x7E => {
                    self.flushUtf8(sink);
                    sink.print(@as(u21, b));
                },
                0x00...0x1F, 0x7F => {
                    self.flushUtf8(sink);
                    sink.execute(b);
                },
                else => self.feedUtf8(b, sink),
            },

            .escape => {
                self.state = .ground;
                switch (b) {
                    '[' => {
                        self.resetCsi();
                        self.state = .csi_entry;
                    },
                    ']' => {
                        self.osc_len = 0;
                        self.state = .osc_string;
                    },
                    // Single-byte ESC X dispatches
                    '7', '8', 'D', 'E', 'M', 'c' => sink.esc(b),
                    // Charset designators take one intermediate byte
                    '(', ')', '*', '+' => self.state = .escape_intermediate,
                    '=', '>' => {}, // application keypad mode toggle — no-op
                    else => {},
                }
            },

            .escape_intermediate => {
                // Swallow one byte (charset designation), back to ground.
                self.state = .ground;
            },

            .csi_entry => switch (b) {
                '0'...'9' => {
                    self.cur_param = @as(i32, b - '0');
                    self.cur_param_set = true;
                    self.state = .csi_param;
                },
                ';' => {
                    self.pushParam();
                    self.state = .csi_param;
                },
                '?', '>', '<', '=' => {
                    self.csi_prefix = b;
                    self.state = .csi_param;
                },
                0x20...0x2F => {
                    self.addIntermediate(b);
                    self.state = .csi_intermediate;
                },
                0x40...0x7E => self.dispatchCsi(b, sink),
                else => self.state = .csi_ignore,
            },

            .csi_param => switch (b) {
                '0'...'9' => {
                    self.cur_param = self.cur_param * 10 + @as(i32, b - '0');
                    self.cur_param_set = true;
                },
                ';' => self.pushParam(),
                0x20...0x2F => {
                    self.pushParam();
                    self.addIntermediate(b);
                    self.state = .csi_intermediate;
                },
                0x40...0x7E => self.dispatchCsi(b, sink),
                else => self.state = .csi_ignore,
            },

            .csi_intermediate => switch (b) {
                0x20...0x2F => self.addIntermediate(b),
                0x40...0x7E => self.dispatchCsi(b, sink),
                else => self.state = .csi_ignore,
            },

            .csi_ignore => switch (b) {
                0x40...0x7E => self.reset(),
                else => {},
            },

            .osc_string => switch (b) {
                0x07 => {
                    sink.osc(self.osc_buf[0..self.osc_len]);
                    self.reset();
                },
                0x1B => self.state = .osc_string_esc,
                else => {
                    if (self.osc_len < max_osc) {
                        self.osc_buf[self.osc_len] = b;
                        self.osc_len += 1;
                    }
                },
            },

            .osc_string_esc => {
                if (b == '\\') {
                    sink.osc(self.osc_buf[0..self.osc_len]);
                    self.reset();
                } else {
                    self.state = .osc_string;
                }
            },
        }
    }

    fn dispatchCsi(self: *Parser, final: u8, sink: anytype) void {
        self.flushUtf8(sink);
        self.pushParam();
        sink.csi(CsiCmd{
            .prefix = self.csi_prefix,
            .params = self.params_buf[0..self.params_len],
            .intermediates = self.intermediates_buf[0..self.intermediates_len],
            .final = final,
        });
        self.reset();
    }

    fn addIntermediate(self: *Parser, b: u8) void {
        if (self.intermediates_len < max_intermediates) {
            self.intermediates_buf[self.intermediates_len] = b;
            self.intermediates_len += 1;
        }
    }

    fn pushParam(self: *Parser) void {
        if (self.params_len < max_params) {
            self.params_buf[self.params_len] = if (self.cur_param_set) self.cur_param else -1;
            self.params_len += 1;
        }
        self.cur_param = 0;
        self.cur_param_set = false;
    }

    fn resetCsi(self: *Parser) void {
        self.params_len = 0;
        self.cur_param = 0;
        self.cur_param_set = false;
        self.intermediates_len = 0;
        self.csi_prefix = 0;
    }

    fn reset(self: *Parser) void {
        self.state = .ground;
        self.resetCsi();
        self.osc_len = 0;
        self.utf8_len = 0;
        self.utf8_remaining = 0;
    }

    fn feedUtf8(self: *Parser, b: u8, sink: anytype) void {
        if (self.utf8_remaining == 0) {
            if ((b & 0xE0) == 0xC0) {
                self.utf8_buf[0] = b;
                self.utf8_len = 1;
                self.utf8_remaining = 1;
            } else if ((b & 0xF0) == 0xE0) {
                self.utf8_buf[0] = b;
                self.utf8_len = 1;
                self.utf8_remaining = 2;
            } else if ((b & 0xF8) == 0xF0) {
                self.utf8_buf[0] = b;
                self.utf8_len = 1;
                self.utf8_remaining = 3;
            } else {
                sink.print(@as(u21, 0xFFFD));
                self.utf8_len = 0;
                self.utf8_remaining = 0;
            }
        } else {
            self.utf8_buf[self.utf8_len] = b;
            self.utf8_len += 1;
            self.utf8_remaining -= 1;
            if (self.utf8_remaining == 0) {
                const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
                sink.print(cp);
                self.utf8_len = 0;
            }
        }
    }

    fn flushUtf8(self: *Parser, sink: anytype) void {
        if (self.utf8_remaining != 0) {
            sink.print(@as(u21, 0xFFFD));
            self.utf8_len = 0;
            self.utf8_remaining = 0;
        }
    }
};

fn decodeUtf8(buf: []const u8) u21 {
    return switch (buf.len) {
        1 => @as(u21, buf[0]),
        2 => (@as(u21, buf[0] & 0x1F) << 6) | @as(u21, buf[1] & 0x3F),
        3 => (@as(u21, buf[0] & 0x0F) << 12) |
            (@as(u21, buf[1] & 0x3F) << 6) |
            @as(u21, buf[2] & 0x3F),
        4 => (@as(u21, buf[0] & 0x07) << 18) |
            (@as(u21, buf[1] & 0x3F) << 12) |
            (@as(u21, buf[2] & 0x3F) << 6) |
            @as(u21, buf[3] & 0x3F),
        else => 0xFFFD,
    };
}

const TestSink = struct {
    alloc: std.mem.Allocator,
    printed: *std.ArrayList(u21),
    executed: *std.ArrayList(u8),
    csis: *std.ArrayList(u8),
    oscs: *std.ArrayList(u8),

    pub fn print(self: TestSink, cp: u21) void {
        self.printed.append(self.alloc, cp) catch {};
    }
    pub fn execute(self: TestSink, b: u8) void {
        self.executed.append(self.alloc, b) catch {};
    }
    pub fn esc(self: TestSink, _: u8) void {
        _ = self;
    }
    pub fn csi(self: TestSink, cmd: CsiCmd) void {
        self.csis.append(self.alloc, cmd.final) catch {};
    }
    pub fn osc(self: TestSink, data: []const u8) void {
        self.oscs.appendSlice(self.alloc, data) catch {};
    }
};

test "prints ASCII and executes LF" {
    const alloc = std.testing.allocator;
    var printed: std.ArrayList(u21) = .empty;
    defer printed.deinit(alloc);
    var executed: std.ArrayList(u8) = .empty;
    defer executed.deinit(alloc);
    var csis: std.ArrayList(u8) = .empty;
    defer csis.deinit(alloc);
    var oscs: std.ArrayList(u8) = .empty;
    defer oscs.deinit(alloc);

    var p = Parser{};
    p.feed("hi\n", TestSink{ .alloc = alloc, .printed = &printed, .executed = &executed, .csis = &csis, .oscs = &oscs });
    try std.testing.expectEqual(@as(usize, 2), printed.items.len);
    try std.testing.expectEqual(@as(u21, 'h'), printed.items[0]);
    try std.testing.expectEqual(@as(u21, 'i'), printed.items[1]);
    try std.testing.expectEqualSlices(u8, &.{0x0A}, executed.items);
}

test "CSI dispatch with params" {
    const alloc = std.testing.allocator;
    var printed: std.ArrayList(u21) = .empty;
    defer printed.deinit(alloc);
    var executed: std.ArrayList(u8) = .empty;
    defer executed.deinit(alloc);
    var csis: std.ArrayList(u8) = .empty;
    defer csis.deinit(alloc);
    var oscs: std.ArrayList(u8) = .empty;
    defer oscs.deinit(alloc);

    var p = Parser{};
    p.feed("\x1b[31;1mX", TestSink{ .alloc = alloc, .printed = &printed, .executed = &executed, .csis = &csis, .oscs = &oscs });
    try std.testing.expectEqualSlices(u8, &.{'m'}, csis.items);
    try std.testing.expectEqual(@as(usize, 1), printed.items.len);
    try std.testing.expectEqual(@as(u21, 'X'), printed.items[0]);
}

test "OSC terminated by BEL" {
    const alloc = std.testing.allocator;
    var printed: std.ArrayList(u21) = .empty;
    defer printed.deinit(alloc);
    var executed: std.ArrayList(u8) = .empty;
    defer executed.deinit(alloc);
    var csis: std.ArrayList(u8) = .empty;
    defer csis.deinit(alloc);
    var oscs: std.ArrayList(u8) = .empty;
    defer oscs.deinit(alloc);

    var p = Parser{};
    p.feed("\x1b]0;hello\x07", TestSink{ .alloc = alloc, .printed = &printed, .executed = &executed, .csis = &csis, .oscs = &oscs });
    try std.testing.expectEqualStrings("0;hello", oscs.items);
}

test "UTF-8 decoded codepoint" {
    const alloc = std.testing.allocator;
    var printed: std.ArrayList(u21) = .empty;
    defer printed.deinit(alloc);
    var executed: std.ArrayList(u8) = .empty;
    defer executed.deinit(alloc);
    var csis: std.ArrayList(u8) = .empty;
    defer csis.deinit(alloc);
    var oscs: std.ArrayList(u8) = .empty;
    defer oscs.deinit(alloc);

    var p = Parser{};
    // U+2764 ❤ encodes as E2 9D A4
    p.feed("\xE2\x9D\xA4", TestSink{ .alloc = alloc, .printed = &printed, .executed = &executed, .csis = &csis, .oscs = &oscs });
    try std.testing.expectEqual(@as(usize, 1), printed.items.len);
    try std.testing.expectEqual(@as(u21, 0x2764), printed.items[0]);
}

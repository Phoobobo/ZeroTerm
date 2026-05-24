const std = @import("std");
const app = @import("app.zig");

pub fn main() !void {
    try app.run();
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("vt/parser.zig");
    _ = @import("vt/screen.zig");
    _ = @import("pty.zig");
    _ = @import("ui/state.zig");
}

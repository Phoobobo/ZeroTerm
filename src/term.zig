//! Terminal backend facade.
//!
//! The UI imports this file only. The current in-tree parser/screen stack stays
//! as the default `legacy_term` backend while the libghostty-vt migration lands
//! behind `zig build -Dghostty=true`.

const options = @import("build_options");

const backend = if (options.use_ghostty)
    @compileError(
        \\The libghostty-vt backend is not implemented yet.
        \\Next steps:
        \\  1. Add and pin the Ghostty dependency in build.zig.zon.
        \\  2. Import the ghostty-vt module from build.zig when -Dghostty=true.
        \\  3. Replace ghostty_term.zig with a Terminal wrapper matching legacy_term.zig.
    )
else
    @import("legacy_term.zig");

pub const Terminal = backend.Terminal;
pub const setDirtyCallback = backend.setDirtyCallback;

test {
    @import("std").testing.refAllDecls(@This());
}

//! Monospace font metrics and a cached attribute dict, established once at
//! app startup. Kaku defaults to JetBrains Mono — we try that first, fall
//! back to Menlo (always present on macOS).

const std = @import("std");
const objc = @import("../objc.zig");

pub const Metrics = struct {
    font_size: f64 = 13.0,
    cell_w: f64 = 7.8,
    cell_h: f64 = 17.0,
    ascent: f64 = 13.0,
    font: objc.id = null,
};

pub var metrics: Metrics = .{};

pub fn init(font_size: f64) void {
    metrics.font_size = font_size;
    const NSFont = objc.cls("NSFont");
    const candidates: []const [*:0]const u8 = &.{
        "JetBrainsMono-Regular",
        "JetBrainsMonoNL-Regular",
        "Menlo-Regular",
    };
    var font: objc.id = null;
    for (candidates) |name| {
        const ns_name = objc.send1(
            objc.id,
            objc.cls("NSString"),
            objc.sel("stringWithUTF8String:"),
            name,
        );
        const f = objc.send2(objc.id, NSFont, objc.sel("fontWithName:size:"), ns_name, font_size);
        if (f != null) {
            font = f;
            break;
        }
    }
    if (font == null) {
        font = objc.send1(objc.id, NSFont, objc.sel("userFixedPitchFontOfSize:"), font_size);
    }
    metrics.font = font;

    // maximumAdvancement gives the widest glyph advance — for true monospace
    // fonts this is also the cell width.
    const adv = objc.send(objc.NSSize, font, objc.sel("maximumAdvancement"));
    metrics.cell_w = adv.w;

    const ascent = objc.send(f64, font, objc.sel("ascender"));
    const descent = objc.send(f64, font, objc.sel("descender"));
    const leading = objc.send(f64, font, objc.sel("leading"));
    metrics.ascent = ascent;
    metrics.cell_h = @ceil(ascent - descent + leading);
}

/// Build an attribute dict for foreground colored text in the configured font.
pub fn attrs(fg: [4]f64) objc.id {
    const NSColor = objc.cls("NSColor");
    const NSMutableDictionary = objc.cls("NSMutableDictionary");
    const dict = objc.send(objc.id, NSMutableDictionary, objc.sel("dictionary"));
    _ = objc.send2(void, dict, objc.sel("setObject:forKey:"), metrics.font, objc.NSFontAttributeName);
    const color = objc.send4(
        objc.id,
        NSColor,
        objc.sel("colorWithSRGBRed:green:blue:alpha:"),
        fg[0],
        fg[1],
        fg[2],
        fg[3],
    );
    _ = objc.send2(void, dict, objc.sel("setObject:forKey:"), color, objc.NSForegroundColorAttributeName);
    return dict;
}

# ZeroTerm Handoff — Architecture Migration

## Context

ZeroTerm is a ~3k LOC macOS terminal emulator in Zig. The current architecture:

| Layer | Files | Lines | Approach |
|---|---|---|---|
| UI | `ui/view.zig`, `ui/draw.zig`, `ui/state.zig`, `ui/font.zig`, `ui/windows.zig` | ~1,870 | Custom NSView via ObjC runtime, Core Graphics CPU rendering |
| Terminal | `term.zig`, `vt/parser.zig`, `vt/screen.zig`, `pty.zig` | ~1,130 | Custom VT parser + screen buffer, forkpty, GCD dispatch on main queue |

**Design principles:** zero dependencies, main-thread-only, minimal scope, learning-friendly.

## Decision

Migrate the terminal stack to **libghostty-vt** and the renderer to **Metal**.

### Why libghostty-vt

Replaces `vt/parser.zig` + `vt/screen.zig` + most of `term.zig` (~1,050 lines) with Ghostty's battle-tested core:

- Full VT sequence compliance (xterm-audited, fuzzed, millions of users)
- SIMD-optimised parser (~4 GB/s on Apple Silicon)
- Proper Unicode grapheme clusters, wide-char CJK/emoji
- Mouse tracking (X10, normal, SGR, URxvt) — enables tmux/mc mouse
- Kitty keyboard protocol
- Text reflow on resize
- Render state API with incremental dirty tracking
- Zig-native API, zero-dependency C ABI

### Why Metal

Replaces Core Graphics `drawAtPoint:withAttributes:` with a GPU glyph-atlas pipeline:

- Lower CPU cost per frame (batch draw calls instead of per-glyph NSAPI)
- Smoother scrolling (GPU composited, no Core Animation sync per character)
- Exploits Apple Silicon's unified memory architecture

The build already links Metal + MetalKit — the plumbing is waiting.

## What stays

The entire UI stack is **unchanged**:

| File | Role | Status |
|---|---|---|
| `ui/state.zig` | Pane tree, tabs, selection, hit-boxes | Keep |
| `ui/view.zig` | Custom NSView IMPs, event routing | Keep (modify key/mouse handlers to use libghostty key encoder) |
| `ui/windows.zig` | NSView/NSWindow → WindowCtx registry | Keep |
| `ui/font.zig` | Font metrics, glyph atlas for Metal | Rewrite (was NSFont attrs; now needs atlas + texture) |
| `objc.zig` | ObjC runtime + Core Graphics bindings | Keep (still need it for NSView, windowing, pasteboard) |
| `pty.zig` | forkpty wrapper | Keep |
| `proc.zig` | cwd polling | Keep |

## What changes

| Current file | Action | Replacement |
|---|---|---|
| `vt/parser.zig` (370 lines) | Delete | libghostty-vt `Parser.zig` |
| `vt/screen.zig` (410 lines) | Delete | libghostty-vt `Screen.zig` + `ScreenSet.zig` |
| `term.zig` (270 lines) | Delete | libghostty-vt `Terminal.zig` + thin wrapper |
| `ui/draw.zig` (558 lines) | Rewrite | Metal renderer via `MTKView` delegate |
| `ui/font.zig` (74 lines) | Rewrite | Glyph atlas builder (Metal texture) |

### New files

| File | Role |
|---|---|
| `ui/metal.zig` | Metal device, shader pipeline, frame encoding |
| `ui/glyph_atlas.zig` | Glyph rasterisation → Metal texture atlas |
| `ui/renderer.zig` | Converts libghostty render state → Metal draw commands |
| `ui/shaders.metal` | Metal shader source (vertex + fragment) |
| `ghostty_term.zig` | Thin Term wrapper holding ghostty Terminal + RenderState |

---

## Migration plan (14 phases)

### Phase 1 — Add libghostty-vt dependency

**`build.zig.zon`** — add ghostty as a dependency:

```zig
.dependencies = .{
    .ghostty = .{
        .url = "https://github.com/ghostty-org/ghostty/archive/refs/heads/main.tar.gz",
        .hash = "...",  // zig build fetch
    },
},
```

**`build.zig`** — import the vt module:

```zig
const ghostty = b.dependency("ghostty", .{
    .target = target,
    .optimize = optimize,
});
const vt_mod = ghostty.module("ghostty-vt");
exe.root_module.addImport("ghostty-vt", vt_mod);
```

### Phase 2 — Create ghostty_term.zig

Thin wrapper that owns `ghostty.Terminal` + `ghostty.RenderState`. Exposes the same interface `term.zig` currently provides to the UI layer, but delegates everything to libghostty:

```zig
const term = @import("ghostty-vt").terminal;

pub const Term = struct {
    allocator: Allocator,
    terminal: *term.Terminal,
    render_state: *term.RenderState,

    pub fn create(...) !*Term { ... }
    pub fn destroy(self: *Term) void { ... }
    pub fn write(self: *Term, bytes: []const u8) void { ... }
    pub fn resize(self: *Term, cols: u16, rows: u16) void { ... }
    pub fn startPump(self: *Term, pty: *Pty) void { ... }
};
```

Key differences from current `term.zig`:
- No custom `Sink` struct — the parser is inside libghostty
- `startPump` still uses a GCD dispatch_source on the main queue, feeds PTY bytes via `ghostty_terminal_vt_write()`
- On each pump iteration, also calls `ghostty_render_state_update(rs, terminal)`
- Calls the dirty callback (→ `setNeedsDisplay:`) after each update

### Phase 3 — Rewrite ui/font.zig → ui/glyph_atlas.zig

Current `font.zig` creates NSFont + NSMutableDictionary for `drawAtPoint:withAttributes:`.

New `glyph_atlas.zig` builds a Metal texture atlas:

```zig
pub const GlyphAtlas = struct {
    texture: id,  // MTLTexture
    metrics: struct { cell_w: f32, cell_h: f32, ascent: f32 },

    pub fn init(font_size: f32, device: id) !GlyphAtlas
    pub fn glyph(self, cp: u32) GlyphInfo  // { uv_rect, advance }
};
```

- Rasterise glyphs via Core Text's `CTFontCreatePathForGlyph` or `CGContextDrawGlyphs`
- Pack into a single `MTLTexture` (e.g. 2048×2048, single-channel R8)
- Cache by codepoint; lazy-populate on first use
- Track cell metrics as before

### Phase 4 — Write Metal shaders

**`src/ui/shaders.metal`** — minimal two-pass pipeline:

```metal
// Vertex: full-screen quad, apply cell position from instance data
// Fragment: sample glyph atlas, multiply by fg/bg color

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vert(uint vid [[vertex_id]],
                      constant float2 *quad [[buffer(0)]],
                      constant float2 *cell_pos [[buffer(1)]]) { ... }

fragment float4 frag(VertexOut in [[stage_in]],
                     texture2d<float> atlas [[texture(0)]],
                     constant float4 &fg [[buffer(0)]]) { ... }
```

Separate background pass (flat colour rects) + foreground pass (glyph quads). Keep it simple — instance-per-cell with indexed quad vertices.

### Phase 5 — Rewrite ui/draw.zig → ui/renderer.zig

Current `draw.zig` uses Core Graphics to paint paper, cells, dividers, tabs.

New `renderer.zig` implements `MTKViewDelegate`:

```zig
pub const Renderer = struct {
    device: id,       // MTLDevice
    queue: id,        // MTLCommandQueue
    pipeline: id,     // MTLRenderPipelineState
    atlas: GlyphAtlas,

    pub fn create(state: *State) !Renderer
    pub fn drawInMTKView(self: *Renderer, view: id) void { ... }
};
```

`drawInMTKView` loop:
1. Check `render_state` dirty flag — skip if clean
2. Iterate dirty rows via `ghostty_render_state_row_iterator`
3. Build background quad buffer (flat rects per cell with bg colour)
4. Build foreground glyph buffer (UV + fg colour per cell with text)
5. Encode command buffer: clear → draw bg quads → draw glyph quads → cursor highlight → present

Pane tree structure stays in `state.zig`. The renderer draws within each pane's subrect.

### Phase 6 — Wire MTKView into the NSView

In `ui/view.zig`, change the view hierarchy:

1. The custom NSView still exists (for event handling)
2. Add an `MTKView` as a subview matching the content rect
3. The `MTKView` holds the `Renderer`
4. `drawRect:` on the custom view becomes a no-op (or just draws dividers / tab strip via Core Graphics overlay)

Alternative: make the custom view itself become an `MTKView` subclass. AppKit allows `MTKView` as a plain NSView subclass — the runtime class registration can add `MTKView` in the inheritance chain.

### Phase 7 — Convert key handler to use libghostty key encoder

Current `view.zig` handles key translation inline (switch on characters + modifier flags).

Replace with libghostty's Kitty keyboard protocol support:

```zig
var event = ghostty.KeyEvent{ .key = ..., .mods = ..., .text = ... };
var buf: [16]u8 = undefined;
const len = ghostty_key_event_encode(terminal, &event, &buf);
pty.write(buf[0..len]);
```

This handles all xterm + Kitty sequences, so Cmd-arrows, Opt-arrows, function keys, and Ctrl-combinations all go through a single correct encoder.

### Phase 8 — Convert mouse handler to use libghostty mouse tracking

Current mouse handler is simple hit-test + selection. Keep hit-testing for pane focus, but delegate to libghostty for mouse reporting:

```zig
// On mouse event:
ghostty_terminal_mouse_event(terminal, mouse_event);
```

If mouse reporting is disabled, libghostty ignores the event and the selection logic runs as before. If enabled (e.g. tmux), libghostty writes the response into the PTY automatically.

### Phase 9 — Convert selection to libghostty Selection API

Current selection in `state.zig` stores raw row/col pairs.

Use libghostty's `Selection` + `SelectionGesture` APIs:

```zig
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
// Render state automatically exposes selection as per-row ranges
```

### Phase 10 — Migrate test suite

Current tests in `vt/parser.zig`, `vt/screen.zig`, and `ui/state.zig` cover the custom stack.

- `state.zig` tests → keep (pane tree logic is unchanged)
- `parser.zig` tests → delete (libghostty has its own test suite)
- `screen.zig` tests → delete (libghostty has its own test suite)

Add integration tests that spawn a `ghostty_terminal`, feed known VT sequences, and verify the render state output.

### Phase 11 — Remove dead dependencies

`build.zig` currently links:
```
CoreGraphics  →  remove (no more CPU drawing)
CoreText      →  keep (glyph rasterisation for atlas)
QuartzCore    →  keep (CAMetalLayer sits on QuartzCore)
```

### Phase 12 — Performance tuning

- Profile frame time with Instruments (Metal debugger)
- Tune glyph atlas size and eviction policy
- Batch quads by uniform colour to minimise draw calls
- Consider double-buffering the command buffer

### Phase 13 — Screenshot test harness recovery

Current `ZT_SCREENSHOT` uses `bitmapImageRepForCachingDisplayInRect:` which captures Core Graphics output. After migrating to Metal, replace with `MTKView.currentDrawable.texture` → `CGImage` path, or keep a Core Graphics fallback renderer just for snapshots.

### Phase 14 — Polish

- Wire Ghostty's `GHOSTTY_TERMINAL_OPT_BELL` callback (currently handled inline in `term.zig:Sink`)
- Wire `GHOSTTY_TERMINAL_OPT_WRITE_PTY` callback for DSR responses (device status reports)
- Wire title change callback → update tab labels

---

## File-by-file change summary

| File | State | Change |
|---|---|---|
| `build.zig.zon` | **Edit** | Add ghostty dependency |
| `build.zig` | **Edit** | Import ghostty-vt module; remove CoreGraphics framework link |
| `src/main.zig` | **Edit** | Remove `_ = @import("vt/parser.zig")` and `_ = @import("vt/screen.zig")` refs |
| `src/app.zig` | **Edit** | Create ghostty_term instead of term; init Metal renderer |
| `src/term.zig` | **Delete** | Replaced by ghostty_term.zig |
| `src/ghostty_term.zig` | **Create** | Thin wrapper around ghostty.Terminal + RenderState |
| `src/vt/parser.zig` | **Delete** | |
| `src/vt/screen.zig` | **Delete** | |
| `src/pty.zig` | Keep | No change needed |
| `src/objc.zig` | Keep | No change needed |
| `src/proc.zig` | Keep | No change needed |
| `src/ui/state.zig` | Keep | No change needed |
| `src/ui/windows.zig` | Keep | No change needed |
| `src/ui/font.zig` | **Delete** | Replaced by glyph_atlas.zig |
| `src/ui/glyph_atlas.zig` | **Create** | Core Text → MTLTexture |
| `src/ui/draw.zig` | **Delete** | Replaced by renderer.zig |
| `src/ui/renderer.zig` | **Create** | MTKViewDelegate, Metal pipeline |
| `src/ui/metal.zig` | **Create** | Metal device/queue/setup helpers |
| `src/ui/shaders.metal` | **Create** | MSL vertex/fragment shaders |
| `src/ui/view.zig` | **Edit** | Route key events through ghostty key encoder; mouse through ghostty mouse; host MTKView |

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| **libghostty-vt API unstable** | Pin to a specific ghostty commit; lock in zon hash; wrap all API calls in a single file so breakage is localised |
| **Ghostty's build system complexity** | Zig module import via `b.dependency()` handles everything — no CMake, no C toolchain needed beyond what's already required for `/usr/include` |
| **Metal learning curve** | Start with the Apple sample "MetalText" or "HelloTriangle"; keep the shader minimal (solid-colour quads, one atlas texture) |
| **Glyph atlas eviction** | 2048×2048 R8 atlas holds ~4,000 CJK glyphs at 32px; evict LRU if full. Most terminals only display ~200 unique glyphs per session |
| **Performance regression** | Phase 12 profiling; Core Graphics currently works — gate the Metal path behind a compile flag and keep both temporarily if needed |
| **Frame rate** | Target 60 fps via CVDisplayLink or MTKView's `enableSetNeedsDisplay = false` + explicit draw triggers on dirty |
| **Screenshot testing breaks** | Post-render capture via `MTKView.currentDrawable.texture` → `CGImage`; implement in Phase 13 |

## Open questions

1. **View hierarchy** — should the custom NSView be the MTKView, or should MTKView be a subview? Subview is simpler (keeps event handling + drawing separate), subclass gives one fewer CALayer.
2. **Tab strip / dividers** — draw these in Metal too, or keep a thin Core Graphics overlay for UI chrome? Overlay keeps the Metal pipeline purely character-cell based.
3. **Shader approach** — instance-per-cell with shared quad vertices, or one big vertex buffer per frame? Instance drawing is simpler and fast enough for 80×24 grids.
4. **CJK / emoji** — libghostty-vt handles grapheme clustering; the atlas must handle multi-codepoint glyphs (emoji ZWJ sequences). Core Text's `CTLine` can shape these into a single glyph image.

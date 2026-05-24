# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ZeroTerm is a macOS-only terminal emulator written in Zig, inspired by [Kaku](https://github.com/tw93/Kaku). The goal is feature parity with Kaku at lower latency. The codebase is at the **early-scaffold** stage: layers are stubbed in their final shape but most are not yet connected end-to-end.

## Build / run / test

```sh
zig build           # build into zig-out/bin/zeroterm
zig build run       # build + launch the app
zig build test      # run all unit tests (root: src/main.zig)
```

Run a single test file directly (these two are self-contained — no libc needed):

```sh
zig test src/vt/parser.zig
zig test src/vt/screen.zig
```

Toolchain: **Zig 0.16** on macOS, with the Xcode Command Line Tools installed (frameworks and headers used by `pty.zig`'s `@cImport`). `build.zig` reads `$SDKROOT` and falls back to `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` — Zig 0.16 does **not** auto-detect the macOS SDK, so the explicit `addSystemFrameworkPath` / `addSystemIncludePath` / `addLibraryPath` plumbing in `build.zig` is load-bearing, don't remove it. Primary target is Apple Silicon — see "ABI gotchas" before adding Intel support.

## Architecture

Two roughly independent stacks. The **UI stack** owns the window, tabs, panes, and event loop. The **term stack** will eventually drive a shell into each pane leaf. They are not yet wired together — pane leaves are currently empty placeholders.

```
   UI stack                                            term stack
   ──────────────────────────────────                  ───────────────────────────
                                                                ┌──── renderer (TODO)
   app.zig ─── installs ────► ui/view.zig                       │     Metal + Core Text
       │                       (custom NSView)                  │
       │                          ▲ events                      │
       │                          │                  ┌─────────────────┐
       └── owns ─► ui/state.zig   │                  │   term.zig      │  glues PTY ↔ VT ─── ┘
                  (tabs / panes)  │                  └────┬───────┬────┘
                          ▲       │                       │       │
                          └── reads ─ ui/draw.zig    ┌────▼───┐ ┌─▼──────────────┐
                              (Core Graphics paint) │ pty.zig│ │ vt/parser.zig  │
                                                    │ forkpty│ │ vt/screen.zig  │
                                                    └────────┘ └────────────────┘

   objc.zig ─ runtime + CG bindings ─ used by every UI module
```

UI data flow:
1. `app.run()` builds `State` (tabs + pane tree), registers the custom NSView class, installs an instance as `contentView`, makes it `firstResponder`, and calls `[NSApp run]`.
2. AppKit invokes our IMPs:
   - `drawRect:` → `draw.render(ctx, bounds, state)` — paints paper bg, pane tree, dotted dividers, bottom tab strip, and records hit-boxes back into `state`.
   - `keyDown:` → command-key shortcuts (see below).
   - `mouseDown:` → hit-tests against the cached tab and pane rects from the last draw.
3. After mutating state, IMPs call `setNeedsDisplay:` to trigger another paint.

Term-stack data flow (once wired):
1. `Pty.spawn` forks the shell with its own controlling tty and returns the master fd.
2. The run loop reads the master fd, hands bytes to `Parser.feed`.
3. The parser invokes a sink — `print` / `execute` / `csi` — which mutates a `Screen`.
4. The renderer reads the grid into a Metal-backed `NSView` swapped into each pane leaf.
5. Keystrokes inside a focused pane go the other way: AppKit → `Pty.write`.

### Keyboard shortcuts (UI stack)

| Combo | Action |
| --- | --- |
| Cmd-T | new tab |
| Cmd-W | close current tab (no-op on last tab) |
| Cmd-Q | quit |
| Cmd-D | split active pane side-by-side |
| Cmd-Shift-D | split active pane top/bottom |
| Cmd-1 … Cmd-9 | select tab N |
| Cmd-[ / Cmd-] | cycle tabs |

Mouse-down on a tab selects it; on a pane focuses that pane.

### What's wired vs stubbed

| Component | State |
| --- | --- |
| `app.zig`, `ui/view.zig` — window + custom NSView with drawRect / keyDown / mouseDown | wired |
| `ui/state.zig` — tabs, pane tree, splits, hit-boxes | wired, unit-tested |
| `ui/draw.zig` — paper bg, pane outlines, dotted dividers, bottom tab strip with active highlight | wired |
| `pty.zig` — fork shell + read/write | implemented, **never called from `app.zig`** yet |
| `vt/parser.zig` — DEC parser | minimal subset only (ground, escape, CSI). No OSC, DCS, character sets, UTF-8 |
| `vt/screen.zig` — grid + cursor | basic put/CR/LF/BS/scroll. No scrollback, alt-screen, selection, wide chars |
| `term.zig` — glues PTY ↔ VT ↔ Screen | written but unused |
| Renderer (cells → pixels) | not started |
| Input (focused-pane keystrokes → PTY) | not started |
| Config / themes / scrollback | not started |

The next natural milestone is **make a leaf own a `Terminal`**: give each pane its own `Pty + Parser + Screen`, render its grid inside the pane rect from `draw.zig`, and route `keyDown:` events that aren't UI shortcuts into the focused pane's `Pty.write`.

## Key design decisions

- **Objective-C via raw `objc_msgSend` casts** (`src/objc.zig`), not a bridging library. Apple Silicon uses unified `objc_msgSend` for all return types (no `_stret` / `_fpret`), so a typed function-pointer cast is sufficient — including for HFA structs like `NSRect`. If/when adding x86_64 support, structs > 16 bytes returned by value need `objc_msgSend_stret`.
- **Custom NSView via runtime class registration**, not Swift/ObjC source files. `ui/view.zig` calls `objc_allocateClassPair` → `class_addMethod` for each IMP → `objc_registerClassPair`. The IMPs are Zig `callconv(.c)` functions. State lives in Zig (one global pointer for now); promote to an associated object on the view when multi-window arrives.
- **Unflipped view coordinates** (origin bottom-left). `isFlipped` returns NO so the tab strip can sit at y=0 and `NSString drawAtPoint:` baselines work without inversion. If you change that, every Y in `ui/draw.zig` flips.
- **Sink-generic parser**: `Parser.feed(bytes, sink)` is templated on any struct exposing `print` / `execute` / `csi`. The parser stays allocation-free, and unit tests use a different sink than `term.zig` does. Don't push the screen into the parser — the indirection is the point.
- **Flat `[]Cell` grid, row-major** in `vt/screen.zig`. Scrolling is `memmove` of all-but-the-first row; the cost is acceptable for typical terminal sizes and will be revisited when scrollback lands (likely as a ring buffer of rows).
- **PTY uses `forkpty(3)`** from `<util.h>`, not the manual `posix_openpt` / `grantpt` / `unlockpt` / `ptsname` dance. Simpler and matches what macOS-native terminals do.
- **Pane tree by tagged union with `**Pane` slot replacement**. Splits walk the tree to find the slot holding the active leaf, then overwrite that slot with a new `split` node containing the old leaf and a new sibling. No parent pointers needed; tree mutation stays local.
- **Hit-boxes cached during draw**, not recomputed in mouseDown. `draw.render` appends `TabHit` / `PaneHit` entries to the state; mouseDown linearly scans them. Means draw must run before any click can land, which is fine because AppKit always paints before delivering events.

## Conventions

- One module per file. Re-exports go through the importer (`@import("vt/parser.zig").Parser`), not a barrel file.
- Tests live next to their unit at the bottom of the same file. `src/main.zig` pulls them in via `refAllDecls` + explicit `_ = @import(...)` for modules not transitively referenced.
- Indentation is 4 spaces (Zig default). Run `zig fmt .` before committing.

### Zig 0.16 idioms used here (don't regress to older patterns)

- `std.ArrayList(T)` is **unmanaged** — initialise with `.empty`, allocate with `.append(allocator, item)`, free with `.deinit(allocator)`. The managed `ArrayList.init(alloc)` form no longer exists.
- `std.BoundedArray` is gone in 0.16. Use a fixed `[N]T` plus an explicit `len` counter (see `Parser.params_buf` / `params_len`).
- Build pattern: `b.createModule(...)` → `b.addExecutable(.{ .name, .root_module })`. The old `root_source_file` field on `ExecutableOptions` is gone; framework/include/library paths live on the `*Module`, not the `*Step.Compile`.
- Calling convention literal is lowercase `.c` (not `.C`).

## ABI gotchas (Apple Silicon)

When extending `src/objc.zig`:
- `NSRect`, `NSSize`, `NSPoint` are HFAs of doubles → passed in `v0..v3`. The C-ABI cast handles them correctly.
- Selectors that return `BOOL` (typed as `u8` here) widen to `int` in older NSObject headers but are `bool`-sized on modern SDKs. Treat returns as `u8` and compare `!= 0`.
- Never call `objc_msgSend` without a cast — the no-arg `extern` declaration is a stub used purely as an address source.

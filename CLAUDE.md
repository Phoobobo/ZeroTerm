# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ZeroTerm is a macOS-only terminal emulator written in Zig, inspired by [Kaku](https://github.com/tw93/Kaku). The goal is the same calm "old paper" aesthetic and the same window / tab / pane ergonomics, at lower latency. Single-binary, no dependencies beyond the macOS SDK + Zig 0.16.

What works today: shell spawning, async PTY pump, VT/xterm parser (printable + C0/C1 + CSI + DEC private + OSC + UTF-8), SGR colours (16 + 256 + truecolor), cursor positioning, erase / scroll regions, alt-screen swap (so vim / less / htop work), monospace cell rendering (JetBrains Mono → Menlo fallback), tabs, recursive pane tree with side-by-side and top-bottom splits, dotted dividers, bottom tab strip, mouse selection with copy-on-mouseup, Cmd-V paste (bracketed-paste-aware), light + dark theme picked from `NSApp.effectiveAppearance`, visual bell flash, multi-window via Cmd-N, scrollback (5 k-row ring), Shift-PageUp/Down navigation.

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

Toolchain: **Zig 0.16** on macOS, with the Xcode Command Line Tools installed (frameworks and headers used by `pty.zig`'s `@cImport`). `build.zig` reads `$SDKROOT` and falls back to `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` — Zig 0.16 does **not** auto-detect the macOS SDK, so the explicit `addSystemFrameworkPath` / `addSystemIncludePath` / `addLibraryPath` plumbing in `build.zig` is load-bearing; don't remove it. Primary target is Apple Silicon — see "ABI gotchas" before adding Intel support.

### Visual verification harness

Several env vars drive a built-in test harness that scripts user actions and writes a PNG of the first window before exiting. Useful because Screen Recording permission is fiddly to grant headless agents — the app self-captures via `bitmapImageRepForCachingDisplayInRect`.

| Variable | Effect |
| --- | --- |
| `ZT_SCREENSHOT=path` | Capture window to `path` and quit. |
| `ZT_SCREENSHOT_DELAY_MS=ms` | When to take the shot (default 1500). |
| `ZT_PRESPLIT=v[,h,v,…]` | Split the active pane before snapshot. |
| `ZT_PRENEWTAB=n` | Open N additional tabs. |
| `ZT_PRENEWWIN=n` | Open N additional windows. |
| `ZT_INPUT="text"` | Write `text` (with `\n` / `\t` / `\r` escapes) to the focused pane after 700 ms. |

Example: `ZT_PRESPLIT=v ZT_INPUT="ls\\n" ZT_SCREENSHOT=/tmp/z.png ./zig-out/bin/zeroterm`.

## Architecture

Three loosely coupled stacks. The **UI stack** owns the window, tabs, panes, drawing, and event loop. The **term stack** runs the shell, parses VT sequences into a screen grid, and notifies the UI on dirty. The **windows registry** maps `NSView` instances back to their owning `State` so a single custom view class can serve every window.

```
   UI stack                                            term stack
   ──────────────────────────────────                  ───────────────────────────
                                                                ┌── primary screen
   app.zig ── installs ──► ui/view.zig                          │
       │                    (custom NSView)                     │
       │                       ▲ events                         ▼
       │                       │              ┌─────────────────────────┐
       └─ ui/windows.zig ◄─────┼──────────────│   term.Terminal         │
          (registry)           │              │   ┌────────┬──────────┐ │
                       ┌───────┴──────┐       │   │ Pty    │ Parser   │ │
                       │  ui/state.zig│       │   │ forkpty│ DEC+OSC  │ │
                       │  tabs, panes │       │   └────────┴──────────┘ │
                       │  selection   │       │   primary + alt Screen  │
                       └───────▲──────┘       │   scrollback (5 k rows) │
                               │              └──────────┬──────────────┘
            ui/draw.zig — Core Graphics ◄────────────────┘ dispatch_source
            ui/font.zig — cell metrics, attrs                 (main queue)
            ui/theme palette light / dark
```

UI data flow:
1. `app.run()` installs view IMPs, registers the shell spawner, creates the first window (which heap-allocates a `WindowCtx` → `State` → first `Terminal`).
2. AppKit invokes the IMPs:
   - `drawRect:` → `draw.render(ctx, bounds, state)` paints paper bg, pane tree, dotted dividers, terminal cells (background pass + per-row run-style foreground pass), selection overlay, bell flash, cursor, bottom tab strip; hit-boxes are appended to the state.
   - `keyDown:` → command-key shortcuts; if none match, the bytes are written to the focused leaf's `Pty`.
   - `mouseDown:` / `mouseDragged:` / `mouseUp:` → drag selection that auto-copies to `NSPasteboard` on release.
3. After mutating state, IMPs call `setNeedsDisplay:`.

Term-stack data flow:
1. `Pty.spawn` runs `forkpty(3)`; child sets `TERM=xterm-256color`, `COLORTERM=truecolor`, then `execvp` of `$SHELL` (or `/bin/zsh`).
2. `Terminal.startPump` creates a GCD `dispatch_source` on the main queue tied to the master fd.
3. The source handler reads, feeds bytes to `Parser.feed`, which calls back into a `Sink` that mutates the current `Screen` (primary or alt).
4. The handler calls the registered dirty callback, which marks every window's view dirty.
5. EOF cancels the source so the run loop doesn't spin after the shell exits.

### Keyboard shortcuts

| Combo | Action |
| --- | --- |
| Cmd-T | new tab |
| Cmd-N | new window |
| Cmd-W | close pane (collapses split) or close tab |
| Cmd-Q | quit |
| Cmd-D | split active pane side-by-side |
| Cmd-Shift-D | split active pane top/bottom |
| Cmd-1 … Cmd-9 | select tab N |
| Cmd-[ / Cmd-] | cycle tabs |
| Cmd-Opt-arrows | focus spatial neighbour pane |
| Cmd-K | clear screen (sends Ctrl-L) |
| Cmd-C | copy selection |
| Cmd-V | paste (bracketed if mode 2004 is on) |
| Cmd-A | select all visible cells in focused pane |
| Cmd-Shift-G | run `lazygit` |
| Cmd-Shift-Y | run `yazi` |
| Shift-PageUp/Down | scroll history a page |
| Shift-Up/Down | scroll history one line |

Mouse-down focuses the hit pane / starts a selection; mouse-drag extends; mouse-up commits and copies to the clipboard if the selection isn't empty.

## Key design decisions

- **Objective-C via raw `objc_msgSend` casts** (`src/objc.zig`), not a bridging library. Apple Silicon uses unified `objc_msgSend` for all return types (no `_stret` / `_fpret`), so a typed function-pointer cast is sufficient — including for HFA structs like `NSRect`. If/when adding x86_64 support, structs > 16 bytes returned by value need `objc_msgSend_stret`.
- **Custom NSView via runtime class registration**, not Swift/ObjC source files. `ui/view.zig` calls `objc_allocateClassPair` → `class_addMethod` for each IMP → `objc_registerClassPair`. The IMPs are Zig `callconv(.c)` functions. They find their `WindowCtx` by looking up `self` in `ui/windows.zig`'s registry, so the same class instance serves every window.
- **Unflipped view coordinates** (origin bottom-left). `isFlipped` returns NO so the tab strip sits at y=0 and `NSString drawAtPoint:` baselines work without inversion. Every Y in `ui/draw.zig` assumes this — flipping later means flipping every offset.
- **Sink-generic parser**: `Parser.feed(bytes, sink)` is templated on any struct exposing `print` / `execute` / `esc` / `csi` / `osc`. The parser stays allocation-free and is testable in isolation.
- **Flat `[]Cell` grid, row-major** in `vt/screen.zig`, plus a **`std.ArrayList(Row)` scrollback** ring. Full-screen `scrollUp` archives the lifted top row before the memmove. Partial-region scrolls (curses sub-areas) don't pollute scrollback.
- **Two `Screen` instances per Terminal** — `primary` and `alt` — so `ESC[?1049h` / `ESC[?47h` / `ESC[?1047h` swap buffers without trashing the main session's history.
- **PTY uses `forkpty(3)`** from `<util.h>`, not the manual `posix_openpt` / `grantpt` / `unlockpt` / `ptsname` dance. Master fd set non-blocking so the dispatch source handler never stalls the main queue.
- **Pane tree by tagged union with `**Pane` slot replacement**. Splits walk the tree to find the slot holding the active leaf, then overwrite that slot with a new `split` node containing the old leaf and a new sibling. Closing a pane walks to find the parent slot + sibling and collapses the split. No parent pointers needed.
- **Hit-boxes cached during draw**, not recomputed in mouseDown. `draw.render` appends `TabHit` / `PaneHit` entries to the state; mouseDown linearly scans them. Directional pane navigation reuses the same rects.
- **Palette is a `*const Palette` global**, swapped at startup by `draw.refreshAppearance()` based on `NSApp.effectiveAppearance`.

## Conventions

- One module per file. Re-exports go through the importer (`@import("vt/parser.zig").Parser`), not a barrel file.
- Tests live next to their unit at the bottom of the same file. `src/main.zig` pulls them in via `refAllDecls` + explicit `_ = @import(...)` for modules not transitively referenced.
- Indentation is 4 spaces (Zig default). Run `zig fmt .` before committing.

### Zig 0.16 idioms used here (don't regress to older patterns)

- `std.ArrayList(T)` is **unmanaged** — initialise with `.empty`, allocate with `.append(allocator, item)`, free with `.deinit(allocator)`. The managed `ArrayList.init(alloc)` form no longer exists.
- `std.BoundedArray` is gone in 0.16. Use a fixed `[N]T` plus an explicit `len` counter (see `Parser.params_buf` / `params_len`).
- `std.time.milliTimestamp` is gone too. Use `objc.nowMs()` (wraps `mach_absolute_time`).
- Build pattern: `b.createModule(...)` → `b.addExecutable(.{ .name, .root_module })`. The old `root_source_file` field on `ExecutableOptions` is gone; framework/include/library paths live on the `*Module`, not the `*Step.Compile`.
- Calling convention literal is lowercase `.c` (not `.C`).

## ABI gotchas (Apple Silicon)

When extending `src/objc.zig`:
- `NSRect`, `NSSize`, `NSPoint` are HFAs of doubles → passed in `v0..v3`. The C-ABI cast handles them correctly.
- Selectors that return `BOOL` (typed as `u8` here) widen to `int` in older NSObject headers but are `bool`-sized on modern SDKs. Treat returns as `u8` and compare `!= 0`.
- Never call `objc_msgSend` without a cast — the no-arg `extern` declaration is a stub used purely as an address source.
- GCD-style "constants" like `DISPATCH_SOURCE_TYPE_READ` and `dispatch_get_main_queue` are C macros over global symbols (`_dispatch_source_type_read`, `_dispatch_main_q`). Declare them as `extern var anyopaque` and take their address.

## Known limits

- No WezTerm Lua config layer. Theme/font are compile-time constants.
- No AI panel, settings panel, history peek, clickable file paths, pane input broadcast.
- No xterm mouse reporting (so tmux/mc mouse mode is inert).
- No wide-character handling — CJK / wide emoji render at single-cell width and may overlap.
- Window close doesn't free the `WindowCtx`; harmless leak per close.

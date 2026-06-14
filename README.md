# ZeroTerm

A macOS terminal emulator written in Zig. Inspired by [Kaku](https://github.com/tw93/Kaku) — paper-cream aesthetic, bottom-tab strip, low-latency native paint.

## What works

- **Shell**: forkpty + dispatch_source pump, `$SHELL` (login) with `TERM=xterm-256color`.
- **VT parser**: printable + C0/C1 + CSI + DEC private + OSC + UTF-8 decode.
- **Screen**: SGR (16 / 256 / truecolor + bold/italic/underline/reverse), cursor positioning, erase, scroll regions, alt-screen swap (vim/less/htop), 5 k-row scrollback.
- **UI**: tabs, recursive pane tree (Cmd-D / Cmd-Shift-D), pane zoom (Cmd-Shift-Enter), split resize / direction toggle, bottom tab strip, dotted dividers, mouse selection with copy-on-mouseup, Cmd-V paste, Cmd-N multi-window, Cmd-Opt-arrows directional pane focus, scroll-wheel + Shift-PageUp/Down scrollback, window hide / minimise / fullscreen.
- **Theme**: light + dark palettes picked from `NSApp.effectiveAppearance`.
- **Visual bell** flash on `BEL`.

## Build

```sh
zig build           # produces zig-out/bin/zeroterm
zig build run       # build + launch
zig build test      # run unit tests
```

Requires Zig 0.16 and the macOS Command Line Tools (for the AppKit / Metal frameworks and headers used by the PTY layer). `build.zig` reads `$SDKROOT` and falls back to the CLT SDK path if unset.

## Shortcuts

| Combo | Action |
| --- | --- |
| Cmd-T / Cmd-N | new tab / new window |
| Cmd-W / Cmd-Shift-W | close pane (collapses split) / force-close tab |
| Cmd-H / Cmd-M / Cmd-Ctrl-F | hide / minimise / fullscreen |
| Cmd-D / Cmd-Shift-D | split side-by-side / top-bottom |
| Cmd-Shift-S / Cmd-Shift-Enter | toggle split direction / zoom pane |
| Cmd-1 … Cmd-9, Cmd-[/] | switch / cycle tabs |
| Cmd-Opt-arrows | focus pane in direction |
| Cmd-Ctrl-arrows | resize split divider |
| Cmd-K | clear screen + scrollback |
| Cmd-C / Cmd-V / Cmd-A | copy / paste / select all |
| Cmd-Left/Right, Cmd-Delete | line start / end, delete to line start |
| Cmd-Enter / Shift-Enter | newline without executing |
| Opt-Left/Right, Opt-Delete | word back / forward, delete word |
| Cmd-Shift-G / Cmd-Shift-Y | run `lazygit` / `yazi` |
| Scroll wheel, Shift-PageUp/Down, Shift-Up/Down | scroll history |

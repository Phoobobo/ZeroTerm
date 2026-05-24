# ZeroTerm

A macOS terminal emulator written in Zig. Inspired by [Kaku](https://github.com/tw93/Kaku) — aim for at least the same feature set, faster.

## Status

Early scaffold. The app opens a window. The PTY, VT parser, and screen modules exist as separate units with unit tests, but are not yet wired into a renderer.

## Build

```sh
zig build           # produces zig-out/bin/zeroterm
zig build run       # build and launch
zig build test      # run unit tests
```

Requires Zig 0.16 and the macOS Command Line Tools (for the AppKit / Metal frameworks and headers used by the PTY layer). `build.zig` reads `$SDKROOT` and falls back to the CLT SDK path if unset.

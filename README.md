# Nib

Nib is a personal, lightweight terminal IDE written in Zig. It favors readable
code, explicit ownership, immediate response, and deliberate defaults over a
personalized plugin environment.

This is a foundation, not a usable editor. The executable currently runs a
terminal placeholder: `q` quits, Ctrl-C exits, and Ctrl-Z suspends until `fg`.
Arguments are still ignored; the executable does not open files yet.

Read-only file loading and viewport rendering are implemented independently and
covered by Zig tests, awaiting viewer integration. Snapshot limits are 8 MiB and
262,144 lines. Rendering supports ASCII, LF/CRLF, and eight-column tabs, replacing
other control/non-ASCII bytes with `?`. Unicode support is required later.

With the latest stable Zig on PATH:

```sh
zig build
zig build run --
```

The installed executable is `zig-out/bin/nib`. For development:

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
```

`check` builds, checks formatting, and runs the Zig unit-test artifact and Linux
PTY lifecycle checks. Unit tests cover snapshot ownership and limits, file
loading, safe clipping, and scrolling bounds. The PTY harness requires zsh on the
host, and uses no C library or Python. It checks terminal restoration, signals,
resize, failure paths, and shell job control; Konsole GUI presentation still
needs manual verification.

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

# Nib

Nib is a personal, lightweight terminal IDE written in Zig. It favors readable
code, explicit ownership, immediate response, and deliberate defaults over a
personalized plugin environment.

This repository is completely unimplemented at the moment.

With the latest stable Zig on PATH:

```sh
zig build
zig build run --
```

The installed executable is `zig-out/bin/nib`. For development:

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
00000000000...........................................................................................................................................................................................................................................................................................................................................```

`check` builds, checks formatting, and runs the Zig unit-test artifact and Linux
PTY lifecycle checks. The PTY harness is written in Zig, requires zsh on the
host, and uses no C library or Python. It checks terminal restoration, signals,
resize, failure paths, and shell job control; Konsole GUI presentation still
needs manual verification.

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

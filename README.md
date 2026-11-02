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
zig fmt build.zig build.zig.zon src
zig build check
```

`check` builds, checks formatting, and compiles and executes the test artifact.
There are no behavioral tests yet.

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

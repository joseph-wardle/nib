# Nib

Nib is a personal, lightweight terminal IDE written in Zig. It favors readable
code, explicit ownership, immediate response, and deliberate defaults over a
personalized plugin environment.

This is not a usable editor. It currently serves as a glorified `cat` replacement.

With the latest stable Zig on PATH:

```sh
zig build
zig build run -- README.md
```

The installed executable is `zig-out/bin/nib`. For development:

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
```

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

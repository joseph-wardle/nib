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

The installed executable is `zig-out/bin/nib`. Run `nib <path>` in a Linux terminal
to open one regular file read-only. Scroll with `h/j/k/l`, quit with `q`, and use
Ctrl-Z/`fg` to suspend/resume.

For development (checks require zsh):

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
```

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

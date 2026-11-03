# Nib

Nib is a personal, lightweight terminal IDE written in Zig. It favors readable
code, explicit ownership, immediate response, and deliberate defaults over a
personalized plugin environment.

This is an early single-file editor. Think vim, but worse in every way. 

With the latest stable Zig on PATH:

```sh
zig build
zig build run -- README.md
```

Run `nib <path>` in a Linux terminal to open one existing regular file. Navigate with
basic vim motions, and likewise edit. Most vim motions are built yet, but the most
common all work.

For development (checks require zsh):

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
zig build bench-buffer
```

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

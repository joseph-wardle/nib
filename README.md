# Nib

Nib is my personal terminal code editor for Linux, written in Zig.

Goals:

- Vim-style modal editing for the commands that matter, with deliberate defaults instead of plugins or a scripting language.
- Quick project navigation: finding files now, and later symbols, definitions and usages through language servers.
- Immediate response, and no work while idle.

## Status

Very early. Think Vim, but worse in every way. Nib can open a project, find and switch between files, edit UTF-8 text with a core set of Vim motions and operators, search the current file, yank and put with registers (copying to the system clipboard), undo, and save safely while watching for changes on disk. Next come visual mode and repeat, then language-server navigation, formatting and project-wide search.

## Try it

With the latest stable Zig on PATH:

```sh
zig build
zig build run -- README.md
```

`nib <file>` opens a file; `nib` or `nib <directory>` starts in the file finder. Editing follows Vim (`hjkl`, `w`, `b`, `d`, `c` and `y` with motions, `p`, `i`, `a`, `o`, `u`, `/` and `n` to search, `:w`, `:q`), and Ctrl-P opens the finder.

## Development

Checks require zsh and Git:

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
zig build bench-buffer
zig build bench-motion
zig build bench-finder
```

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

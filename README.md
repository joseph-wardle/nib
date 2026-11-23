# Nib

Nib is my personal terminal code editor for Linux, written in Zig.

Goals:

- Vim-style modal editing for the commands that matter, with deliberate defaults instead of plugins or a scripting language.
- Quick project navigation: finding files now, and later symbols, definitions and usages through language servers.
- Immediate response, and no work while idle.

## Status

Very early. Think Vim, but worse in every way. Nib can open a project, find and switch between files, edit UTF-8 text with a core set of Vim motions and operators, search the current file, jump back and forth across files, select with visual mode, yank and put with registers (copying to the system clipboard), undo, save safely while watching for changes on disk, format Zig on save, and go to definitions and references through a language server (zls for Zig, slangd for Slang), with several results listed in the finder, and list a file's symbols. It colours Zig syntax, with zls adding the types, functions and fields it knows, shows relative line numbers, and one built-in theme styles everything in the terminal's own colours. Next come project-wide symbol and text search, then more Vim commands.

## Try it

With the latest stable Zig on PATH:

```sh
zig build
zig build run -- README.md
```

`nib <file>` opens a file; `nib` or `nib <directory>` starts in the file finder. Editing follows Vim (`hjkl`, `w`, `b`, `d`, `c` and `y` with motions, `p`, `v` and `V` to select, `i`, `a`, `o`, `u`, `/` and `n` to search, Ctrl-O and Tab to go back and forward through jumps, `:w`, which formats Zig first, `:q`; `:fmt` formats without saving), Ctrl-P opens the finder, and `gd`, `grD`, `grt`, `gri` and `grr` go to a definition, declaration, type definition, implementation or reference; when there are several, the finder lists them under Locations to filter, preview and open. `gO` lists the file's symbols under Symbols the same way.

## Development

Checks require zsh, Git and ZLS:

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
zig build bench-buffer
zig build bench-motion
zig build bench-finder
```

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

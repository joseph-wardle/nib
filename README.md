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

Run `nib <path>` in a Linux terminal to open one existing regular file.

Supported Vim commands:

- Move with `hjkl`, `0`, `^`, `$`, `w`, `b`, `e`, `gg`, and `G`, with counts.
- Enter insert mode with `i`, `a`, `o`, or `O`; type text, Enter, Tab, or Backspace.
  Escape or Ctrl-C returns to normal mode. Ctrl-C also cancels pending commands.
- Delete or change with `d`/`c` followed by a motion, or `dd`/`cc` for lines.
  Operator and motion counts multiply. Undo with `u`; redo with Ctrl-R.
- `:w` saves; `:q` quits only when clean; `:q!` discards edits and quits.
- `:w <new-path>` writes a copy without overwriting an existing destination,
  changing the source association, or clearing unsaved changes.
- `:e!` discards local edits and reloads the source on success. Reload clears undo
  history; saving retains it. A failed reload retains local state.
- Ctrl-Z suspends; use shell `fg` to resume. Bracketed paste inserts only in
  insert mode; unsupported or oversized paste is rejected as a whole.

Editing temporarily supports ASCII, tabs, LF, and CRLF; other bytes remain
viewable but read-only. 

For development (checks require zsh):

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
zig build bench-buffer
```

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

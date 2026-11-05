# Nib

Nib is a personal, lightweight terminal IDE written in Zig. It favors readable
code, explicit ownership, immediate response, and deliberate defaults over a
personalized plugin environment.

This is an early editor. Think vim, but worse in every way.

With the latest stable Zig on PATH:

```sh
zig build
zig build run -- README.md
```

Run `nib <file>` in a Linux terminal to edit an existing regular file, or
`nib <directory>` or plain `nib` to start in the file finder.

The finder searches the project's file names and paths:

- Ctrl-P opens it from normal mode, ready to type a search. Escape or Ctrl-C
  moves to the list, where `j`/`k`, `gg`/`G` and Ctrl-D/Ctrl-U move, `/` or `i`
  returns to the search, `:` enters a command, and Escape, Ctrl-C or `q`
  returns to the file.
- In either: Enter opens the selection; Tab cycles the Project, All and Open
  lists; Ctrl-N, Ctrl-P or the arrow keys move; Ctrl-R refreshes the list; and
  Ctrl-X enters a command.
- Several files can be open at once. Switching keeps each file's edits, undo
  history, cursor and scroll position.

Supported Vim commands:

- Move with `hjkl`, `0`, `^`, `$`, `w`, `b`, `e`, `gg`, and `G`, with counts.
- Enter insert mode with `i`, `a`, `o`, or `O`; type text, Enter, Tab, or Backspace.
  Escape or Ctrl-C returns to normal mode. Ctrl-C also cancels pending commands.
- Delete or change with `d`/`c` followed by a motion, or `dd`/`cc` for lines.
  Operator and motion counts multiply. Undo with `u`; redo with Ctrl-R.
- `:w` saves. `:q` closes the file only when clean; `:q!` discards its edits.
  Closing the last file quits, as does `:q` in the finder with no file open.
- `:wq` closes the file only after a verified, durable save.
- `:qa` quits only when every file is clean, otherwise naming the files with
  unsaved edits; `:qa!` discards them all and quits.
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

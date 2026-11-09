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

## Finding files

The finder searches the file names and paths of one project, its root:

- `nib <file>` uses the Git worktree containing the file, else the file's
  directory. A symlinked file belongs to the project it was named from.
- `nib <directory>` uses that directory, even inside a larger worktree.
- `nib` uses the worktree containing the current directory, else that directory.

The root is shown in the finder's top row and stays fixed for the session.
Three lists, cycled with Tab:

- **Project:** Git's tracked files and untracked files it does not ignore.
  Outside Git, or if Git fails, every file under the root, marked `Unfiltered`
  with the reason.
- **All:** every regular file under the root, hidden and ignored ones included,
  skipping `.git` and never following directory symlinks. Files Git ignores are
  dimmed; `?` marks a file whose status is unknown because Git couldn't say,
  including every file inside a nested repository or submodule, which Git
  doesn't look into.
- **Open:** every open file, most recently used first. `+` marks unsaved edits.
  Ignore status comes from All, so it shows `?` until All has been listed.

A query matches when its characters appear in order anywhere in the path. It
ignores case unless it contains an uppercase letter. Matches at the start of a
word or path component, consecutive runs and matches in the file name rank
higher; matched characters are underlined.

Lists are read when the finder opens, when you switch list and on Ctrl-R; they
don't follow later changes on their own. The preview shows the selected file's
first 64 KiB, marked when truncated, and reads only regular files, never FIFOs
or devices. An open file previews its current text, unsaved edits included.

Keys:

- Ctrl-P opens the finder from normal mode, ready to type a search. Escape or
  Ctrl-C moves to the list, where `j`/`k`, `gg`/`G` and Ctrl-D/Ctrl-U move, `/`
  or `i` returns to the search, `:` enters a command, and Escape, Ctrl-C or `q`
  returns to the file.
- In either: Enter opens the selection; Tab cycles the lists; Ctrl-N, Ctrl-P or
  the arrow keys move; Ctrl-R refreshes; and Ctrl-X enters a command.

Several files can be open at once. Switching keeps each file's edits, undo
history, cursor and scroll position. Only the file you're viewing is watched
for changes on disk; the others are checked again when you switch to them. A
clean file that changed reloads; a file with unsaved edits keeps them and shows
`DISK CONFLICT`.

## Editing

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

## Text

Nib edits UTF-8 text with tabs, LF and CRLF, and assumes a UTF-8 terminal.
Motions, deletes, Backspace, typing and paste work by character. Files with
invalid UTF-8 or other control bytes remain viewable but read-only, with the
reason shown; their bytes are saved back unchanged.

Nib draws only characters whose width it knows: Latin, Greek and Cyrillic,
common punctuation, symbols and arrows, box drawing, CJK and common emoji.
Widths follow Unicode's East Asian Width, with ambiguous characters narrow, as
in Konsole's default; a terminal that draws them wide misaligns those rows.
Anything else, including combining accents, zero-width and bidi characters,
emoji sequences, other scripts and invalid bytes, shows as one `?` cell. A
combining accent or emoji sequence is edited one code point at a time.

Current limits:

- Non-ASCII file paths show escaped in the finder and as `?` in the status line,
  and the `:` command line accepts only ASCII, so `:w` can't name such a file.
- Moving on a very long line is slow: on a 100 KiB line, a key costs about
  1 ms in ASCII text and 2 to 6 ms in UTF-8 text.

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

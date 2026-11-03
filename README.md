# Nib

Nib is a personal, lightweight terminal IDE written in Zig. It favors readable
code, explicit ownership, immediate response, and deliberate defaults over a
personalized plugin environment.

This is an early single-file editor foundation. Project navigation and live
external-change handling are still being built.

With the latest stable Zig on PATH:

```sh
zig build
zig build run -- README.md
```

The installed executable is `zig-out/bin/nib`. Run `nib <path>` in a Linux terminal
to open one existing regular file. Move with `h/j/k/l`, `0`, `^`, `$`, `w`, `b`,
`e`, `gg`, and `G`; motions accept counts (`3w`, `20G`). The view follows the
text cursor without wrapping long lines.

Enter insert mode with `i` or `a`; `o`/`O` open a line below/above. Type ASCII text,
Tab, Enter, and Backspace, then use Escape or Ctrl-C to return to normal mode.
Compose `d`/`c` with motions, or use `dd`/`cc` for lines. Operator and motion counts
multiply (`2d3w`). Undo with `u`, redo with Ctrl-R. Each insertion session, including
its preceding change or open-line command, is one undo group. Status shows the
mode and `[+]` for unsaved changes. Ctrl-C also cancels incomplete commands.
Ctrl-Z suspends; use the shell's `fg` to resume with edits and history retained.

Use `:w` then Enter to save, `:q` to quit when clean, or `:q!` to discard unsaved
changes. `:w <new-path>` writes a separate copy, refuses any existing destination,
and retains the original association and unsaved status. Paths are literal ASCII,
including spaces; there is no shell expansion. `:e!` and live reload remain for
the next implementation step. Saving checks for external changes and refuses a
changed or missing source; write a copy to preserve local edits. External changes
are not yet announced while idle.

Editing temporarily supports printable ASCII, tabs, LF, and CRLF. Files with
Unicode, lone CR, or other control bytes remain viewable and read-only with an
explicit reason; saving preserves their original bytes. Untouched mixed line
endings and final-newline state are preserved. New line breaks use the current
line's ending, otherwise the first existing ending, otherwise LF. The temporary
limits are 8 MiB and 262,144 logical lines, applying to loading and edited text.
Refused edits retain earlier typing and undo history.

Bracketed paste works in insert mode, as part of its undo group. It normalizes
CR/LF/CRLF breaks using the same newline policy, preserves tabs, and rejects the
whole paste on unsupported bytes or limits. Paste never executes commands. Pasted
Ctrl-C/Ctrl-Z are unsupported bytes; ordinary keyboard Ctrl-Z still suspends.
An external suspension during paste discards that paste and drains its remaining
payload through the end delimiter. In other modes paste is ignored.

A lone Escape takes 100 ms to distinguish it from a terminal sequence. Before
`O` or `^`, wait for that recognition or use Ctrl-C first; rapid Escape followed
by either prefix is interpreted as a terminal sequence. The restricted command
line accepts at most 4,096 ASCII bytes; overflow or unsupported bytes invalidate
the command. Arrow, mouse, and extended keyboard commands are not supported.

For development (checks require zsh):

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
zig build bench-buffer
```

`bench-buffer` measures the internal mutable buffer in ReleaseFast: insertion
latency, grouped undo/redo, and retained allocation bytes on source, long-line,
and near-limit fixtures. It does not measure terminal or editor responsiveness.

Saving uses validated loading, atomic replacement, conflict refusal, and
no-clobber copies. It preserves and verifies permissions, ownership, ACLs, and
observable extended attributes, refusing saves when that is impossible. Linux
can hide privileged attributes; replacement may lose them without Nib detecting
their presence. Source saves follow symlink targets and refuse multiply linked
files and unsupported inode policies. Copies are private (0600), retain the
source association, and do not clear unsaved status.

Saving checks effective source write access and actual base bytes before
replacement. A race remains between the last check and replacement with an
independent writer. File and directory syncing can block; lifecycle signals
remain pending until synchronous saving returns. A directory-sync error after
replacement is reported separately from failure to install the bytes. There is
no persistent recovery: a crash, terminal closure, or terminating signal can lose
unsaved changes.

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

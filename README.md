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
to open one regular file read-only. Move the text cursor with `h/j/k/l`, `0`,
`^`, `$`, `w`, `b`, `e`, `gg`, and `G`; motions accept counts (`3w`, `20G`).
The view scrolls to follow the cursor. Quit with `:q` followed by Enter, and use
Ctrl-Z/`fg` to suspend/resume. Ctrl-C cancels pending commands. Editing, saving,
and reloading are not yet available in the executable.

A lone Escape takes 100 ms to distinguish it from a terminal sequence. Before
`O` or `^`, wait for that recognition or use Ctrl-C first; rapid Escape followed
by either prefix is interpreted as a terminal sequence. The restricted command
line accepts at most 4,096 ASCII bytes; overflow or unsupported bytes invalidate
the command. Bracketed paste in the current read-only viewer executes no commands.

For development (checks require zsh):

```sh
zig fmt build.zig build.zig.zon src tests
zig build check
zig build bench-buffer
```

`bench-buffer` measures the internal mutable buffer in ReleaseFast: insertion
latency, grouped undo/redo, and retained allocation bytes on source, long-line,
and near-limit fixtures. It does not measure terminal or editor responsiveness.
The buffer is not yet connected to interactive editing.

The internal save engine has native Zig tests for validated loading, atomic
replacement, conflict refusal, and writing a separate copy without overwriting
an existing path. It preserves and verifies permissions, ownership, ACLs, and
observable extended attributes, refusing saves when that is impossible. Linux
can hide privileged attributes; replacement may lose them without Nib detecting
their presence. Source saves follow symlink targets and refuse multiply linked
files and unsupported inode policies. Copies are private (0600), retain the
source association, and do not clear unsaved status.

Saving checks effective source write access and actual base bytes before
replacement. A race remains between the last check and replacement with an
independent writer. File and directory syncing can block; lifecycle signals
remain pending until synchronous saving returns. A directory-sync error after
replacement is reported separately from failure to install the bytes. These
engine guarantees will accompany the commands when interactive editing is wired
in; they do not provide persistent recovery after termination or a crash.

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

// SPDX-License-Identifier: MIT OR Apache-2.0
//! The modules the benchmarks in `tests/` measure. The editor itself is rooted
//! at `main.zig`; this root only gives the benchmarks one module rooted at
//! `src/`, since Zig refuses imports above a module's root.
pub const buffer = @import("text/buffer.zig");
pub const editor = @import("edit/editor.zig");
pub const editor_view = @import("views/editor_view.zig");
pub const finder = @import("finder/finder.zig");
pub const frame = @import("terminal/frame.zig");
pub const jobs = @import("finder/jobs.zig");
pub const motion = @import("text/motion.zig");
pub const position = @import("lsp/position.zig");
pub const protocol = @import("lsp/protocol.zig");
pub const search = @import("text/search.zig");
pub const session = @import("files/session.zig");
pub const syntax = @import("text/syntax.zig");
pub const terminal = @import("terminal/terminal.zig");
pub const viewport = @import("text/viewport.zig");

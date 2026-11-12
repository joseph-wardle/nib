// SPDX-License-Identifier: MIT OR Apache-2.0
//! The modules the benchmarks in `tests/` measure. The editor itself is rooted
//! at `main.zig`; this root only gives the benchmarks one module rooted at
//! `src/`, since Zig refuses imports above a module's root.
pub const buffer = @import("text/buffer.zig");
pub const finder = @import("finder/finder.zig");
pub const jobs = @import("finder/jobs.zig");
pub const motion = @import("text/motion.zig");
pub const search = @import("text/search.zig");
pub const viewport = @import("text/viewport.zig");

// SPDX-License-Identifier: MIT OR Apache-2.0
//! The modules the benchmarks in `tests/` measure. The editor itself is rooted
//! at `main.zig`; this root only gives the benchmarks one module rooted at
//! `src/`, since Zig refuses imports above a module's root.
pub const buffer = @import("buffer.zig");
pub const finder = @import("finder.zig");
pub const jobs = @import("jobs.zig");
pub const motion = @import("motion.zig");
pub const search = @import("search.zig");
pub const view = @import("view.zig");

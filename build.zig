// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const executable = b.addExecutable(.{
        .name = "nib",
        .root_module = module,
    });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run Nib").dependOn(&run.step);

    const buffer_bench = b.addExecutable(.{
        .name = "buffer-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/buffer_bench.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "buffer", .module = b.createModule(.{
                .root_source_file = b.path("src/buffer.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
            }) }},
        }),
    });
    b.step("bench-buffer", "Measure ReleaseFast buffer edits, history, and retained bytes").dependOn(&b.addRunArtifact(buffer_bench).step);

    const motion_bench = b.addExecutable(.{
        .name = "motion-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/motion_bench.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "view", .module = b.createModule(.{
                .root_source_file = b.path("src/view.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
            }) }},
        }),
    });
    const motion_step = b.step(
        "bench-motion",
        "Measure ReleaseFast per-key motion, follow and cursor-column work",
    );
    motion_step.dependOn(&b.addRunArtifact(motion_bench).step);

    const finder_bench = b.addExecutable(.{
        .name = "finder-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/finder_bench.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "finder", .module = b.createModule(.{
                .root_source_file = b.path("src/finder.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
            }) }},
        }),
    });
    b.step("bench-finder", "Measure ReleaseFast finder discovery, filtering, classification, cancellation and memory").dependOn(&b.addRunArtifact(finder_bench).step);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const terminal_harness = b.addExecutable(.{
        .name = "terminal-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/terminal.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const terminal_tests = b.addRunArtifact(terminal_harness);
    terminal_tests.addArtifactArg(executable);
    const test_step = b.step("test", "Run unit tests and Linux PTY viewer checks");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&terminal_tests.step);

    const format = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    });
    const check = b.step("check", "Build, check formatting, and run tests");
    check.dependOn(b.getInstallStep());
    check.dependOn(&format.step);
    check.dependOn(test_step);
}

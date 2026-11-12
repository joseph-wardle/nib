// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const terminal = @import("terminal.zig");
const discovery = @import("discovery.zig");
const jobs = @import("jobs.zig");
const Finder = @import("finder.zig").Finder;
const app = @import("app.zig");

pub fn main(init: std.process.Init) u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next();
    if (path != null and args.next() != null) {
        diagnostic("usage: nib [path] (one file or directory)");
        return 1;
    }
    const how: discovery.Start = if (path) |named|
        if (directory(named)) .{ .directory = named } else .{ .file = named }
    else
        .working;
    // Establish the signal mask before file I/O can start runtime workers.
    // open validates the terminal but does not enter the alternate screen.
    var device = terminal.Terminal.open() catch |err| {
        report(err);
        return 1;
    };
    // Workers inherit the blocked mask, so jobs start after the terminal.
    var background = jobs.Jobs.init() catch |err| {
        device.close() catch {};
        report(err);
        return 1;
    };
    var finder: Finder = .{};
    const outcome = app.run(init, &device, &background, &finder, how);
    const cleanup = device.close();
    // Joining workers can wait on helpers, so the terminal is restored first.
    background.deinit(init.gpa, init.io);
    finder.deinit(init.gpa, init.io);
    // Diagnostics follow cleanup so they remain visible in the shell.
    var code = outcome catch |err| code: {
        report(err);
        break :code @as(u8, 1);
    };
    cleanup catch |err| {
        report(err);
        code = 1;
    };
    return code;
}

fn directory(path: [*:0]const u8) bool {
    var status: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &status);
    return posix.errno(result) == .SUCCESS and status.mode & linux.S.IFMT == linux.S.IFDIR;
}

fn report(err: anyerror) void {
    const message = switch (err) {
        error.NotATerminal => "stdin and stdout must be the controlling terminal",
        error.NotForeground => "run Nib as a foreground terminal job",
        error.OutputBlocked => "screen cleanup blocked by terminal output",
        error.SystemResources => "cannot start background work",
        error.FileNotFound,
        error.AccessDenied,
        error.UnsupportedFileType,
        error.FileTooLarge,
        error.TooManyLines,
        error.OutOfMemory,
        error.UnstableSource,
        error.SourceChanged,
        => app.openFailure(@errorCast(err)),
        else => @errorName(err),
    };
    diagnostic(message);
}

fn diagnostic(message: []const u8) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "nib: {s}\n", .{message}) catch unreachable;
    terminal.writeDiagnostic(text);
}

test {
    _ = @import("external.zig");
    _ = @import("editor.zig");
    _ = @import("file.zig");
    _ = @import("buffer.zig");
    _ = @import("char.zig");
    _ = @import("terminal.zig");
    _ = @import("view.zig");
    _ = @import("input.zig");
    _ = @import("command.zig");
    _ = @import("command_line.zig");
    _ = @import("jobs.zig");
    _ = @import("session.zig");
    _ = @import("finder.zig");
    _ = @import("match.zig");
    _ = @import("preview.zig");
    _ = @import("app.zig");
    _ = @import("frame.zig");
    _ = @import("editor_view.zig");
    _ = @import("finder_view.zig");
    _ = @import("search.zig");
}

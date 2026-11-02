// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("terminal.zig");
const source = @import("snapshot.zig");
const view = @import("view.zig");
const input = @import("input.zig");

pub fn main(init: std.process.Init) u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse {
        diagnostic(init.io, "usage: nib <path> (one regular file)");
        return 1;
    };
    if (args.next() != null) {
        diagnostic(init.io, "usage: nib <path> (exactly one file required)");
        return 1;
    }
    // Establish the signal mask before file I/O can start runtime workers.
    // open validates the terminal but does not enter the alternate screen.
    var session = terminal.Terminal.open() catch |err| {
        report(init.io, err);
        return 1;
    };
    const outcome = loadAndRun(init, &session, path);
    const cleanup = session.close();
    // Diagnostics follow cleanup so they remain visible in the shell.
    var code = outcome catch |err| code: {
        report(init.io, err);
        break :code @as(u8, 1);
    };
    cleanup catch |err| {
        report(init.io, err);
        code = 1;
    };
    return code;
}

fn loadAndRun(init: std.process.Init, session: *terminal.Terminal, path: []const u8) !u8 {
    var snapshot = try source.Snapshot.load(init.gpa, init.io, .cwd(), path);
    defer snapshot.deinit(init.gpa);
    var viewport: view.Viewport = .{};
    var parser: input.Parser = .{};
    var dimensions: terminal.Size = .{ .rows = 0, .columns = 0 };
    while (true) {
        switch (try session.next()) {
            .redraw => |size| {
                dimensions = size;
                viewport.clamp(snapshot, size.rows -| 1, size.columns -| 1);
                try draw(snapshot, viewport, dimensions, path);
            },
            .input => |byte| if (parser.feed(byte)) |command| {
                switch (command) {
                    .quit => return 0,
                    .move => |direction| if (viewport.move(snapshot, dimensions.rows -| 1, dimensions.columns -| 1, direction)) {
                        try draw(snapshot, viewport, dimensions, path);
                    },
                }
            },
            .quit => |code| return code,
        }
    }
}

fn draw(snapshot: source.Snapshot, viewport: view.Viewport, dimensions: terminal.Size, path: []const u8) terminal.Error!void {
    try terminal.write("\x1b[H\x1b[2J");
    // Reserve the last column on every row to avoid autowrap, including the
    // bottom-right cell. A fixed row buffer covers every u16 terminal width.
    var buffer: [std.math.maxInt(u16)]u8 = undefined;
    const row = buffer[0..dimensions.columns -| 1];
    if (dimensions.rows != 0 and row.len != 0) {
        for (0..dimensions.rows - 1) |number| {
            viewport.renderRow(snapshot, number, row);
            try terminal.write(row);
            try terminal.write("\r\n");
        }
        var status: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&status, "q quit | hjkl scroll | Ctrl-Z suspend | {d}:{d} | ", .{ viewport.top + 1, viewport.left + 1 }) catch unreachable;
        const prefix = @min(label.len, row.len);
        @memcpy(row[0..prefix], label[0..prefix]);
        view.renderText(path, 0, row[prefix..]);
        try terminal.write("\x1b[7m");
        try terminal.write(row);
    }
    try terminal.write("\x1b[0m");
}

fn report(io: std.Io, err: anyerror) void {
    const message = switch (err) {
        error.NotATerminal => "stdin and stdout must be the controlling terminal",
        error.NotForeground => "run Nib as a foreground terminal job",
        error.FileNotFound => "file not found; check the path",
        error.AccessDenied => "permission denied while opening the file",
        error.UnsupportedFileType, error.IsDir => "expected a regular file, not a directory or device",
        error.FileTooLarge => "file exceeds the temporary 8 MiB viewer limit",
        error.TooManyLines => "file exceeds the temporary 262,144-line viewer limit",
        error.OutOfMemory => "not enough memory to open the file",
        else => @errorName(err),
    };
    diagnostic(io, message);
}

fn diagnostic(io: std.Io, message: []const u8) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "nib: {s}\n", .{message}) catch unreachable;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

test {
    _ = @import("snapshot.zig");
    _ = @import("view.zig");
    _ = @import("input.zig");
}

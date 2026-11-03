// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("terminal.zig");
const source = @import("file.zig");
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");
const view = @import("view.zig");
const input = @import("input.zig");
const commands = @import("command.zig");

pub fn main(init: std.process.Init) u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse {
        diagnostic("usage: nib <path> (one regular file)");
        return 1;
    };
    if (args.next() != null) {
        diagnostic("usage: nib <path> (exactly one file required)");
        return 1;
    }
    // Establish the signal mask before file I/O can start runtime workers.
    // open validates the terminal but does not enter the alternate screen.
    var session = terminal.Terminal.open() catch |err| {
        report(err);
        return 1;
    };
    const outcome = loadAndRun(init, &session, path);
    const cleanup = session.close();
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

fn loadAndRun(init: std.process.Init, session: *terminal.Terminal, path: []const u8) !u8 {
    var document = try source.Source.load(init.gpa, init.io, .cwd(), path);
    defer document.deinit(init.gpa);
    const buffer = &document.buffer;
    var goal: motion.Goal = 0;
    var viewport: view.Viewport = .{};
    var decoder: input.Decoder = .{};
    var parser: commands.Parser = .{};
    var notice: []const u8 = "";
    var dimensions: terminal.Size = .{ .rows = 0, .columns = 0 };
    while (true) {
        var redraw = false;
        var events: input.Events = .{};
        switch (try session.next(decoder.deadline)) {
            .redraw => |size| {
                dimensions = size;
                viewport.follow(buffer, size.rows -| 1, size.columns -| 1, false);
                redraw = true;
            },
            .input => |byte| events = decoder.feed(byte, try terminal.milliseconds()),
            .timeout => events = decoder.expire(try terminal.milliseconds()),
            .quit => |code| return code,
        }
        for (events.items[0..events.len]) |event| {
            const old_mode = parser.mode;
            const old_length = parser.line_len;
            const old_notice = notice;
            if (event == .escape or (event == .key and event.key == 3)) notice = "";
            if (parser.feed(event)) |action| switch (action) {
                .move => |movement| {
                    notice = "";
                    if (motion.resolve(buffer, goal, movement.motion, movement.count, null)) |result| {
                        redraw = redraw or result.destination != buffer.cursor;
                        buffer.cursor = result.destination;
                        goal = result.goal;
                        viewport.follow(buffer, dimensions.rows -| 1, dimensions.columns -| 1, false);
                    }
                },
                .file => |file| switch (file) {
                    .quit => |discard| {
                        if (discard or !buffer.modified()) return 0;
                        notice = "Unsaved changes; use :q! to discard";
                    },
                    .write, .reload => notice = "Saving/reloading is not available yet",
                },
                .invalid => notice = "Unsupported command or count",
                else => {
                    // Do not expose mutations until saving and grouped editing
                    // are connected. Refused insert entry returns to normal.
                    parser.cancel();
                    notice = "Editing is not available yet";
                },
            };
            redraw = redraw or old_mode != parser.mode or old_length != parser.line_len or !std.mem.eql(u8, old_notice, notice);
        }
        if (redraw) draw(session, buffer, viewport, dimensions, path, &parser, notice) catch |err| {
            if (err != error.Interrupted) return err;
        };
    }
}

fn draw(session: *terminal.Terminal, buffer: *const Buffer, viewport: view.Viewport, dimensions: terminal.Size, path: []const u8, parser: *const commands.Parser, notice: []const u8) terminal.Error!void {
    try session.write("\x1b[?25l\x1b[H\x1b[2J");
    // Reserve the last column on every row to avoid autowrap, including the
    // bottom-right cell. A fixed row buffer covers every u16 terminal width.
    var row_buffer: [std.math.maxInt(u16)]u8 = undefined;
    const row = row_buffer[0..dimensions.columns -| 1];
    if (dimensions.rows != 0 and row.len != 0) {
        for (0..dimensions.rows - 1) |number| {
            viewport.renderRow(buffer, number, row);
            try session.write(row);
            try session.write("\r\n");
        }
        var status: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&status, ":q quit | Ctrl-Z suspend | {d}:{d} | ", .{ buffer.rowAt(buffer.cursor) + 1, motion.screenColumn(buffer, buffer.cursor, false) + 1 }) catch unreachable;
        if (parser.mode == .command_line) {
            row[0] = ':';
            // Keep the end of a long command visible in the reserved status row.
            const left = parser.line_len -| (row.len - 1);
            view.renderText(parser.line[0..parser.line_len], left, row[1..]);
        } else if (parser.mode == .operator) {
            view.renderText("OPERATOR pending | Escape/Ctrl-C cancel", 0, row);
        } else if (notice.len != 0) {
            view.renderText(notice, 0, row);
        } else {
            const prefix = @min(label.len, row.len);
            @memcpy(row[0..prefix], label[0..prefix]);
            view.renderText(path, 0, row[prefix..]);
        }
        try session.write("\x1b[7m");
        try session.write(row);
    }
    try session.write("\x1b[27m");
    if (viewport.cursor(buffer, dimensions.rows -| 1, dimensions.columns -| 1, false)) |cell| {
        var position: [48]u8 = undefined;
        try session.write(std.fmt.bufPrint(&position, "\x1b[{d};{d}H\x1b[?25h", .{ cell.row + 1, cell.column + 1 }) catch unreachable);
    }
    try session.write("\x1b[0m");
}

fn report(err: anyerror) void {
    const message = switch (err) {
        error.NotATerminal => "stdin and stdout must be the controlling terminal",
        error.NotForeground => "run Nib as a foreground terminal job",
        error.FileNotFound => "file not found; check the path",
        error.AccessDenied => "permission denied while opening the file",
        error.UnsupportedFileType, error.IsDir => "expected a regular file, not a directory or device",
        error.FileTooLarge => "file exceeds the temporary 8 MiB viewer limit",
        error.TooManyLines => "file exceeds the temporary 262,144-line viewer limit",
        error.OutputBlocked => "screen cleanup blocked by terminal output",
        error.OutOfMemory => "not enough memory to open the file",
        error.UnstableSource, error.SourceChanged => "file changed while loading; try again",
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
    _ = @import("file.zig");
    _ = @import("buffer.zig");
    _ = @import("terminal.zig");
    _ = @import("snapshot.zig");
    _ = @import("view.zig");
    _ = @import("input.zig");
    _ = @import("command.zig");
}

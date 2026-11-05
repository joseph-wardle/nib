// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("terminal.zig");
const file = @import("file.zig");
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");
const view = @import("view.zig");
const input = @import("input.zig");
const command = @import("command.zig");
const Editor = @import("editor.zig").Editor;
const External = @import("external.zig").External;
const Session = @import("session.zig").Session;

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
    var editor: Editor = .{};
    defer editor.deinit(init.gpa);
    var documents: Session = .{};
    defer documents.deinit(init.gpa);
    _ = try documents.open(init.gpa, init.io, .cwd(), path, &editor);
    var suspension_count = session.suspension_count;
    var resumption_count = session.resumption_count;
    var save_notice: [256]u8 = undefined;
    var decoder: input.Decoder = .{};

    var dimensions: terminal.Size = .{ .rows = 0, .columns = 0 };
    // Until the finder exists, closing the last document exits.
    while (documents.current()) |active| {
        var redraw = false;
        var bytes: []const u8 = &.{};
        var expired = false;
        switch (try session.next(decoder.deadline, active.disk.watch.fd)) {
            .watch => {
                const old_status = active.disk.status();
                if (active.disk.watch.drain()) {
                    active.disk.inspect(init.gpa, &active.document, true);
                    redraw = !std.mem.eql(u8, old_status, active.disk.status());
                }
            },
            .redraw => |size| {
                dimensions = size;
                redraw = true;
            },
            .input => |chunk| bytes = chunk,
            .timeout => expired = true,
            .quit => |code| return code,
        }
        if (suspension_count != session.suspension_count or resumption_count != session.resumption_count) {
            suspension_count = session.suspension_count;
            resumption_count = session.resumption_count;
            editor.interruptPaste();
            active.disk.inspect(init.gpa, &active.document, true);
            redraw = true;
        }
        // One read can hold many keys or a large paste; they share a timestamp.
        const now = if (bytes.len != 0 or expired) try terminal.milliseconds() else 0;
        var fed: usize = 0;
        while (expired or fed < bytes.len) {
            const events = if (expired) decoder.expire(now) else decoder.feed(bytes[fed], now);
            if (expired) expired = false else fed += 1;
            for (events.items[0..events.len]) |event| {
                if (event == .key and event.key == 26) {
                    session.requestSuspend();
                    continue;
                }
                // Closing a document moves entries; look the active one up per event.
                const entry = documents.current() orelse return 0;
                const buffer = &entry.document.buffer;
                const old_mode = editor.parser.mode;
                const old_length = editor.parser.line_len;
                const old_cursor = buffer.cursor;
                const old_position = buffer.position;
                const old_text_length = buffer.bytes().len;
                const old_notice = editor.notice;
                if (editor.feed(init.gpa, buffer, &entry.goal, event)) |action| switch (action) {
                    .quit => |discard| {
                        documents.close(init.gpa, init.io, entry.id, discard, &editor) catch {
                            editor.notice = "Unsaved changes; use :q! to discard";
                        };
                        redraw = true;
                        continue;
                    },
                    .write => |copy_path| {
                        const result = if (copy_path.len == 0)
                            documents.save(init.gpa, .{})
                        else
                            file.copy(init.gpa, init.io, .cwd(), copy_path, buffer, .{});
                        editor.notice = saveNotice(result, copy_path.len != 0);
                        if (result.cleanup_failure) editor.notice = std.fmt.bufPrint(&save_notice, "{s}; cleanup failed", .{editor.notice}) catch unreachable;
                    },
                    .reload => {
                        _ = entry.disk.reload(
                            init.gpa,
                            init.io,
                            &entry.document,
                            &entry.goal,
                            &editor,
                            true,
                        );
                        redraw = true;
                    },
                };
                redraw = redraw or old_mode != editor.parser.mode or old_length != editor.parser.line_len or old_cursor != buffer.cursor or old_position != buffer.position or old_text_length != buffer.bytes().len or !std.mem.eql(u8, old_notice, editor.notice);
            }
        }
        const entry = documents.current() orelse return 0;
        const buffer = &entry.document.buffer;
        redraw = entry.disk.automatic(
            init.gpa,
            init.io,
            &entry.document,
            &entry.goal,
            &editor,
        ) or redraw;
        const rows = dimensions.rows -| 1;
        entry.viewport.follow(buffer, rows, dimensions.columns -| 1, editor.inserting());
        if (redraw) draw(
            session,
            buffer,
            entry.viewport,
            dimensions,
            path,
            &editor.parser,
            editor.notice,
            &entry.disk,
        ) catch |err| {
            if (err != error.Interrupted) return err;
        };
    }
    return 0;
}

fn saveNotice(result: file.Report, copy: bool) []const u8 {
    if (result.publication == .uncertain) return "Save outcome uncertain; inspect disk before retrying";
    if (result.publication == .installed and !result.verified) return "Bytes installed but changed/unverified; local edits retained";
    if (result.publication == .installed and !result.durable) return "Bytes installed and verified; durability not confirmed";
    if (result.publication == .installed and result.failure != null) return "Bytes installed and verified; save reported an error";
    if (result.failure) |err| return switch (err) {
        error.SourceChanged, error.FileNotFound, error.UnstableSource => "Source changed or missing; save refused; :e! reloads; :w <new-path> copies",
        error.MultiplyLinked => "Hard-linked source; use :w <new-path>",
        error.AccessDenied => "Write permission denied; save refused",
        error.PathAlreadyExists => "Copy destination exists; choose a new path",
        error.MetadataUnavailable, error.UnsupportedFlags => "Cannot preserve source metadata; save refused",
        error.OutOfMemory => "Not enough memory; save refused",
        else => @errorName(err),
    };
    return if (copy) "Copy written; source association and unsaved status retained" else "Written";
}

fn draw(session: *terminal.Terminal, buffer: *const Buffer, viewport: view.Viewport, dimensions: terminal.Size, path: []const u8, parser: *const command.Parser, notice: []const u8, external: *const External) terminal.Error!void {
    var frame: Frame = .{ .session = session };
    try frame.append("\x1b[?25l\x1b[H\x1b[2J");
    // Reserve the last column on every row to avoid autowrap, including the
    // bottom-right cell.
    const width = dimensions.columns -| 1;
    if (dimensions.rows != 0 and width != 0) {
        for (0..dimensions.rows - 1) |number| {
            viewport.renderRow(buffer, number, try frame.reserve(width));
            try frame.append("\r\n");
        }
        try frame.append("\x1b[7m");
        var row = try frame.reserve(width);
        const warning = external.status();
        const warning_len = @min(warning.len, row.len);
        @memcpy(row[0..warning_len], warning[0..warning_len]);
        row = row[warning_len..];
        var status: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&status, ":q quit | Ctrl-Z suspend | {s}{s} | {d}:{d} | ", .{ if (parser.mode == .insert) "INSERT" else "NORMAL", if (buffer.modified()) " [+]" else if (!buffer.editable) " [read-only: unsupported bytes]" else "", buffer.rowAt(buffer.cursor) + 1, motion.screenColumn(buffer, buffer.cursor, parser.mode == .insert) + 1 }) catch unreachable;
        if (row.len == 0) {
            // The persistent disk/monitor status fills tiny status rows.
        } else if (parser.mode == .command_line) {
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
    }
    try frame.append("\x1b[27m");
    if (viewport.cursor(buffer, dimensions.rows -| 1, dimensions.columns -| 1, parser.mode == .insert)) |cell| {
        var position: [48]u8 = undefined;
        try frame.append(std.fmt.bufPrint(&position, "\x1b[{d};{d}H\x1b[?25h", .{ cell.row + 1, cell.column + 1 }) catch unreachable);
    }
    try frame.append("\x1b[0m");
    try frame.flush();
}

/// Collects output so an ordinary frame reaches the terminal in one write.
/// Larger frames flush whenever the buffer fills; the capacity holds the
/// widest possible row, so a reserved row is never split.
const Frame = struct {
    session: *terminal.Terminal,
    bytes: [std.math.maxInt(u16) + 1]u8 = undefined,
    len: usize = 0,

    fn append(self: *Frame, data: []const u8) terminal.Error!void {
        @memcpy(try self.reserve(data.len), data);
    }

    /// The caller fills the returned bytes before the next append or reserve.
    fn reserve(self: *Frame, count: usize) terminal.Error![]u8 {
        std.debug.assert(count <= self.bytes.len);
        if (self.bytes.len - self.len < count) try self.flush();
        defer self.len += count;
        return self.bytes[self.len..][0..count];
    }

    fn flush(self: *Frame) terminal.Error!void {
        defer self.len = 0;
        try self.session.write(self.bytes[0..self.len]);
    }
};

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
    _ = @import("external.zig");
    _ = @import("editor.zig");
    _ = @import("file.zig");
    _ = @import("buffer.zig");
    _ = @import("terminal.zig");
    _ = @import("view.zig");
    _ = @import("input.zig");
    _ = @import("command.zig");
    _ = @import("jobs.zig");
    _ = @import("session.zig");
    _ = @import("finder.zig");
    _ = @import("match.zig");
    _ = @import("preview.zig");
}

test "save notices distinguish failure, uncertain publication and installed durability" {
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .failure = error.SourceChanged }, false), "Source changed"));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .uncertain, .failure = error.PublishFailed }, false), "Save outcome uncertain"));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .installed, .failure = error.SourceChanged }, false), "Bytes installed but changed/unverified"));
    try std.testing.expectEqualStrings("Bytes installed and verified; durability not confirmed", saveNotice(.{ .publication = .installed, .verified = true, .failure = error.SyncFailed }, false));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .installed, .verified = true, .durable = true, .failure = error.InjectedFailure }, false), "Bytes installed and verified"));
    try std.testing.expectEqualStrings("Written", saveNotice(.{ .publication = .installed, .verified = true, .durable = true }, false));
}

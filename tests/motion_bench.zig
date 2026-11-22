// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const nib = @import("nib");
const Buffer = nib.buffer.Buffer;
const motion = nib.motion;
const search = nib.search;
const Viewport = nib.viewport.Viewport;
const Highlights = nib.viewport.Highlights;
const Editor = nib.editor.Editor;
const Frame = nib.frame.Frame;
const session = nib.session;

// Per-key motion work as the event loop does it, without a terminal: resolve
// the motion, move the cursor, follow it, place the terminal cursor and compute
// the status column. Each sample starts from the same cursor, 90% of the way
// along the middle line, where column scans are longest. Rendering and output
// are not timed with the motions; a separate sample draws a whole frame through
// the editor view once it follows the cursor, as Zig and as plain text, and
// again with every content row selected by `V`. Search samples time one
// incremental query change, for a query that is found and one that is not, and
// again on an 8 MiB file with no match.
// Output is never written to a terminal. No timing threshold is a test.
pub fn main(init: std.process.Init) !void {
    const lines = [_]struct {
        name: []const u8,
        found: []const u8,
        missing: []const u8,
        text: []const u8,
    }{
        .{
            .name = "ASCII",
            .found = "boundary",
            .missing = "cursory",
            .text = "    const value = buffer.line(row); // keep the cursor on a boundary\t",
        },
        .{
            .name = "UTF-8",
            .found = "quoted",
            .missing = "quotes",
            .text = "    na\u{ef}ve \u{2014} \u{3c3} \u{201c}quoted\u{201d} \u{6750}\u{6599} " ++
                "\u{2705} \u{2192} \u{2211} \u{2264} \u{2502}\t",
        },
    };
    const motions = [_]motion.Motion{
        .left, .right, .word, .back,  .word_end,
        .down, .up,    .end,  .start, .first,
    };
    for (lines) |line| {
        for ([_]bool{ false, true }) |long| {
            const text = try fixture(init.gpa, line.text, long, 100 * 1024);
            defer init.gpa.free(text);
            var buffer = try Buffer.fromBytes(init.gpa, text);
            defer buffer.deinit(init.gpa);
            const row = buffer.lineCount() / 2;
            const start = buffer.lineRange(row).start;
            const origin = motion.normal(&buffer, start + buffer.line(row).len * 9 / 10);
            var viewport: Viewport = .{};
            std.debug.print("{s} {s}, {d} bytes, cursor at byte {d} of its line:\n", .{
                line.name,
                if (long) "100 KiB single line" else "100 KiB source",
                text.len,
                origin - start,
            });
            for (motions) |key| {
                var times: [samples]i96 = undefined;
                for (&times) |*elapsed| {
                    buffer.cursor = origin;
                    var goal: motion.Goal = motion.screenColumn(&buffer, origin, false);
                    const before = std.Io.Timestamp.now(init.io, .awake);
                    if (motion.resolve(&buffer, goal, key, null, null)) |result| {
                        buffer.cursor = result.destination;
                        goal = result.goal;
                    }
                    viewport.follow(&buffer, rows, columns, false);
                    const cell = viewport.cursor(&buffer, rows, columns, false);
                    const status = motion.screenColumn(&buffer, buffer.cursor, false);
                    std.mem.doNotOptimizeAway(cell);
                    std.mem.doNotOptimizeAway(status);
                    std.mem.doNotOptimizeAway(goal);
                    const after = std.Io.Timestamp.now(init.io, .awake);
                    elapsed.* = before.durationTo(after).toNanoseconds();
                }
                summary(@tagName(key), &times);
            }
            // A whole frame drawn by the editor view, scrolled to the cursor:
            // every content row and the status row, then again with every
            // visible row selected by `V`.
            buffer.cursor = origin;
            try render(init.gpa, init.io, &buffer, "fixture.zig", null, .none, "render 50x200");
            const tagged = "render 50x200, server tokens";
            try render(init.gpa, init.io, &buffer, "fixture.zig", null, .current, tagged);
            const shifted = "render 50x200, server tokens shifted a row";
            try render(init.gpa, init.io, &buffer, "fixture.zig", null, .shifted, shifted);
            const plain = "render 50x200, plain text";
            try render(init.gpa, init.io, &buffer, "fixture.txt", null, .none, plain);
            const selected = "render 50x200, all selected";
            try render(init.gpa, init.io, &buffer, "fixture.zig", 0, .none, selected);
            for ([_][]const u8{ line.found, line.missing }) |query| {
                incremental(init.io, &buffer, origin, query);
            }
            try decode(init.gpa, init.io, &buffer);
            if (!long) try change(init.gpa, init.io, &buffer);
        }
    }
    // The largest file Nib loads; the missing query's first letter is common.
    const large = try fixture(init.gpa, lines[0].text, false, 8 * 1024 * 1024);
    defer init.gpa.free(large);
    var buffer = try Buffer.fromBytes(init.gpa, large);
    defer buffer.deinit(init.gpa);
    std.debug.print("ASCII 8 MiB source, {d} bytes, cursor at the start:\n", .{large.len});
    incremental(init.io, &buffer, 0, lines[0].missing);
    try change(init.gpa, init.io, &buffer);
}

/// One frame of the editor view at `rows` content rows by `columns` of a
/// document at `path`, which decides its colours, the cursor where `buffer` has
/// it and the view following it as the app does. With an `anchor`, a linewise
/// selection runs from it to the cursor. With server `tokens`, every identifier
/// in view has one, in turn a field, a function and plain, as a range answer
/// would; shifted, they are a row behind the text, as after an edit that joined
/// the top row with the one below before the next answer. Reports the frame's bytes; nothing is
/// written to a terminal.
fn render(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffer: *const Buffer,
    path: []const u8,
    anchor: ?usize,
    tokens: Tokens,
    name: []const u8,
) !void {
    const size: nib.terminal.Size = .{ .rows = rows + 1, .columns = columns + 1 };
    // Borrows the buffer: only the tokens are the entry's own.
    var entry: session.Entry = .{
        .id = @fromBackingInt(@intCast(0)),
        .document = .{
            .source = .{ .path = path, .resolved = undefined, .version = undefined },
            .buffer = buffer.*,
        },
    };
    entry.viewport.follow(buffer, rows, nib.editor_view.contentWidth(size, buffer), false);
    defer entry.tokens.deinit(gpa);
    if (tokens != .none) try tag(gpa, buffer, &entry);
    if (tokens == .shifted) {
        // The top row was two rows when the tokens were asked; the rest moved up.
        const count = buffer.insertionRows();
        const top = entry.viewport.top;
        entry.document.buffer.changed_rows = .{ .lines = .{
            .first = top,
            .unchanged = count - top - 1,
            .rows = count + 1,
        } };
    }
    var editor: Editor = .{};
    if (anchor) |offset| {
        editor.parser.visual = .linewise;
        editor.anchor = offset;
    }
    var frame: Frame = .{ .screen = undefined };
    var times: [samples]i96 = undefined;
    for (&times) |*elapsed| {
        frame.len = 0;
        const before = std.Io.Timestamp.now(io, .awake);
        nib.editor_view.draw(&frame, size, &entry, &editor, "", null) catch unreachable;
        std.mem.doNotOptimizeAway(frame.bytes[0..frame.len]);
        const after = std.Io.Timestamp.now(io, .awake);
        elapsed.* = before.durationTo(after).toNanoseconds();
    }
    var label: [64]u8 = undefined;
    const bytes = std.fmt.bufPrint(&label, "{s}, {d} bytes", .{ name, frame.len });
    summary(bytes catch unreachable, &times);
}

/// One incremental query change, as the editor and the next frame do it: a
/// forward search from `origin`, the cursor moved and followed, and the
/// visible matches of every content row found.
fn incremental(io: std.Io, buffer: *Buffer, origin: usize, query: []const u8) void {
    var times: [samples]i96 = undefined;
    for (&times) |*elapsed| {
        buffer.cursor = origin;
        var viewport: Viewport = .{};
        viewport.follow(buffer, rows, columns, false);
        const before = std.Io.Timestamp.now(io, .awake);
        if (search.find(buffer.bytes(), query, origin, .forward, 1)) |found| {
            buffer.cursor = found.start;
        }
        viewport.follow(buffer, rows, columns, false);
        const shown = buffer.insertionRows() -| viewport.top;
        for (0..@min(rows, shown)) |row| {
            const text = buffer.line(viewport.top + row);
            var highlights: Highlights = .init(text, query, viewport.left, columns);
            while (highlights.next()) |part| std.mem.doNotOptimizeAway(part.bytes);
        }
        const after = std.Io.Timestamp.now(io, .awake);
        elapsed.* = before.durationTo(after).toNanoseconds();
    }
    var name: [64]u8 = undefined;
    summary(std.fmt.bufPrint(&name, "search \"{s}\"", .{query}) catch unreachable, &times);
}

/// A frame's server tokens: none, matching the text, or a row behind it.
const Tokens = enum { none, current, shifted };

const samples = 1000;
const rows = 50;
const columns = 200;

fn summary(name: []const u8, times: *[samples]i96) void {
    std.mem.sort(i96, times, {}, std.sort.asc(i96));
    std.debug.print("  {s}: p50/p99/max {d}/{d}/{d} ns over {d} samples\n", .{
        name,
        times[samples / 2],
        times[samples * 99 / 100],
        times[samples - 1],
        samples,
    });
}

/// Up to `size` bytes of `line` repeated, ending each copy with LF, or with a
/// space for the single-line fixture. Caller frees.
fn fixture(allocator: std.mem.Allocator, line: []const u8, long: bool, size: usize) ![]u8 {
    const copies = size / (line.len + 1);
    const text = try allocator.alloc(u8, copies * (line.len + 1));
    for (0..copies) |index| {
        const copy = text[index * (line.len + 1) ..][0 .. line.len + 1];
        @memcpy(copy[0..line.len], line);
        copy[line.len] = if (long) ' ' else '\n';
    }
    return text;
}

/// Gives every identifier in the rows `entry` shows a server token, in turn a
/// field, a function and plain.
fn tag(gpa: std.mem.Allocator, buffer: *const Buffer, entry: *session.Entry) !void {
    const kinds = [_]?nib.syntax.Kind{ .field, .function, null };
    const held = &entry.tokens;
    held.top = entry.viewport.top;
    const last = @min(buffer.insertionRows(), entry.viewport.top + rows);
    for (entry.viewport.top..last) |row| {
        const text = buffer.line(row);
        var position: usize = 0;
        while (position < text.len) {
            const start = position;
            while (position < text.len and std.ascii.isAlphabetic(text[position])) position += 1;
            if (position > start) {
                const kind = kinds[held.tokens.items.len % kinds.len];
                try held.tokens.append(gpa, .{ .start = start, .end = position, .kind = kind });
            } else position += 1;
        }
        try held.ends.append(gpa, held.tokens.items.len);
    }
    // The buffer's text is the tokens' text.
    entry.document.buffer.changed_rows = .none;
}

/// Decoding a range answer for the rows in view, as the app does when it
/// arrives: every identifier a token, in turn a property, a function and a
/// variable, encoded as ZLS sends them. Reports the answer's bytes.
fn decode(gpa: std.mem.Allocator, io: std.Io, buffer: *const Buffer) !void {
    var viewport: Viewport = .{};
    viewport.follow(buffer, rows, columns, false);
    const top = viewport.top;
    const bottom = @min(buffer.insertionRows(), top + rows);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const writer = &body.writer;
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"data\":[");
    var count: usize = 0;
    var line: usize = 0;
    var start: usize = 0;
    for (top..bottom) |row| {
        const text = buffer.line(row);
        var position: usize = 0;
        while (position < text.len) {
            const first = position;
            while (position < text.len and std.ascii.isAlphabetic(text[position])) position += 1;
            if (position == first) {
                position += 1;
                continue;
            }
            const lines = row - line;
            const column = if (lines == 0) first - start else first;
            if (count != 0) try writer.writeByte(',');
            try writer.print("{d},{d},{d},{d},0", .{ lines, column, position - first, count % 3 });
            line = row;
            start = first;
            count += 1;
        }
    }
    try writer.writeAll("]}}");
    const legend: nib.protocol.Legend = .init(&.{ "property", "function", "variable" });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var times: [samples]i96 = undefined;
    for (&times) |*elapsed| {
        _ = arena.reset(.retain_capacity);
        const before = std.Io.Timestamp.now(io, .awake);
        var held = (try nib.protocol.tokensReply(
            gpa,
            arena.allocator(),
            body.written(),
            &legend,
            .utf8,
            buffer,
            .none,
            top,
            bottom,
        )).?;
        const after = std.Io.Timestamp.now(io, .awake);
        held.deinit(gpa);
        elapsed.* = before.durationTo(after).toNanoseconds();
    }
    var label: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&label, "decode {d} tokens, {d} bytes", .{ count, body.written().len });
    summary(name catch unreachable, &times);
}

/// Queueing the `didChange` for an edit of one middle line, as changed
/// lines and as the whole text. Reports each message's bytes.
fn change(gpa: std.mem.Allocator, io: std.Io, buffer: *const Buffer) !void {
    const count = buffer.insertionRows();
    const middle = count / 2;
    const record: nib.buffer.ChangedRows = .{ .lines = .{
        .first = middle,
        .unchanged = count - middle - 1,
        .rows = count,
    } };
    var queue: std.ArrayList(u8) = .empty;
    defer queue.deinit(gpa);
    for ([_]nib.buffer.ChangedRows{ record, .whole }) |changed| {
        var times: [samples]i96 = undefined;
        for (&times) |*elapsed| {
            queue.clearRetainingCapacity();
            const before = std.Io.Timestamp.now(io, .awake);
            const text = nib.protocol.textChange(buffer, changed).?;
            try nib.protocol.didChange(gpa, &queue, "/p/fixture.zig", 1, text);
            const after = std.Io.Timestamp.now(io, .awake);
            elapsed.* = before.durationTo(after).toNanoseconds();
        }
        var label: [64]u8 = undefined;
        const kind = if (changed == .whole) "whole text" else "changed line";
        const name = std.fmt.bufPrint(&label, "didChange, {s}, {d} bytes", .{ kind, queue.items.len });
        summary(name catch unreachable, &times);
    }
}

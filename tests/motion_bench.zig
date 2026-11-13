// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const nib = @import("nib");
const Buffer = nib.buffer.Buffer;
const motion = nib.motion;
const search = nib.search;
const Viewport = nib.viewport.Viewport;
const Highlights = nib.viewport.Highlights;
const Span = nib.viewport.Span;

// Per-key motion work as the event loop does it, without a terminal: resolve
// the motion, move the cursor, follow it, place the terminal cursor and compute
// the status column. Each sample starts from the same cursor, 90% of the way
// along the middle line, where column scans are longest. Rendering and output
// are not timed with the motions; a separate sample renders every content row
// once the view follows the cursor, and again with every row selected by `V`
// redrawn over it, as the editor view does. Search samples time one incremental query
// change, for a query that is found and one that is not, and again on an
// 8 MiB file with no match. Output is not written. No timing threshold is a
// test.
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
            // A whole content area scrolled to the cursor, as one frame draws it.
            buffer.cursor = origin;
            viewport = .{};
            viewport.follow(&buffer, rows, columns, false);
            var output: [3 * columns]u8 = undefined;
            var times: [samples]i96 = undefined;
            for (&times) |*elapsed| {
                const before = std.Io.Timestamp.now(init.io, .awake);
                for (0..rows) |content| {
                    const used = viewport.renderRow(&buffer, content, columns, &output);
                    std.mem.doNotOptimizeAway(output[0..used]);
                }
                const after = std.Io.Timestamp.now(init.io, .awake);
                elapsed.* = before.durationTo(after).toNanoseconds();
            }
            summary("render 50x200", &times);
            const selected = motion.visualRange(&buffer, 0, text.len - 1, .linewise, null).range;
            for (&times) |*elapsed| {
                const before = std.Io.Timestamp.now(init.io, .awake);
                for (0..rows) |content| {
                    const used = viewport.renderRow(&buffer, content, columns, &output);
                    std.mem.doNotOptimizeAway(output[0..used]);
                }
                const last = @min(buffer.lineCount(), viewport.top + rows);
                for (viewport.top..last) |number| {
                    const line_start = buffer.lineStart(number);
                    const line_end = buffer.contentEnd(number);
                    const span = Span.init(
                        buffer.line(number),
                        @max(selected.start, line_start) - line_start,
                        @min(selected.end, line_end) - line_start,
                        selected.end > line_end,
                        viewport.left,
                        columns,
                    ) orelse continue;
                    std.mem.doNotOptimizeAway(output[0..span.render(&output)]);
                }
                const after = std.Io.Timestamp.now(init.io, .awake);
                elapsed.* = before.durationTo(after).toNanoseconds();
            }
            summary("render 50x200, all selected", &times);
            for ([_][]const u8{ line.found, line.missing }) |query| {
                incremental(init.io, &buffer, origin, query);
            }
        }
    }
    // The largest file Nib loads; the missing query's first letter is common.
    const large = try fixture(init.gpa, lines[0].text, false, 8 * 1024 * 1024);
    defer init.gpa.free(large);
    var buffer = try Buffer.fromBytes(init.gpa, large);
    defer buffer.deinit(init.gpa);
    std.debug.print("ASCII 8 MiB source, {d} bytes, cursor at the start:\n", .{large.len});
    incremental(init.io, &buffer, 0, lines[0].missing);
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

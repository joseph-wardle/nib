// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Buffer = @import("nib").buffer.Buffer;

// Storage-only measurement: no terminal, file I/O, save, or presentation claims.
// Retain 1,000 insertion deltas in one command, including a newline every 16
// edits, then undo/redo the complete command. No timing threshold is a test.
pub fn main(init: std.process.Init) !void {
    const samples = 1000;
    const fixtures = [_]struct { name: []const u8, size: usize, width: usize }{
        .{ .name = "100KiB source", .size = 100 * 1024, .width = 80 },
        .{ .name = "100KiB long line", .size = 100 * 1024, .width = 0 },
        .{ .name = "near byte/line caps", .size = 8 * 1024 * 1024 - 4096, .width = 32 },
        .{ .name = "near byte cap long line", .size = 8 * 1024 * 1024 - 4096, .width = 0 },
        .{ .name = "near line cap", .size = (256 * 1024 - 128) * 2, .width = 2 },
    };
    for (fixtures) |fixture| {
        const input = try init.gpa.alloc(u8, fixture.size);
        defer init.gpa.free(input);
        @memset(input, 'x');
        if (fixture.width != 0) {
            var i = fixture.width - 1;
            while (i < input.len) : (i += fixture.width) input[i] = '\n';
        }
        for ([_][]const u8{ "start", "middle", "end" }) |location| {
            var accounting = std.testing.FailingAllocator.init(init.gpa, .{});
            const allocator = accounting.allocator();
            var buffer = try Buffer.fromBytes(allocator, input);
            defer buffer.deinit(allocator);
            const initial_bytes = accounting.allocated_bytes - accounting.freed_bytes;
            var times: [samples]i96 = undefined;
            buffer.beginGroup();
            for (&times, 0..) |*elapsed, i| {
                const offset = if (std.mem.eql(u8, location, "start")) 0 else if (std.mem.eql(u8, location, "middle")) buffer.bytes().len / 2 else buffer.bytes().len;
                const before = std.Io.Timestamp.now(init.io, .awake);
                try buffer.replace(allocator, .{ .start = offset, .end = offset }, if (i % 16 == 0) "\n" else "a", offset + 1);
                elapsed.* = before.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds();
            }
            buffer.endGroup();
            const retained_bytes = accounting.allocated_bytes - accounting.freed_bytes;
            const before_undo = std.Io.Timestamp.now(init.io, .awake);
            if (!try buffer.undo(allocator)) return error.MissingUndo;
            const after_undo = std.Io.Timestamp.now(init.io, .awake);
            if (!std.mem.eql(u8, buffer.bytes(), input)) return error.IncorrectUndo;
            const before_redo = std.Io.Timestamp.now(init.io, .awake);
            if (!try buffer.redo(allocator)) return error.MissingRedo;
            const after_redo = std.Io.Timestamp.now(init.io, .awake);
            if (!std.mem.eql(u8, buffer.base, input) or buffer.bytes().len != input.len + samples) return error.IncorrectResult;
            std.mem.sort(i96, &times, {}, std.sort.asc(i96));
            std.debug.print("{s}, {s}: insert p50/p99/max {d}/{d}/{d} ns; group undo/redo {d}/{d} us; retained initial/final {d}/{d} bytes\n", .{
                fixture.name,                                                        location,                                                            times[samples / 2], times[990],     times[samples - 1],
                @divTrunc(before_undo.durationTo(after_undo).toNanoseconds(), 1000), @divTrunc(before_redo.durationTo(after_redo).toNanoseconds(), 1000), initial_bytes,      retained_bytes,
            });
        }
    }
}

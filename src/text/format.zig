// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const char = @import("char.zig");
const Range = @import("buffer.zig").Range;

// Formatting a document's text: which formatter a path uses, the formatted
// text or why there is none, and the one replacement that turns the old text
// into the new. Pure apart from allocation; the caller applies the change.

/// How a file is formatted. Each formatter produces the whole new text, so
/// one replacement step serves every one.
pub const Formatter = enum {
    /// `std.zig.Ast` in Zig mode: the formatter behind `zig fmt`.
    zig,
    /// The same, in ZON mode.
    zon,
};

/// The formatter for `path`, by extension, or null for a file Nib doesn't format.
pub fn formatterFor(path: []const u8) ?Formatter {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".zig")) return .zig;
    if (std.mem.eql(u8, extension, ".zon")) return .zon;
    return null;
}

/// A position in the source, both 1-based; the column counts bytes, as `zig fmt` does.
pub const Position = struct { line: usize, column: usize };

pub const Outcome = union(enum) {
    /// The new text, owned by the caller and freed with the allocator given to `format`.
    formatted: []u8,
    /// The text is already formatted.
    unchanged,
    /// The text doesn't parse; the first error's position.
    syntax_error: Position,
};

/// Formats `text`. Allocates a sentinel-terminated copy of it for the parser
/// and frees everything but a `formatted` result before returning.
pub fn format(
    allocator: Allocator,
    formatter: Formatter,
    text: []const u8,
) Allocator.Error!Outcome {
    const source = try allocator.dupeSentinel(u8, text, 0);
    defer allocator.free(source);
    const mode: std.zig.Ast.Mode = switch (formatter) {
        .zig => .zig,
        .zon => .zon,
    };
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = mode });
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        const first = tree.errors[0];
        const location = tree.tokenLocation(0, first.token);
        return .{ .syntax_error = .{
            .line = location.line + 1,
            .column = location.column + tree.errorOffset(first) + 1,
        } };
    }
    const formatted = try tree.renderAlloc(allocator);
    if (std.mem.eql(u8, formatted, text)) {
        allocator.free(formatted);
        return .unchanged;
    }
    return .{ .formatted = formatted };
}

/// One replacement that turns `old` into `new`: `range` in `old` is replaced
/// by `inserted`, a slice of `new`, and `cursor` is where `old`'s cursor goes
/// in the result: on a character, as normal mode needs.
pub const Change = struct { range: Range, inserted: []const u8, cursor: usize };

/// The smallest single replacement between `old` and `new`, with both ends on
/// character boundaries of each, so it never splits a UTF-8 sequence or CRLF.
/// The cursor keeps its place in the unchanged text around the range; inside
/// it, the cursor goes to the same count of non-whitespace bytes from the
/// range's start, which follows its token while formatting moves only
/// whitespace. A cursor on whitespace goes to the next token. One that would
/// end on a line break or past the text steps back onto the line's last
/// character, as `motion.normal` places it.
pub fn change(old: []const u8, new: []const u8, cursor: usize) Change {
    const shorter = @min(old.len, new.len);
    var prefix: usize = 0;
    while (prefix < shorter and old[prefix] == new[prefix]) prefix += 1;
    while (!boundary(old, prefix) or !boundary(new, prefix)) prefix -= 1;
    var suffix: usize = 0;
    while (suffix < shorter - prefix and
        old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    while (!boundary(old, old.len - suffix) or !boundary(new, new.len - suffix)) suffix -= 1;

    const range: Range = .{ .start = prefix, .end = old.len - suffix };
    const inserted = new[prefix .. new.len - suffix];
    const placed = if (cursor < range.start)
        cursor
    else if (cursor >= range.end)
        cursor - range.end + range.start + inserted.len
    else
        range.start + nonWhitespace(inserted, countNonWhitespace(old[range.start..cursor]));
    const landed = normal(new, char.start(new, placed));
    return .{ .range = range, .inserted = inserted, .cursor = landed };
}

/// `offset`, a boundary of `text`, or the last character of its line when it
/// is on a line break or at the end; an empty line keeps its start. The text's
/// end after a final line break belongs to the last line, as in `Buffer`.
fn normal(text: []const u8, offset: usize) usize {
    var placed = offset;
    const after_break = placed == text.len and placed != 0 and text[placed - 1] == '\n';
    if (after_break) placed = char.previous(text, placed);
    const on_break = placed == text.len or text[placed] == '\n' or text[placed] == '\r';
    if (on_break and placed != 0 and text[placed - 1] != '\n') placed = char.previous(text, placed);
    return placed;
}

fn boundary(bytes: []const u8, offset: usize) bool {
    return char.start(bytes, offset) == offset;
}

fn whitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn countNonWhitespace(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| count += @intFromBool(!whitespace(byte));
    return count;
}

/// The offset of the non-whitespace byte that has `count` others before it,
/// or `bytes.len` if there is none.
fn nonWhitespace(bytes: []const u8, count: usize) usize {
    var seen: usize = 0;
    for (bytes, 0..) |byte, offset| {
        if (whitespace(byte)) continue;
        if (seen == count) return offset;
        seen += 1;
    }
    return bytes.len;
}

const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");

fn expectFormatted(formatter: Formatter, text: []const u8, expected: []const u8) !void {
    const outcome = try format(testing.allocator, formatter, text);
    defer if (outcome == .formatted) testing.allocator.free(outcome.formatted);
    try testing.expectEqualStrings(expected, outcome.formatted);
}

/// Applies `delta` to `old` as the buffer would, for checking a change.
fn applied(old: []const u8, delta: Change) ![]u8 {
    return std.mem.concat(testing.allocator, u8, &.{
        old[0..delta.range.start],
        delta.inserted,
        old[delta.range.end..],
    });
}

test "a file's extension chooses its formatter" {
    try testing.expectEqual(Formatter.zig, formatterFor("src/app.zig").?);
    try testing.expectEqual(Formatter.zon, formatterFor("build.zig.zon").?);
    try testing.expectEqual(null, formatterFor("README.md"));
    try testing.expectEqual(null, formatterFor("shaders/a.slang"));
    try testing.expectEqual(null, formatterFor("zig"));
}

test "Zig and ZON format as zig fmt formats them" {
    // Expected texts are zig fmt's output (Zig 0.17.1).
    try expectFormatted(.zig, "const  x=1;\nfn f( )void{ }\n", "const x = 1;\nfn f() void {}\n");
    const accented = "const s = \"é\";const  t = 2;\n";
    try expectFormatted(.zig, accented, "const s = \"é\";\nconst t = 2;\n");
    try expectFormatted(.zig, "fn f() void {\n\treturn;\n}\n", "fn f() void {\n    return;\n}\n");
    try expectFormatted(.zon, ".{.a=1,}\n", ".{\n    .a = 1,\n}\n");
    try expectFormatted(
        .zon,
        ".{ .name = .nib,.version=\"0.0.0\", .paths = .{\"src\"} }\n",
        ".{ .name = .nib, .version = \"0.0.0\", .paths = .{\"src\"} }\n",
    );
}

test "formatting takes the formatter's line endings and final newline" {
    const crlf = "const x = 1;\r\nfn f() void {}\r\n";
    try expectFormatted(.zig, crlf, "const x = 1;\nfn f() void {}\n");
    try expectFormatted(.zig, "const x = 1;", "const x = 1;\n");
}

test "formatted text and an empty file are unchanged" {
    const cases = [_]struct { formatter: Formatter, text: []const u8 }{
        .{ .formatter = .zig, .text = "const x = 1;\n" },
        .{ .formatter = .zig, .text = "" },
        .{ .formatter = .zon, .text = ".{}\n" },
    };
    for (cases) |case| {
        const outcome = try format(testing.allocator, case.formatter, case.text);
        try testing.expectEqual(Outcome.unchanged, outcome);
    }
}

test "a syntax error gives the first error's line and byte column" {
    const cases = [_]struct { text: []const u8, line: usize, column: usize }{
        // zig fmt reports `<stdin>:1:11: error: expected expression, found ';'`.
        .{ .text = "const x = ;\n", .line = 1, .column = 11 },
        .{ .text = "const a = 1;\nconst b = 2\nconst c = 3;\n", .line = 2, .column = 12 },
        .{ .text = "const s = \"é\"; = \n", .line = 1, .column = 17 },
    };
    for (cases) |case| {
        const outcome = try format(testing.allocator, .zig, case.text);
        const position: Position = .{ .line = case.line, .column = case.column };
        try testing.expectEqualDeep(Outcome{ .syntax_error = position }, outcome);
    }
    // ZON mode refuses Zig declarations.
    try testing.expect(try format(testing.allocator, .zon, "const x = 1;\n") == .syntax_error);
}

test "formatting frees everything on allocation failure" {
    const run = struct {
        fn run(allocator: Allocator, formatter: Formatter, text: []const u8) !void {
            const outcome = try format(allocator, formatter, text);
            if (outcome == .formatted) allocator.free(outcome.formatted);
        }
    }.run;
    const cases = [_]struct { formatter: Formatter, text: []const u8 }{
        .{ .formatter = .zig, .text = "const  x=1;\nfn f( )void{ }\n" },
        .{ .formatter = .zig, .text = "const x = ;\n" },
        .{ .formatter = .zon, .text = ".{.a=1,}\n" },
    };
    for (cases) |case| {
        const arguments = .{ case.formatter, case.text };
        try testing.checkAllAllocationFailures(testing.allocator, run, arguments);
    }
}

test "a change replaces only what differs and reproduces the new text" {
    const cases = [_]struct { old: []const u8, new: []const u8, start: usize, end: usize }{
        .{ .old = "const  x=1;\n", .new = "const x = 1;\n", .start = 6, .end = 9 },
        .{ .old = "a\nb\n", .new = "a\nb\n", .start = 4, .end = 4 },
        .{ .old = "a", .new = "a\n", .start = 1, .end = 1 },
        .{ .old = "", .new = "x\n", .start = 0, .end = 0 },
        .{ .old = "x  ", .new = "x", .start = 1, .end = 3 },
        // Repeated bytes: the prefix takes them first, so the suffix can't overlap it.
        .{ .old = "aaa", .new = "aaaa", .start = 3, .end = 3 },
    };
    for (cases) |case| {
        const delta = change(case.old, case.new, 0);
        try testing.expectEqual(case.start, delta.range.start);
        try testing.expectEqual(case.end, delta.range.end);
        const result = try applied(case.old, delta);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(case.new, result);
    }
}

test "a change never splits a UTF-8 sequence or a CRLF" {
    const cases = [_]struct { old: []const u8, new: []const u8 }{
        // é (C3 A9) and è (C3 A8) share their first byte.
        .{ .old = "x = \"é\";\n", .new = "x = \"è\";\n" },
        // ¿ (C2 BF) and ÿ (C3 BF) share their last byte.
        .{ .old = "\"¿\"", .new = "\"ÿ\"" },
        // A CRLF becomes LF: the CR goes with its LF.
        .{ .old = "a\r\nb\r\n", .new = "a\nb\n" },
        .{ .old = "a\r\n", .new = "a\r\r\n" },
    };
    for (cases) |case| {
        const delta = change(case.old, case.new, 0);
        try testing.expect(boundary(case.old, delta.range.start));
        try testing.expect(boundary(case.old, delta.range.end));
        try testing.expect(char.editable(delta.inserted) or !char.editable(case.new));
        try testing.expect(std.unicode.utf8ValidateSlice(delta.inserted));
        const result = try applied(case.old, delta);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(case.new, result);
    }
    const crlf = change("a\r\nb\r\n", "a\nb\n", 0);
    try testing.expectEqual(1, crlf.range.start);
    try testing.expectEqualStrings("\nb\n", crlf.inserted);
}

test "the cursor follows its token through a change" {
    const old = "fn f( )void{\n  return  x;\n}\n";
    const new = "fn f() void {\n    return x;\n}\n";
    const cases = [_]struct { at: []const u8, lands: []const u8 }{
        // Before the changed range: unchanged.
        .{ .at = "fn f(", .lands = "fn f(" },
        // On a token inside it: the same token.
        .{ .at = "void", .lands = "void" },
        .{ .at = "return", .lands = "return" },
        .{ .at = "x;", .lands = "x;" },
        // On whitespace: the next token.
        .{ .at = "  return", .lands = "return" },
        // Whitespace kept after the range stays where it was.
        .{ .at = " x;", .lands = " x;" },
        // After the changed range: the same text.
        .{ .at = "}", .lands = "}" },
    };
    for (cases) |case| {
        const cursor = std.mem.indexOf(u8, old, case.at).?;
        const delta = change(old, new, cursor);
        try testing.expectEqual(std.mem.indexOf(u8, new, case.lands).?, delta.cursor);
    }
    // At the end of the text it lands on the last character.
    try testing.expectEqual(new.len - 2, change(old, new, old.len).cursor);
}

test "a cursor lands on a character of the new text" {
    // The cursor on `é` stays on its first byte.
    const old = "x  = \"é\";\n";
    const new = "x = \"é\";\n";
    const delta = change(old, new, std.mem.indexOf(u8, old, "é").?);
    try testing.expectEqual(std.mem.indexOf(u8, new, "é").?, delta.cursor);
    // Past the last token of the range is the line break: back onto `a`.
    const trailing = change("a  \r\n", "a\n", 2);
    try testing.expectEqual(0, trailing.cursor);
}

test "a cursor is placed on a line as motion.normal places it" {
    const texts = [_][]const u8{
        "",
        "a",
        "a\n",
        "a\n\n",
        "\n",
        "ab\r\n",
        "ab\r\ncd",
        "é\n",
        "a\n\nb\n",
        "\r\n\r\n",
    };
    for (texts) |text| {
        var buffer = try Buffer.fromBytes(testing.allocator, text);
        defer buffer.deinit(testing.allocator);
        for (0..text.len + 1) |offset| {
            if (!boundary(text, offset)) continue;
            try testing.expectEqual(motion.normal(&buffer, offset), normal(text, offset));
        }
    }
}

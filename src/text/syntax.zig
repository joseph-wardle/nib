// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const ChangedRows = @import("buffer.zig").ChangedRows;

/// A language Nib colours.
pub const Language = enum { zig };

/// What a coloured token is. Everything else in a line (identifiers,
/// operators, punctuation, spaces) has no kind. The lexer never finds a
/// function or a field; only a language server tells them apart.
pub const Kind = enum {
    /// `//` to the end of the line, doc comments included.
    comment,
    keyword,
    /// String and character literals and `\\` lines.
    string,
    /// Numbers and `true`, `false`, `null` and `undefined`.
    constant,
    /// `@name`, but not the quoted identifier `@"name"`.
    builtin,
    /// Primitive type names: `u8`, `bool`, `type`, `void`, …, and from a
    /// language server, any type or namespace.
    type,
    /// A function or method.
    function,
    /// A struct field.
    field,
};

/// The language of the file at `path`, by extension, or null when Nib
/// doesn't colour it. ZON is Zig syntax.
pub fn language(path: []const u8) ?Language {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".zig") or std.mem.eql(u8, extension, ".zon")) return .zig;
    return null;
}

pub const Token = struct { start: usize, end: usize, kind: Kind };

/// The coloured tokens of one line of Zig, left to right, as byte ranges.
/// The bytes between them have no kind. A line is coloured alone: Zig has no
/// block comments, its strings and character literals cannot span lines, and a
/// multiline string marks every line with `\\`. Any bytes are accepted;
/// an unterminated literal ends with the line. Borrows `text`, which
/// excludes the line break.
pub const Tokens = struct {
    text: []const u8,
    position: usize = 0,

    pub fn init(text: []const u8) Tokens {
        return .{ .text = text };
    }

    pub fn next(self: *Tokens) ?Token {
        const text = self.text;
        while (self.position < text.len) {
            const start = self.position;
            const byte = text[start];
            const rest = text[start..];
            if (std.mem.startsWith(u8, rest, "//") or std.mem.startsWith(u8, rest, "\\\\")) {
                self.position = text.len;
                const kind: Kind = if (byte == '/') .comment else .string;
                return .{ .start = start, .end = text.len, .kind = kind };
            }
            if (byte == '"' or byte == '\'') {
                self.position = quoted(text, start);
                return .{ .start = start, .end = self.position, .kind = .string };
            }
            if (byte == '@') {
                if (start + 1 < text.len and text[start + 1] == '"') {
                    // A quoted identifier has no kind.
                    self.position = quoted(text, start + 1);
                    continue;
                }
                self.position = word(text, start + 1);
                if (self.position == start + 1) continue;
                return .{ .start = start, .end = self.position, .kind = .builtin };
            }
            if (std.ascii.isDigit(byte)) {
                self.position = number(text, start);
                return .{ .start = start, .end = self.position, .kind = .constant };
            }
            if (std.ascii.isAlphabetic(byte) or byte == '_') {
                self.position = word(text, start);
                const name = text[start..self.position];
                const kind: Kind = if (std.zig.Token.getKeyword(name) != null)
                    .keyword
                else if (constants.has(name))
                    .constant
                else if (std.zig.primitives.isPrimitive(name))
                    .type
                else
                    continue;
                return .{ .start = start, .end = self.position, .kind = kind };
            }
            self.position += 1;
        }
        return null;
    }
};

/// A token a language server tagged, by byte column in its line. A null
/// kind is drawn plain, whatever the lexer would make of its bytes.
pub const Tagged = struct { start: usize, end: usize, kind: ?Kind };

/// A language server's tokens for consecutive rows, kept while the text
/// changes. Rows are numbered in the text from when `changed` was last
/// reset; their columns are bytes of that text, where each row's tokens are
/// in order, apart, within it and on character boundaries. Owns its lists.
pub const Held = struct {
    /// The first row covered.
    top: usize = 0,
    /// Where each covered row's tokens end in `tokens`.
    ends: std.ArrayList(usize) = .empty,
    tokens: std.ArrayList(Tagged) = .empty,
    /// The edits since the tokens' text that no longer show in the buffer's
    /// own record: each sync merges in the record it takes.
    changed: ChangedRows = .none,

    pub fn deinit(self: *Held, allocator: Allocator) void {
        self.ends.deinit(allocator);
        self.tokens.deinit(allocator);
        self.* = undefined;
    }

    /// The tokens for `row` of a buffer with `rows` rows, where `pending`
    /// is the buffer's `changed_rows`. A row changed since the tokens' text,
    /// or not covered, has none. Borrowed until the set changes.
    pub fn row(self: *const Held, pending: ChangedRows, rows: usize, shown: usize) []const Tagged {
        const earlier = self.changed.then(pending).before(shown, rows) orelse return &.{};
        if (earlier < self.top or earlier - self.top >= self.ends.items.len) return &.{};
        const index = earlier - self.top;
        const start = if (index == 0) 0 else self.ends.items[index - 1];
        return self.tokens.items[start..self.ends.items[index]];
    }
};

/// The coloured tokens of one line: the `tagged` tokens with a kind, and
/// the lexer's tokens, cut to the bytes no tagged token covers. In order and
/// apart, like `Tokens`. Borrows both.
pub const Merged = struct {
    lexer: Tokens,
    /// The lexer token after `position`'s, once read.
    waiting: ?Token = null,
    tagged: []const Tagged,
    /// The next tagged token.
    index: usize = 0,
    /// Every byte before it is drawn.
    position: usize = 0,

    pub fn init(text: []const u8, tagged: []const Tagged) Merged {
        return .{ .lexer = .init(text), .tagged = tagged };
    }

    pub fn next(self: *Merged) ?Token {
        const text = self.lexer.text;
        while (true) {
            const tagged = self.index < self.tagged.len;
            const gap_end = if (tagged) self.tagged[self.index].start else text.len;
            if (self.position < gap_end) {
                const found = self.waiting orelse self.lexer.next() orelse {
                    self.position = gap_end;
                    continue;
                };
                if (found.end <= self.position) {
                    self.waiting = null;
                    continue;
                }
                if (found.start >= gap_end) {
                    self.waiting = found;
                    self.position = gap_end;
                    continue;
                }
                const start = @max(found.start, self.position);
                const end = @min(found.end, gap_end);
                self.waiting = if (found.end > gap_end) found else null;
                self.position = end;
                return .{ .start = start, .end = end, .kind = found.kind };
            }
            if (self.index == self.tagged.len) return null;
            const token = self.tagged[self.index];
            self.index += 1;
            self.position = token.end;
            if (token.kind) |kind| return .{ .start = token.start, .end = token.end, .kind = kind };
        }
    }
};

/// The primitive values, which `isPrimitive` counts with the types.
const constants: std.StaticStringMap(void) = .initComptime(.{
    .{"true"},
    .{"false"},
    .{"null"},
    .{"undefined"},
});

/// The end of the literal opened by the quote at `start`: after its closing
/// quote, skipping each escaped byte, or the end of the line.
fn quoted(text: []const u8, start: usize) usize {
    const quote = text[start];
    var position = start + 1;
    while (position < text.len) : (position += 1) {
        if (text[position] == '\\') {
            position += 1;
        } else if (text[position] == quote) {
            return position + 1;
        }
    }
    return text.len;
}

/// The end of the identifier characters from `start`.
fn word(text: []const u8, start: usize) usize {
    var position = start;
    while (position < text.len) : (position += 1) {
        const byte = text[position];
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') break;
    }
    return position;
}

/// The end of the number literal starting with the digit at `start`: digits,
/// letters, `_` and a `.` not followed by another `.`, so `0..10` is two
/// numbers. A sign continues it after a decimal exponent (`e`, `E`) or a
/// hexadecimal one (`p`, `P`), where `e` is a digit.
fn number(text: []const u8, start: usize) usize {
    const hex = std.mem.startsWith(u8, text[start..], "0x") or
        std.mem.startsWith(u8, text[start..], "0X");
    var position = start + 1;
    while (position < text.len) : (position += 1) {
        const byte = text[position];
        if (std.ascii.isAlphanumeric(byte) or byte == '_') continue;
        if (byte == '.' and !(position + 1 < text.len and text[position + 1] == '.')) continue;
        const exponent: []const u8 = if (hex) "pP" else "eE";
        const sign = byte == '+' or byte == '-';
        if (sign and std.mem.indexOfScalar(u8, exponent, text[position - 1]) != null) continue;
        break;
    }
    return position;
}

const testing = std.testing;

/// Checks a line's tokens, written as `kind:text` separated by spaces.
fn expectTokens(expected: []const u8, text: []const u8) !void {
    var tokens: Tokens = .init(text);
    try expectFound(expected, text, &tokens);
}

/// Checks the tokens `iterator` finds in `text`, as `expectTokens` does.
fn expectFound(expected: []const u8, text: []const u8, iterator: anytype) !void {
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(testing.allocator);
    while (iterator.next()) |token| {
        if (written.items.len != 0) try written.append(testing.allocator, ' ');
        try written.appendSlice(testing.allocator, @tagName(token.kind));
        try written.append(testing.allocator, ':');
        try written.appendSlice(testing.allocator, text[token.start..token.end]);
    }
    try testing.expectEqualStrings(expected, written.items);
}

test "Zig and ZON paths are coloured as Zig, others not at all" {
    try testing.expectEqual(Language.zig, language("src/app.zig").?);
    try testing.expectEqual(Language.zig, language("build.zig.zon").?);
    try testing.expectEqual(@as(?Language, null), language("README.md"));
    try testing.expectEqual(@as(?Language, null), language("zig"));
}

test "each kind is found, and identifiers and punctuation have none" {
    try expectTokens(
        "keyword:const type:u32 builtin:@intCast constant:42",
        "const x: u32 = @intCast(42);",
    );
    try expectTokens("keyword:if keyword:return constant:null", "if (ok) return null;");
    try expectTokens(
        "keyword:const string:\"text\" comment:// green string",
        "const s = \"text\"; // green string",
    );
    try expectTokens("constant:true constant:false constant:undefined", "true false undefined");
    try expectTokens("type:bool type:type type:void type:usize type:i0", "bool type void usize i0");
    try expectTokens("", "b.target();");
    try expectTokens("", "");
}

test "comments, doc comments and multiline strings run to the end of the line" {
    try expectTokens("comment:// a \"b\" const", "// a \"b\" const");
    try expectTokens("comment:/// doc", "/// doc");
    try expectTokens("comment://! container", "//! container");
    try expectTokens("comment://// plain", "//// plain");
    try expectTokens("string:\\\\ const \"x", "    \\\\ const \"x");
    try expectTokens("keyword:const string:\\\\a", "const s = \\\\a");
}

test "literals end where Zig ends them, or with the line" {
    try expectTokens("string:\"// not a comment\"", "\"// not a comment\"");
    try expectTokens("string:\"a\\\"b\" keyword:or", "\"a\\\"b\" or");
    try expectTokens("string:'\\'' string:'x'", "'\\'' 'x'");
    try expectTokens("string:\"\\\\\" constant:1", "\"\\\\\" 1");
    const open = "const s = \"open // still string";
    try expectTokens("keyword:const string:\"open // still string", open);
    try expectTokens("string:'", "'");
    try expectTokens("string:\"\\", "\"\\");
}

test "a quoted identifier has no kind and a builtin needs a name" {
    try expectTokens("builtin:@import string:\"std\"", "@import(\"std\")");
    try expectTokens("keyword:const constant:1", "const @\"while\" = 1;");
    try expectTokens("", "@\"unterminated const");
    try expectTokens("", "@ (");
}

test "identifiers that only start like a kind have none" {
    try expectTokens("", "u8x x1 constant nullable _u8 trueish");
    try expectTokens("type:u8", "u8");
}

test "number literals keep their digits, separators, fractions and exponents" {
    try expectTokens(
        "constant:0x1F constant:1_000 constant:1.5e3 constant:0b1010 constant:0o17",
        "0x1F 1_000 1.5e3 0b1010 0o17",
    );
    try expectTokens("constant:1e-3 constant:0x1p-2 constant:2.5E+10", "1e-3 0x1p-2 2.5E+10");
    // In hexadecimal, `e` is a digit, so a sign after it is subtraction.
    try expectTokens("constant:0x1e constant:3", "0x1e-3");
    try expectTokens("constant:0 constant:10", "0..10");
    try expectTokens("constant:0 constant:2", "x.0 + 2");
    try expectTokens("constant:1", "1-x");
}

test "invalid and non-ASCII bytes are skipped without a kind" {
    try expectTokens("keyword:const string:\"\xff\xfe\"", "\xc3 const \xff \"\xff\xfe\"");
    try expectTokens("comment:// na\u{ef}ve", "x \u{2014} // na\u{ef}ve");
    try expectTokens("", "\x00\x1b[\t\x7f");
}

test "tagged tokens win where they are, and the lexer colours the bytes between" {
    const text = "const x = foo.bar(1); // c";
    const tagged = [_]Tagged{
        .{ .start = 6, .end = 7, .kind = null },
        .{ .start = 10, .end = 13, .kind = .type },
        .{ .start = 14, .end = 17, .kind = .function },
    };
    var merged: Merged = .init(text, &tagged);
    const expected = "keyword:const type:foo function:bar constant:1 comment:// c";
    try expectFound(expected, text, &merged);
    // A plain tag hides the lexer's look, and a tag inside a lexer token
    // leaves the lexer's look on either side.
    const string = "const s = \"abc\";";
    const inside = [_]Tagged{
        .{ .start = 0, .end = 5, .kind = null },
        .{ .start = 12, .end = 13, .kind = .field },
    };
    merged = .init(string, &inside);
    try expectFound("string:\"a field:b string:c\"", string, &merged);
    // Tags covering the whole line leave the lexer nothing.
    const all = [_]Tagged{.{ .start = 0, .end = string.len, .kind = .keyword }};
    merged = .init(string, &all);
    try expectFound("keyword:const s = \"abc\";", string, &merged);
    merged = .init(string, &.{});
    try expectFound("keyword:const string:\"abc\"", string, &merged);
}

test "a held set gives a row its tokens until the row changes" {
    const allocator = testing.allocator;
    var held: Held = .{ .top = 2 };
    defer held.deinit(allocator);
    // Rows 2, 3 and 4 of a ten-row text, the middle one without tokens.
    try held.tokens.appendSlice(allocator, &.{
        .{ .start = 0, .end = 1, .kind = .field },
        .{ .start = 0, .end = 2, .kind = .function },
    });
    try held.ends.appendSlice(allocator, &.{ 1, 1, 2 });
    const field = held.tokens.items[0..1];
    const function = held.tokens.items[1..2];
    try testing.expectEqualSlices(Tagged, field, held.row(.none, 10, 2));
    try testing.expectEqual(0, held.row(.none, 10, 3).len);
    try testing.expectEqualSlices(Tagged, function, held.row(.none, 10, 4));
    try testing.expectEqual(0, held.row(.none, 10, 1).len);
    try testing.expectEqual(0, held.row(.none, 10, 5).len);
    // Two rows added in row 3: row 2 stays, row 4 moves to 6, and row 3,
    // now rows 3 to 5, has none.
    const added: ChangedRows = .{ .lines = .{ .first = 3, .unchanged = 7, .rows = 10 } };
    try testing.expectEqualSlices(Tagged, field, held.row(added, 12, 2));
    try testing.expectEqual(0, held.row(added, 12, 4).len);
    try testing.expectEqualSlices(Tagged, function, held.row(added, 12, 6));
    // The set's own record, from a sync, composes with the buffer's.
    held.changed = added;
    const typed: ChangedRows = .{ .lines = .{ .first = 2, .unchanged = 10, .rows = 12 } };
    try testing.expectEqual(0, held.row(typed, 12, 2).len);
    try testing.expectEqualSlices(Tagged, function, held.row(typed, 12, 6));
    try testing.expectEqualSlices(Tagged, function, held.row(.none, 12, 6));
    // A new buffer's text is all changed.
    try testing.expectEqual(0, held.row(.whole, 12, 6).len);
}

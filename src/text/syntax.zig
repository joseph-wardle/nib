// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");

/// A language Nib colours.
pub const Language = enum { zig };

/// What a coloured token is. Everything else in a line (identifiers,
/// operators, punctuation, spaces) has no kind.
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
    /// Primitive type names: `u8`, `bool`, `type`, `void`, ….
    type,
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
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(testing.allocator);
    var tokens: Tokens = .init(text);
    while (tokens.next()) |token| {
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

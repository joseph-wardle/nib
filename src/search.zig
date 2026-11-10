// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Range = @import("buffer.zig").Range;

// Matching for `/` and `?`: literal text with smart case. Pure: no allocation
// and no I/O. Queries are non-empty printable ASCII (the prompt rejects
// anything else), so a match never starts inside a character or spans a line.

pub const Direction = enum {
    forward,
    backward,

    pub fn reverse(self: Direction) Direction {
        return if (self == .forward) .backward else .forward;
    }
};

pub const Found = struct {
    start: usize,
    /// Whether reaching it passed the end of the text in the search direction.
    wrapped: bool,
};

/// The match `count` steps from `cursor`, wrapping past either end of the
/// text, or null when the text has no match. A forward step takes the first
/// match starting after the current position, a backward step the last one
/// starting before it. Once the steps come back round to the first match, the
/// rest of the count is reduced by the matches in that lap, so any count costs
/// at most two passes over the text. Requires a non-empty query and a count of
/// at least one.
pub fn find(
    text: []const u8,
    query: []const u8,
    cursor: usize,
    direction: Direction,
    count: usize,
) ?Found {
    std.debug.assert(query.len > 0 and count > 0);
    const fold = smartFold(query);
    const first = step(text, query, fold, cursor, direction) orelse return null;
    var found = first;
    var remaining = count - 1;
    var lap: usize = 0;
    while (remaining > 0) {
        const next = step(text, query, fold, found.start, direction).?;
        found = .{ .start = next.start, .wrapped = found.wrapped or next.wrapped };
        remaining -= 1;
        lap += 1;
        if (found.start == first.start) remaining %= lap;
    }
    return found;
}

/// The matches within one line, with overlapping or adjacent matches merged
/// into one span. Offsets are relative to `line`, which borrows the caller's
/// text and must not include its line break.
pub const Spans = struct {
    line: []const u8,
    query: []const u8,
    fold: bool,
    from: usize = 0,

    /// Requires a non-empty query.
    pub fn init(line: []const u8, query: []const u8) Spans {
        std.debug.assert(query.len > 0);
        return .{ .line = line, .query = query, .fold = smartFold(query) };
    }

    pub fn next(self: *Spans) ?Range {
        const any = std.math.maxInt(usize);
        const start = firstIn(self.line, self.query, self.fold, self.from, any) orelse return null;
        var end = start + self.query.len;
        var at = start;
        while (firstIn(self.line, self.query, self.fold, at + 1, end)) |more| {
            at = more;
            end = more + self.query.len;
        }
        self.from = end + 1;
        return .{ .start = start, .end = end };
    }
};

/// ASCII letters match either case unless the query has an uppercase letter.
fn smartFold(query: []const u8) bool {
    for (query) |byte| if (std.ascii.isUpper(byte)) return false;
    return true;
}

fn step(
    text: []const u8,
    query: []const u8,
    fold: bool,
    from: usize,
    direction: Direction,
) ?Found {
    const any = std.math.maxInt(usize);
    switch (direction) {
        .forward => {
            if (firstIn(text, query, fold, from +| 1, any)) |start| {
                return .{ .start = start, .wrapped = false };
            }
            const start = firstIn(text, query, fold, 0, from) orelse return null;
            return .{ .start = start, .wrapped = true };
        },
        .backward => {
            if (from > 0) {
                const below = lastIn(text, query, fold, 0, from - 1);
                if (below) |start| return .{ .start = start, .wrapped = false };
            }
            const start = lastIn(text, query, fold, from, any) orelse return null;
            return .{ .start = start, .wrapped = true };
        },
    }
}

const block_len = 32;
const Block = @Vector(block_len, u8);

/// The first match starting in `low..high` inclusive. Candidates are found
/// a block at a time by the query's first byte in either case, then compared.
fn firstIn(text: []const u8, query: []const u8, fold: bool, low: usize, high: usize) ?usize {
    if (query.len > text.len) return null;
    const top = @min(high, text.len - query.len);
    if (low > top) return null;
    const lower: Block = @splat(firstByte(query, fold, .lower));
    const upper: Block = @splat(firstByte(query, fold, .upper));
    var at = low;
    while (at + (block_len - 1) <= top) : (at += block_len) {
        const block: Block = text[at..][0..block_len].*;
        var candidates: u32 = @bitCast((block == lower) | (block == upper));
        while (candidates != 0) : (candidates &= candidates - 1) {
            const start = at + @ctz(candidates);
            if (matchesAt(text, start, query, fold)) return start;
        }
    }
    while (at <= top) : (at += 1) if (matchesAt(text, at, query, fold)) return at;
    return null;
}

/// The last match starting in `low..high` inclusive, scanning down from `high`.
fn lastIn(text: []const u8, query: []const u8, fold: bool, low: usize, high: usize) ?usize {
    if (query.len > text.len) return null;
    const top = @min(high, text.len - query.len);
    if (low > top) return null;
    const lower: Block = @splat(firstByte(query, fold, .lower));
    const upper: Block = @splat(firstByte(query, fold, .upper));
    // Candidates are below `end`.
    var end = top + 1;
    while (end - low >= block_len) : (end -= block_len) {
        const base = end - block_len;
        const block: Block = text[base..][0..block_len].*;
        var candidates: u32 = @bitCast((block == lower) | (block == upper));
        while (candidates != 0) {
            const bit: u5 = @intCast(block_len - 1 - @clz(candidates));
            if (matchesAt(text, base + bit, query, fold)) return base + bit;
            candidates &= ~(@as(u32, 1) << bit);
        }
    }
    while (end > low) {
        end -= 1;
        if (matchesAt(text, end, query, fold)) return end;
    }
    return null;
}

fn firstByte(query: []const u8, fold: bool, case: enum { lower, upper }) u8 {
    if (!fold) return query[0];
    return if (case == .lower) std.ascii.toLower(query[0]) else std.ascii.toUpper(query[0]);
}

fn matchesAt(text: []const u8, start: usize, query: []const u8, fold: bool) bool {
    const candidate = text[start..][0..query.len];
    if (fold) return std.ascii.eqlIgnoreCase(candidate, query);
    return std.mem.eql(u8, candidate, query);
}

const testing = std.testing;

fn expectFound(expected: ?Found, actual: ?Found) !void {
    try testing.expectEqual(expected, actual);
}

test "a lowercase query folds ASCII case and any uppercase letter makes it exact" {
    const text = "Foo FOO foo";
    try expectFound(.{ .start = 4, .wrapped = false }, find(text, "foo", 0, .forward, 1));
    try expectFound(.{ .start = 0, .wrapped = true }, find(text, "Foo", 0, .forward, 1));
    try expectFound(.{ .start = 4, .wrapped = true }, find(text, "FOO", 4, .forward, 1));
    try expectFound(null, find(text, "fOO", 0, .forward, 1));
    // Digits and punctuation have no case and keep folding on.
    try expectFound(.{ .start = 4, .wrapped = false }, find("x1  X1", "x1", 0, .forward, 1));
}

test "non-ASCII bytes never fold to ASCII and are found only byte-exactly" {
    // 0xd8 and 0xf8 are 'X' and 'x' with the high bit set.
    const text = "\xd8\xf8 caf\xc3\xa9 CAF\xc3\x89";
    try expectFound(null, find(text, "x", 0, .forward, 1));
    try expectFound(.{ .start = 3, .wrapped = false }, find(text, "caf", 0, .forward, 1));
    try expectFound(.{ .start = 9, .wrapped = false }, find(text, "caf", 3, .forward, 1));
}

test "forward and backward skip the cursor and wrap past either end" {
    const text = "ab\nab\nab";
    try expectFound(.{ .start = 3, .wrapped = false }, find(text, "ab", 0, .forward, 1));
    try expectFound(.{ .start = 6, .wrapped = false }, find(text, "ab", 3, .forward, 1));
    try expectFound(.{ .start = 0, .wrapped = true }, find(text, "ab", 6, .forward, 1));
    try expectFound(.{ .start = 3, .wrapped = false }, find(text, "ab", 6, .backward, 1));
    try expectFound(.{ .start = 6, .wrapped = true }, find(text, "ab", 0, .backward, 1));
    // Between matches: the cursor inside the first.
    try expectFound(.{ .start = 3, .wrapped = false }, find(text, "ab", 1, .forward, 1));
    try expectFound(.{ .start = 0, .wrapped = false }, find(text, "ab", 1, .backward, 1));
    // The only match is the cursor's own, reached by wrapping.
    try expectFound(.{ .start = 2, .wrapped = true }, find("x yz", "y", 2, .forward, 1));
    try expectFound(.{ .start = 2, .wrapped = true }, find("x yz", "y", 2, .backward, 1));
    // A cursor at the end of the text, as in an empty last line.
    try expectFound(.{ .start = 0, .wrapped = true }, find("ab\n", "ab", 3, .forward, 1));
    try expectFound(.{ .start = 0, .wrapped = false }, find("ab\n", "ab", 3, .backward, 1));
}

test "matches at the start and end of the text and overlapping matches are found" {
    try expectFound(.{ .start = 4, .wrapped = false }, find("end end", "end", 0, .forward, 1));
    try expectFound(.{ .start = 0, .wrapped = true }, find("end end", "end", 4, .forward, 1));
    try expectFound(.{ .start = 1, .wrapped = false }, find("aaa", "aa", 0, .forward, 1));
    try expectFound(.{ .start = 0, .wrapped = false }, find("aaa", "aa", 1, .backward, 1));
}

test "a query longer than the text or absent from it finds nothing" {
    try expectFound(null, find("", "a", 0, .forward, 1));
    try expectFound(null, find("ab", "abc", 0, .forward, 1));
    try expectFound(null, find("ab", "abc", 2, .backward, 3));
    try expectFound(null, find("abcabc", "abd", 3, .backward, 1));
}

test "read-only text with invalid bytes and lone controls is searchable" {
    const text = "\xff\x00x\r\xc3y\x1bx";
    try expectFound(.{ .start = 7, .wrapped = false }, find(text, "x", 2, .forward, 1));
    try expectFound(.{ .start = 5, .wrapped = true }, find(text, "y", 7, .forward, 1));
}

test "a count takes that many steps, wrapping as often as needed" {
    const text = "x.x.x";
    try expectFound(.{ .start = 4, .wrapped = false }, find(text, "x", 0, .forward, 2));
    try expectFound(.{ .start = 0, .wrapped = true }, find(text, "x", 0, .forward, 3));
    try expectFound(.{ .start = 2, .wrapped = true }, find(text, "x", 0, .forward, 4));
    try expectFound(.{ .start = 0, .wrapped = true }, find(text, "x", 4, .backward, 5));
}

test "a huge count finishes on the match its remainder by the matches selects" {
    const text = "x.x.x...\nx";
    const huge = std.math.maxInt(usize);
    for ([_]Direction{ .forward, .backward }) |direction| {
        for (0..text.len) |cursor| {
            const reduced = (huge - 1) % 4 + 1;
            const expected = find(text, "x", cursor, direction, reduced).?.start;
            const actual = find(text, "x", cursor, direction, huge).?;
            try testing.expectEqual(expected, actual.start);
            try testing.expect(actual.wrapped);
        }
    }
}

test "matches in a line are merged where they overlap or touch" {
    var spans = Spans.init("aaaa b abab AB", "ab");
    // "aaaa b" has no "ab"; "abab" is one span; "AB" folds.
    try testing.expectEqual(Range{ .start = 7, .end = 11 }, spans.next().?);
    try testing.expectEqual(Range{ .start = 12, .end = 14 }, spans.next().?);
    try testing.expectEqual(@as(?Range, null), spans.next());

    var overlapping = Spans.init("aaaa", "aa");
    try testing.expectEqual(Range{ .start = 0, .end = 4 }, overlapping.next().?);
    try testing.expectEqual(@as(?Range, null), overlapping.next());

    var exact = Spans.init("Ab ab Ab", "Ab");
    try testing.expectEqual(Range{ .start = 0, .end = 2 }, exact.next().?);
    try testing.expectEqual(Range{ .start = 6, .end = 8 }, exact.next().?);
    try testing.expectEqual(@as(?Range, null), exact.next());

    var none = Spans.init("", "a");
    try testing.expectEqual(@as(?Range, null), none.next());
}

/// A byte-at-a-time reference for the block scans.
fn naiveStep(text: []const u8, query: []const u8, from: usize, direction: Direction) ?Found {
    const fold = smartFold(query);
    if (query.len > text.len) return null;
    const last = text.len - query.len;
    var start: ?usize = null;
    var wrapped = false;
    switch (direction) {
        .forward => {
            for (0..last + 1) |at| if (at > from and matchesAt(text, at, query, fold)) {
                start = at;
                break;
            };
            if (start == null) for (0..last + 1) |at| if (matchesAt(text, at, query, fold)) {
                start = at;
                wrapped = true;
                break;
            };
        },
        .backward => {
            for (0..last + 1) |at| if (at < from and matchesAt(text, at, query, fold)) {
                start = at;
            };
            if (start == null) for (0..last + 1) |at| if (matchesAt(text, at, query, fold)) {
                start = at;
                wrapped = true;
            };
        },
    }
    return .{ .start = start orelse return null, .wrapped = wrapped };
}

test "the block scans agree with a byte-at-a-time scan across block boundaries and tails" {
    var prng = std.Random.DefaultPrng.init(0x5ea4c4);
    const random = prng.random();
    const alphabet = "aAbB\n\xc1\xe1";
    var text_storage: [3 * block_len + 7]u8 = undefined;
    var query_storage: [4]u8 = undefined;
    for (0..400) |_| {
        const text = text_storage[0..random.uintAtMost(usize, text_storage.len)];
        for (text) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const query = query_storage[0 .. 1 + random.uintLessThan(usize, query_storage.len)];
        for (query) |*byte| byte.* = "aAbB"[random.uintLessThan(usize, 4)];
        for (0..text.len + 1) |cursor| for ([_]Direction{ .forward, .backward }) |direction| {
            var expected = naiveStep(text, query, cursor, direction);
            for (1..4) |count| {
                if (count > 1) {
                    if (expected) |previous| {
                        const next = naiveStep(text, query, previous.start, direction).?;
                        const wrapped = previous.wrapped or next.wrapped;
                        expected = .{ .start = next.start, .wrapped = wrapped };
                    }
                }
                try expectFound(expected, find(text, query, cursor, direction, count));
            }
        };
        // Spans cover exactly the matched bytes, and separate spans neither
        // overlap nor touch.
        var matched: [text_storage.len]bool = @splat(false);
        for (0..text.len) |at| {
            if (at + query.len > text.len) break;
            if (!matchesAt(text, at, query, smartFold(query))) continue;
            @memset(matched[at..][0..query.len], true);
        }
        var covered: [text_storage.len]bool = @splat(false);
        var spans = Spans.init(text, query);
        var previous_end: ?usize = null;
        while (spans.next()) |span| {
            if (previous_end) |end| try testing.expect(span.start > end);
            previous_end = span.end;
            @memset(covered[span.start..span.end], true);
        }
        try testing.expectEqualSlices(bool, matched[0..text.len], covered[0..text.len]);
    }
}

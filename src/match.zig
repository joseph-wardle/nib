// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const discovery = @import("discovery.zig");

pub const Error = Allocator.Error || error{Canceled};

/// Longest query accepted; highlight buffers are sized for it.
pub const max_query = 256;

/// Whether Git ignores a candidate. Unknown unless Git listed the ignored
/// paths for this catalog; never guessed.
pub const Ignore = enum(u8) { unknown, ignored, visible };

/// One searchable candidate.
pub const Entry = struct {
    /// Raw bytes as discovered, used to open the file.
    path: []const u8,
    /// What is shown and searched: `path`, or an unambiguous escaped form
    /// when it holds a backslash, control or non-ASCII byte.
    label: []const u8,
    /// Position in the inventory the catalog was built from.
    origin: u32,
};

pub const Match = struct { index: u32, score: i32 };

/// Candidates sorted by label, so ranking ties break by path. `entries` and
/// `ignored` are immutable once the catalog is shared and may be read by a
/// filter job. `references` belongs to the UI thread, which is also the only
/// thread that retains and releases.
pub const Catalog = struct {
    paths: discovery.Inventory,
    /// Storage for escaped labels.
    escaped: []u8,
    entries: []Entry,
    /// Per entry, in `entries` order.
    ignored: []Ignore,
    references: usize = 1,

    /// Takes ownership of `paths`, even on failure. The caller releases the
    /// result.
    pub fn create(
        gpa: Allocator,
        paths: discovery.Inventory,
        cancel: ?*const discovery.Cancel,
    ) Error!*Catalog {
        var owned = paths;
        errdefer owned.deinit(gpa);
        var escaped_len: usize = 0;
        for (0..owned.count()) |index| escaped_len += escapedLength(owned.path(index));
        const escaped = try gpa.alloc(u8, escaped_len);
        errdefer gpa.free(escaped);
        const entries = try gpa.alloc(Entry, owned.count());
        errdefer gpa.free(entries);
        const ignored = try gpa.alloc(Ignore, owned.count());
        errdefer gpa.free(ignored);
        @memset(ignored, .unknown);
        const self = try gpa.create(Catalog);
        errdefer gpa.destroy(self);
        var used: usize = 0;
        for (entries, 0..) |*entry, index| {
            if (index % check_interval == 0) try check(cancel);
            const path = owned.path(index);
            const length = escapedLength(path);
            const label = if (length == 0) path else escape(escaped[used..][0..length], path);
            used += length;
            entry.* = .{ .path = path, .label = label, .origin = @intCast(index) };
        }
        try check(cancel);
        std.mem.sortUnstable(Entry, entries, {}, byLabel);
        try check(cancel);
        self.* = .{ .paths = owned, .escaped = escaped, .entries = entries, .ignored = ignored };
        return self;
    }

    pub fn retain(self: *Catalog) *Catalog {
        self.references += 1;
        return self;
    }

    pub fn release(self: *Catalog, gpa: Allocator) void {
        self.references -= 1;
        if (self.references != 0) return;
        self.paths.deinit(gpa);
        gpa.free(self.escaped);
        gpa.free(self.entries);
        gpa.free(self.ignored);
        gpa.destroy(self);
    }

    /// Marks each entry ignored when a directory above it is in `ignored`,
    /// else unknown when it lies in one of `repositories` (directories ending
    /// in `/`), which Git's listing never looks into, else ignored when it is
    /// in `ignored` and visible otherwise. Only before the catalog is shared.
    pub fn classify(
        self: *Catalog,
        gpa: Allocator,
        ignored: *const discovery.Inventory,
        repositories: *const discovery.Inventory,
        cancel: ?*const discovery.Cancel,
    ) Error!void {
        const listed = try ordered(gpa, ignored);
        defer gpa.free(listed);
        const nested = try ordered(gpa, repositories);
        defer gpa.free(nested);
        var directories = false;
        for (listed) |path| {
            if (path[path.len - 1] == '/') directories = true;
        }
        try check(cancel);
        for (self.entries, self.ignored, 0..) |entry, *status, index| {
            if (index % check_interval == 0) try check(cancel);
            status.* = if (directories and beneathAny(listed, entry.path))
                .ignored
            else if (nested.len != 0 and beneathAny(nested, entry.path))
                .unknown
            else if (contains(listed, entry.path))
                .ignored
            else
                .visible;
        }
    }

    /// The entry labelled `label`, if any.
    pub fn find(self: *const Catalog, label: []const u8) ?usize {
        return std.sort.binarySearch(Entry, self.entries, label, struct {
            fn compare(wanted: []const u8, entry: Entry) std.math.Order {
                return std.mem.order(u8, wanted, entry.label);
            }
        }.compare);
    }
};

/// A query with smart case: any uppercase byte makes it case-sensitive.
pub const Query = struct {
    text: []const u8,
    exact: bool,

    pub fn init(text: []const u8) Query {
        for (text) |byte| if (std.ascii.isUpper(byte)) return .{ .text = text, .exact = true };
        return .{ .text = text, .exact = false };
    }

    /// Rank of `label`, or null when the query is not a subsequence of it.
    /// The alignment starts as late as possible and ends as early as it can
    /// from there, so hits favour the basename. `positions`, when given,
    /// receives the matched byte offsets and must hold `text.len`.
    pub fn score(self: Query, label: []const u8, positions: ?[]usize) ?i32 {
        var remaining = self.text.len;
        var start = label.len;
        while (remaining != 0 and start != 0) {
            start -= 1;
            if (self.fold(label[start]) == self.text[remaining - 1]) remaining -= 1;
        }
        if (remaining != 0) return null;
        const basename = if (std.mem.lastIndexOfScalar(u8, label, '/')) |slash| slash + 1 else 0;
        var total: i32 = 0;
        var previous: ?usize = null;
        var at = start;
        // A run inherits the bonus of the boundary it starts on, and the first
        // character's bonus counts twice, as in fzf.
        var run: i32 = 0;
        for (self.text, 0..) |wanted, index| {
            while (self.fold(label[at]) != wanted) at += 1;
            if (positions) |out| out[index] = at;
            var bonus = boundary(label, at);
            if (previous) |last| {
                if (at == last + 1) {
                    bonus = @max(bonus, run, bonus_consecutive);
                } else {
                    total -= @intCast(@min(at - last - 1 + penalty_gap_start, penalty_gap_max));
                    run = bonus;
                }
            } else {
                run = bonus;
                bonus *= 2;
            }
            total += bonus_match + bonus;
            if (at >= basename) total += bonus_basename;
            previous = at;
            at += 1;
        }
        return total;
    }

    fn fold(self: Query, byte: u8) u8 {
        return if (self.exact) byte else std.ascii.toLower(byte);
    }
};

/// Every entry the query matches, best first, ties in catalog order. An
/// empty query matches everything in catalog order. The caller frees.
pub fn filter(
    gpa: Allocator,
    catalog: *const Catalog,
    text: []const u8,
    cancel: ?*const discovery.Cancel,
) Error![]Match {
    const query: Query = .init(text);
    var matches: std.ArrayList(Match) = try .initCapacity(gpa, catalog.entries.len);
    errdefer matches.deinit(gpa);
    for (catalog.entries, 0..) |entry, index| {
        if (index % check_interval == 0) try check(cancel);
        const value = query.score(entry.label, null) orelse continue;
        matches.appendAssumeCapacity(.{ .index = @intCast(index), .score = value });
    }
    try check(cancel);
    if (text.len != 0) std.mem.sortUnstable(Match, matches.items, {}, better);
    return matches.toOwnedSlice(gpa);
}

const check_interval = 4096;

const bonus_match = 16;
const bonus_boundary = 10;
const bonus_separator = 8;
const bonus_camel = 7;
const bonus_basename = 4;
const bonus_consecutive = 4;
const penalty_gap_start = 3;
const penalty_gap_max = 16;

fn boundary(label: []const u8, at: usize) i32 {
    if (at == 0 or label[at - 1] == '/') return bonus_boundary;
    const before = label[at - 1];
    if (std.mem.indexOfScalar(u8, "_-. ", before) != null) return bonus_separator;
    if (std.ascii.isLower(before) and std.ascii.isUpper(label[at])) return bonus_camel;
    return 0;
}

fn better(_: void, a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.index < b.index;
}

fn byLabel(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.label, b.label);
}

/// The inventory's paths in byte order, borrowed from it. Free the slice.
fn ordered(gpa: Allocator, inventory: *const discovery.Inventory) Allocator.Error![][]const u8 {
    const paths = try gpa.alloc([]const u8, inventory.count());
    for (paths, 0..) |*path, index| path.* = inventory.path(index);
    std.mem.sortUnstable([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return paths;
}

fn contains(sorted: []const []const u8, path: []const u8) bool {
    return std.sort.binarySearch([]const u8, sorted, path, struct {
        fn compare(wanted: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, wanted, item);
        }
    }.compare) != null;
}

/// Whether a directory above `path`, spelled with its trailing `/`, is listed.
fn beneathAny(sorted: []const []const u8, path: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| : (start = slash + 1) {
        if (contains(sorted, path[0 .. slash + 1])) return true;
    }
    return false;
}

fn check(cancel: ?*const discovery.Cancel) Error!void {
    if (cancel) |flag| try flag.check();
}

fn plain(byte: u8) bool {
    return byte >= 0x20 and byte < 0x7f and byte != '\\';
}

/// Length of the escaped label, or zero when the path is its own label.
fn escapedLength(path: []const u8) usize {
    var length: usize = 0;
    var escaped = false;
    for (path) |byte| {
        if (plain(byte)) {
            length += 1;
        } else {
            escaped = true;
            length += switch (byte) {
                '\\', '\n', '\t' => 2,
                else => 4,
            };
        }
    }
    return if (escaped) length else 0;
}

/// `\\`, `\n` and `\t`, and `\xHH` for every other byte that is not
/// printable ASCII. Backslash is always escaped, so labels are unambiguous.
fn escape(out: []u8, path: []const u8) []const u8 {
    var length: usize = 0;
    for (path) |byte| {
        if (plain(byte)) {
            out[length] = byte;
            length += 1;
            continue;
        }
        const written: []const u8 = switch (byte) {
            '\\' => "\\\\",
            '\n' => "\\n",
            '\t' => "\\t",
            else => &[_]u8{ '\\', 'x', hex[byte >> 4], hex[byte & 0xf] },
        };
        @memcpy(out[length..][0..written.len], written);
        length += written.len;
    }
    return out[0..length];
}

const hex = "0123456789abcdef";

const testing = std.testing;

fn catalogOf(paths: []const []const u8) !*Catalog {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(testing.allocator);
    for (paths) |path| {
        try bytes.appendSlice(testing.allocator, path);
        try ends.append(testing.allocator, bytes.items.len);
        try bytes.append(testing.allocator, 0);
    }
    const inventory: discovery.Inventory = .{
        .bytes = try bytes.toOwnedSlice(testing.allocator),
        .ends = try ends.toOwnedSlice(testing.allocator),
    };
    return Catalog.create(testing.allocator, inventory, null);
}

fn expectRanking(catalog: *const Catalog, query: []const u8, expected: []const []const u8) !void {
    const matches = try filter(testing.allocator, catalog, query, null);
    defer testing.allocator.free(matches);
    try testing.expectEqual(expected.len, matches.len);
    for (expected, matches) |label, found| {
        try testing.expectEqualStrings(label, catalog.entries[found.index].label);
    }
}

test "labels escape unusual bytes unambiguously and stay searchable" {
    const raw = [_][]const u8{ "plain", "nl\nname", "back\\slash", "bad\xffbyte", "tab\tx" };
    const catalog = try catalogOf(&raw);
    defer catalog.release(testing.allocator);
    const labels = [_][]const u8{
        "back\\\\slash", "bad\\xffbyte", "nl\\nname", "plain", "tab\\tx",
    };
    try expectRanking(catalog, "", &labels);
    // A literal `\n` in a name and an escaped newline never share a label.
    const confusable = try catalogOf(&.{ "a\\n", "a\n" });
    defer confusable.release(testing.allocator);
    try expectRanking(confusable, "", &.{ "a\\\\n", "a\\n" });
    // The label is what is searched; the raw bytes are what is opened.
    try expectRanking(catalog, "\\xff", &.{"bad\\xffbyte"});
    const index = catalog.find("nl\\nname").?;
    try testing.expectEqualStrings("nl\nname", catalog.entries[index].path);
    try testing.expectEqual(@as(u32, 1), catalog.entries[index].origin);
    try testing.expectEqual(@as(?usize, null), catalog.find("nl\nname"));
}

test "matching is a smart-case subsequence of the whole path" {
    const catalog = try catalogOf(&.{ "src/Main.zig", "src/main.zig", "docs/readme", "MAIN" });
    defer catalog.release(testing.allocator);
    // Lowercase ignores case; any uppercase makes the query exact.
    try expectRanking(catalog, "main", &.{ "MAIN", "src/Main.zig", "src/main.zig" });
    try expectRanking(catalog, "Main", &.{"src/Main.zig"});
    // Directories count, and characters need not be adjacent.
    try expectRanking(catalog, "srmz", &.{ "src/Main.zig", "src/main.zig" });
    try expectRanking(catalog, "dcrm", &.{"docs/readme"});
    try expectRanking(catalog, "zigsrc", &.{});
}

test "ranking rewards basename hits, contiguous runs and word boundaries" {
    const catalog = try catalogOf(&.{
        "main/other.txt",
        "src/domain.zig",
        "src/main.zig",
        "lib/m_a_i_n.zig",
        "tests/mxaxixn.zig",
    });
    defer catalog.release(testing.allocator);
    try expectRanking(catalog, "main", &.{
        "src/main.zig",
        "main/other.txt",
        "lib/m_a_i_n.zig",
        "src/domain.zig",
        "tests/mxaxixn.zig",
    });
    // Duplicate basenames are told apart by their directories.
    const twins = try catalogOf(&.{ "b/lib.rs", "a/lib.rs", "c/lib.rs" });
    defer twins.release(testing.allocator);
    try expectRanking(twins, "lib", &.{ "a/lib.rs", "b/lib.rs", "c/lib.rs" });
    try expectRanking(twins, "blib", &.{"b/lib.rs"});
}

test "highlights mark the bytes the score used" {
    const query: Query = .init("main");
    var positions: [max_query]usize = undefined;
    _ = query.score("src/domain/main.zig", &positions).?;
    try testing.expectEqualSlices(usize, &.{ 11, 12, 13, 14 }, positions[0..4]);
    try testing.expectEqual(@as(?i32, null), query.score("mai", &positions));
}

test "filtering stops when cancelled" {
    const catalog = try catalogOf(&.{ "a", "b" });
    defer catalog.release(testing.allocator);
    var cancel: discovery.Cancel = try .init();
    defer cancel.deinit();
    cancel.request();
    try testing.expectError(error.Canceled, filter(testing.allocator, catalog, "a", &cancel));
}

test "classification marks listed paths, everything under listed directories, and nested repositories unknown" {
    const catalog = try catalogOf(&.{
        "a.log",    "keep",       "nested/x/y", "nested.txt", "dir/ok",  "bad\xff.log",
        "sub/junk", "sub/deep/a", "subway",     "nested/x/z", "sub.log",
    });
    defer catalog.release(testing.allocator);
    var ignored: discovery.Inventory = .{
        .bytes = try testing.allocator.dupe(u8, "nested/\x00bad\xff.log\x00a.log\x00"),
        .ends = try testing.allocator.dupe(usize, &.{ 7, 16, 22 }),
    };
    defer ignored.deinit(testing.allocator);
    // A submodule, and a repository inside an ignored directory.
    var repositories: discovery.Inventory = .{
        .bytes = try testing.allocator.dupe(u8, "sub/\x00nested/x/\x00"),
        .ends = try testing.allocator.dupe(usize, &.{ 4, 14 }),
    };
    defer repositories.deinit(testing.allocator);
    try catalog.classify(testing.allocator, &ignored, &repositories, null);
    const expected = [_]struct { []const u8, Ignore }{
        .{ "a.log", .ignored },      .{ "keep", .visible },       .{ "nested/x/y", .ignored },
        .{ "nested.txt", .visible }, .{ "dir/ok", .visible },     .{ "bad\\xff.log", .ignored },
        .{ "sub/junk", .unknown },   .{ "sub/deep/a", .unknown }, .{ "subway", .visible },
        .{ "nested/x/z", .ignored }, .{ "sub.log", .visible },
    };
    for (expected) |pair| {
        try testing.expectEqual(pair[1], catalog.ignored[catalog.find(pair[0]).?]);
    }
    var cancel: discovery.Cancel = try .init();
    defer cancel.deinit();
    cancel.request();
    try testing.expectError(error.Canceled, catalog.classify(testing.allocator, &ignored, &repositories, &cancel));
}

test "catalog creation frees everything on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            const bytes = try gpa.dupe(u8, "b\x00a\xff\x00");
            const ends = gpa.dupe(usize, &.{ 1, 4 }) catch |err| {
                gpa.free(bytes);
                return err;
            };
            const catalog = try Catalog.create(gpa, .{ .bytes = bytes, .ends = ends }, null);
            defer catalog.release(gpa);
            const matches = try filter(gpa, catalog, "a", null);
            gpa.free(matches);
        }
    }.run, .{});
}

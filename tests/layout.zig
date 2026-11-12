// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;

// Checks the layout rules in `.claude/architecture.md` over every file under
// the `src/` directory it is given: each file's imports above its first
// `test` (test-only imports go below it), and that only `text/buffer.zig`
// reads `Buffer.starts`, the line index. Prints each violation and fails.

/// Paths are relative to `src/`; one ending in `/` covers a folder. The first
/// rule matching a file applies, and a file no rule covers fails the check.
const rules = [_]struct { importer: []const u8, allowed: []const []const u8 }{
    .{ .importer = "text/", .allowed = &.{"text/"} },
    .{ .importer = "edit/", .allowed = &.{ "text/", "edit/", "terminal/input.zig" } },
    .{ .importer = "files/", .allowed = &.{ "text/", "files/" } },
    .{ .importer = "finder/", .allowed = &.{ "text/", "finder/" } },
    .{ .importer = "terminal/", .allowed = &.{"terminal/"} },
    .{ .importer = "views/", .allowed = &.{ "text/", "edit/", "files/", "finder/", "terminal/" } },
    .{ .importer = "command_line.zig", .allowed = &.{ "edit/keys.zig", "terminal/input.zig" } },
    .{
        .importer = "app.zig",
        .allowed = &.{ "text/", "edit/", "files/", "finder/", "terminal/", "views/", "command_line.zig" },
    },
    .{ .importer = "main.zig", .allowed = &.{ "app.zig", "finder/", "terminal/" } },
    .{ .importer = "nib.zig", .allowed = &.{ "text/", "finder/" } },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len != 2) return error.ExpectedSourceDirectory;
    var source = try std.Io.Dir.cwd().openDir(io, arguments[1], .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(arena);
    defer walker.deinit();
    var violations: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try arena.dupe(u8, entry.path);
        const text = try entry.dir.readFileAllocOptions(
            io,
            entry.basename,
            arena,
            .limited(16 * 1024 * 1024),
            .of(u8),
            0,
        );
        violations += try check(arena, path, text);
    }
    if (violations != 0) {
        std.debug.print("{d} layout violation(s); see .claude/architecture.md\n", .{violations});
        std.process.exit(1);
    }
}

/// Prints and counts the violations in one file.
fn check(arena: Allocator, path: []const u8, text: [:0]const u8) !usize {
    const allowed = for (rules) |rule| {
        if (covers(rule.importer, path)) break rule.allowed;
    } else {
        std.debug.print("src/{s}: no import rule covers this file\n", .{path});
        return 1;
    };
    const directory = std.fs.path.dirnamePosix(path) orelse ".";
    var violations: usize = 0;
    var tests = false;
    var tokens: std.zig.Tokenizer = .init(text);
    var previous: std.zig.Token.Tag = .invalid;
    while (true) {
        const token = tokens.next();
        switch (token.tag) {
            .eof => break,
            .keyword_test => tests = true,
            .builtin => if (!tests and std.mem.eql(u8, slice(text, token), "@import")) {
                const open = tokens.next();
                const name = tokens.next();
                if (open.tag != .l_paren or name.tag != .string_literal) continue;
                const imported = std.mem.trim(u8, slice(text, name), "\"");
                if (!std.mem.endsWith(u8, imported, ".zig")) continue;
                const target = try std.fs.path.resolveAllocPosix(arena, &.{ directory, imported });
                for (allowed) |prefix| {
                    if (covers(prefix, target)) break;
                } else {
                    std.debug.print("src/{s}: may not import {s}\n", .{ path, target });
                    violations += 1;
                }
            },
            .identifier => if (previous == .period and
                std.mem.eql(u8, slice(text, token), "starts") and
                !std.mem.eql(u8, path, "text/buffer.zig"))
            {
                std.debug.print("src/{s}: reads the line index; use Buffer's accessors\n", .{path});
                violations += 1;
            },
            else => {},
        }
        previous = token.tag;
    }
    return violations;
}

fn covers(rule: []const u8, path: []const u8) bool {
    return if (std.mem.endsWith(u8, rule, "/"))
        std.mem.startsWith(u8, path, rule)
    else
        std.mem.eql(u8, path, rule);
}

fn slice(text: []const u8, token: std.zig.Token) []const u8 {
    return text[token.loc.start..token.loc.end];
}

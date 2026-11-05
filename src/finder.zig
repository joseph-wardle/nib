// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const discovery = @import("discovery.zig");
/// Public for `tests/finder_bench.zig`, which drives the finder's jobs.
pub const jobs = @import("jobs.zig");
const match = @import("match.zig");
const session = @import("session.zig");
const Snapshot = @import("preview.zig").Snapshot;

pub const Category = enum {
    /// Ordinary candidates: Git's tracked and unignored files, else a walk.
    project,
    /// Every regular file under the root, hidden and ignored ones included.
    all,
    /// Every open document, whatever its ignore status or presence on disk.
    open,

    /// Tab order.
    pub fn next(self: Category) Category {
        return switch (self) {
            .project => .all,
            .all => .open,
            .open => .project,
        };
    }
};

/// An open document as the caller describes it.
pub const OpenFile = struct {
    id: session.Id,
    /// Absolute spelling, as `Source` records it. Borrowed for the call.
    path: []const u8,
    modified: bool,
    /// Activation order; larger is more recent.
    used: u64,
};

pub const Choice = union(enum) {
    /// Raw bytes relative to the root directory. Borrowed until the finder
    /// next changes.
    path: []const u8,
    document: session.Id,
};

/// How one result is shown. Dimming never hides a match or changes ranking.
pub const Row = struct {
    /// Borrowed until the finder next changes.
    label: []const u8,
    ignore: match.Ignore,
    /// Set only for open documents with unsaved edits.
    modified: bool,
};

/// What one category last discovered and how far classification has got.
pub const List = struct {
    catalog: ?*match.Catalog = null,
    /// A discovery job for this list is outstanding.
    discovering: bool = false,
    /// The last discovery failed; any catalog is from an earlier one.
    failure: ?jobs.Error = null,
    partial: bool = false,
    /// Git did not filter the listing.
    unfiltered: bool = false,
    /// Why the listing is unfiltered or partial. Owned; may be empty.
    reason: []u8 = &.{},
    /// Open only: per catalog entry origin.
    documents: []Document = &.{},
    /// Catalog entries before this index have been sent for classification.
    classified: usize = 0,
    /// Entries whose classification failed; their status stays unknown.
    unclassified: usize = 0,
    /// The last failed batch's error, and Git's message when Git refused it.
    ignore_failure: ?jobs.Error = null,
    /// Owned; may be empty.
    ignore_reason: []u8 = &.{},

    fn deinit(self: *List, gpa: Allocator) void {
        self.replace(gpa, null, &.{});
        gpa.free(self.reason);
    }

    /// Takes ownership of `catalog` and `documents`.
    fn replace(self: *List, gpa: Allocator, catalog: ?*match.Catalog, documents: []Document) void {
        if (self.catalog) |old| old.release(gpa);
        gpa.free(self.documents);
        gpa.free(self.ignore_reason);
        self.catalog = catalog;
        self.documents = documents;
        self.classified = 0;
        self.unclassified = 0;
        self.ignore_failure = null;
        self.ignore_reason = &.{};
    }
};

pub const Document = struct { id: session.Id, modified: bool, used: u64 };

/// What the preview pane shows for the selection.
pub const Preview = union(enum) {
    /// Nothing is selected.
    none,
    /// An open document: draw its current text, unsaved edits included,
    /// from the session. Nothing is read or copied.
    document: session.Id,
    /// The file is being read.
    loading,
    /// A bounded prefix of the file on disk. Borrowed until the finder next
    /// changes.
    file: Snapshot,
    /// The file could not be previewed; opening it may still work.
    unavailable: jobs.Error,
};

/// Paths per `git check-ignore` process.
pub const batch_size = 4096;

/// The finder's state, independent of the terminal. Discovery, classification,
/// filtering and previews run in `jobs` lanes; the finder submits a request
/// whenever what it shows changes and applies each completion the caller
/// hands back. A filter result always describes the current catalog and
/// query, and a preview the selected path, because every change to either
/// submits a newer request or cancels the lane.
pub const Finder = struct {
    root: ?discovery.Root = null,
    root_failure: ?jobs.Error = null,
    category: Category = .project,
    query: std.ArrayList(u8) = .empty,
    lists: std.EnumArray(Category, List) = .initFill(.{}),
    /// Results in `shown`, best first. Owned.
    matches: []match.Match = &.{},
    /// The catalog `matches` index into. Holds a reference.
    shown: ?*match.Catalog = null,
    selected: usize = 0,
    /// A filter job for the current catalog and query is outstanding.
    filtering: bool = false,
    filter_failure: ?jobs.Error = null,
    /// The next results select the best match rather than the same path.
    restart: bool = false,
    /// The label to select once results arrive after a category change.
    keep: std.ArrayList(u8) = .empty,
    /// The classification batch in flight.
    batch: ?Batch = null,
    /// The path whose file preview is shown or being read; empty when the
    /// selection needs none.
    previewed: std.ArrayList(u8) = .empty,
    /// Owned.
    snapshot: ?Snapshot = null,
    preview_failure: ?jobs.Error = null,
    /// A preview job for `previewed` is outstanding.
    reading: bool = false,
    /// On screen, from `focus` until `leave`. A hidden finder discovers
    /// nothing when the root arrives and previews nothing.
    visible: bool = false,

    /// Call after `Jobs.deinit`: requests borrow the root descriptor.
    pub fn deinit(self: *Finder, gpa: Allocator, io: Io) void {
        if (self.root) |*root| root.deinit(gpa, io);
        for (&self.lists.values) |*list| list.deinit(gpa);
        if (self.shown) |catalog| catalog.release(gpa);
        if (self.batch) |batch| batch.catalog.release(gpa);
        gpa.free(self.matches);
        self.query.deinit(gpa);
        self.keep.deinit(gpa);
        if (self.snapshot) |*snapshot| snapshot.deinit(gpa);
        self.previewed.deinit(gpa);
        self.* = undefined;
    }

    /// Resolves the root in the background; discovery starts when it
    /// arrives. `how` is borrowed until then.
    pub fn start(
        self: *Finder,
        gpa: Allocator,
        io: Io,
        background: *jobs.Jobs,
        how: discovery.Start,
    ) void {
        std.debug.assert(self.root == null and self.root_failure == null);
        background.submit(gpa, io, .discovery, .{ .root = how });
    }

    pub fn resolving(self: *const Finder) bool {
        return self.root == null and self.root_failure == null;
    }

    /// Focus enters `category`, from the editor, another category or a manual
    /// refresh. The category is discovered again and the selection's preview
    /// read again; the query is kept, and the selected path where it can be.
    /// `open` lists every open document, whichever category is focused.
    pub fn focus(
        self: *Finder,
        gpa: Allocator,
        io: Io,
        background: *jobs.Jobs,
        category: Category,
        open: []const OpenFile,
    ) Allocator.Error!void {
        self.visible = true;
        defer self.look(gpa, io, background, true);
        if (category != self.category) {
            if (self.selection()) |entry| {
                self.keep.clearRetainingCapacity();
                try self.keep.appendSlice(gpa, entry.label);
            }
            self.clear(gpa);
            self.category = category;
        }
        try self.listOpen(gpa, background, open);
        if (category != .open) {
            self.discover(gpa, io, background);
            try self.show(gpa, io, background);
        }
        try self.classifyNext(gpa, io, background);
    }

    /// Focus returns to the editor. Any preview read is abandoned; the query,
    /// category and results stay for the next `focus`.
    pub fn leave(self: *Finder, gpa: Allocator, io: Io, background: *jobs.Jobs) void {
        self.visible = false;
        self.look(gpa, io, background, false);
    }

    /// `path`, an absolute document path, as the finder lists it: relative
    /// when beneath the root. Borrows `path`.
    pub fn display(self: *const Finder, path: []const u8) []const u8 {
        const root = self.root orelse return path;
        return beneath(root.path, path) orelse path;
    }

    /// Replaces the query. The next results select the best match.
    pub fn search(
        self: *Finder,
        gpa: Allocator,
        io: Io,
        background: *jobs.Jobs,
        text: []const u8,
    ) (Allocator.Error || error{QueryTooLong})!void {
        if (text.len > match.max_query) return error.QueryTooLong;
        defer self.look(gpa, io, background, false);
        try self.query.ensureTotalCapacity(gpa, text.len);
        self.query.clearRetainingCapacity();
        self.query.appendSliceAssumeCapacity(text);
        self.restart = true;
        try self.show(gpa, io, background);
    }

    /// Moves the selection, stopping at either end, and previews the new one.
    /// Discovery is never restarted.
    pub fn move(self: *Finder, gpa: Allocator, io: Io, background: *jobs.Jobs, delta: isize) void {
        if (self.matches.len == 0) return;
        const distance = @abs(delta);
        self.selected = if (delta < 0) self.selected -| distance else @min(
            self.selected +| distance,
            self.matches.len - 1,
        );
        self.restart = false;
        self.look(gpa, io, background, false);
    }

    /// The page of `rows` results that holds the selection. Every match is
    /// reachable; nothing is truncated.
    pub fn page(self: *const Finder, rows: usize) []const match.Match {
        if (self.matches.len == 0 or rows == 0) return &.{};
        const first = self.selected - self.selected % rows;
        return self.matches[first..@min(first + rows, self.matches.len)];
    }

    pub fn row(self: *const Finder, result: match.Match) Row {
        const catalog = self.shown.?;
        const entry = catalog.entries[result.index];
        const modified = if (self.opened(entry.label)) |document| document.modified else false;
        const ignore = catalog.ignored[result.index];
        return .{ .label = entry.label, .ignore = ignore, .modified = modified };
    }

    /// Byte offsets of the label that match the current query, for
    /// highlighting. Empty when the shown results predate the query.
    pub fn highlight(
        self: *const Finder,
        result: match.Match,
        out: *[match.max_query]usize,
    ) []usize {
        const label = self.shown.?.entries[result.index].label;
        const query: match.Query = .init(self.query.items);
        _ = query.score(label, out) orelse return &.{};
        return out[0..query.text.len];
    }

    /// What Enter would open.
    pub fn choice(self: *const Finder) ?Choice {
        const entry = self.selection() orelse return null;
        if (self.category != .open) return .{ .path = entry.path };
        return .{ .document = self.opened(entry.label).?.id };
    }

    /// The selection's preview. Enter still opens through `choice`, never
    /// from a preview.
    pub fn preview(self: *const Finder) Preview {
        if (!self.visible) return .none;
        const entry = self.selection() orelse return .none;
        if (self.opened(entry.label)) |document| return .{ .document = document.id };
        if (self.preview_failure) |err| return .{ .unavailable = err };
        if (self.reading) return .loading;
        std.debug.assert(std.mem.eql(u8, entry.path, self.previewed.items));
        return .{ .file = self.snapshot.? };
    }

    /// Applies a completion from `jobs`, taking ownership of it.
    pub fn receive(
        self: *Finder,
        gpa: Allocator,
        io: Io,
        background: *jobs.Jobs,
        completion: jobs.Completion,
    ) Allocator.Error!void {
        var request = completion.request;
        defer request.deinit(gpa);
        defer self.look(gpa, io, background, false);
        switch (completion.outcome) {
            .root => |result| {
                self.root = result catch |err| {
                    self.root_failure = err;
                    return;
                };
                if (self.visible and self.category != .open) self.discover(gpa, io, background);
                try self.relabel(gpa, background);
            },
            .listing => |result| {
                const category: Category = if (request == .project) .project else .all;
                const list = self.lists.getPtr(category);
                list.discovering = false;
                const found = result catch |err| {
                    list.failure = err;
                    return;
                };
                list.failure = null;
                list.partial = found.partial;
                list.unfiltered = found.unfiltered;
                gpa.free(list.reason);
                list.reason = found.reason;
                list.replace(gpa, found.catalog, &.{});
                if (category != self.category) return;
                try self.show(gpa, io, background);
                try self.classifyNext(gpa, io, background);
            },
            .classified => |result| {
                self.classify(gpa, request.classify.batch.count(), result);
                try self.classifyNext(gpa, io, background);
            },
            .matches => |result| {
                const job = request.filter;
                std.debug.assert(job.catalog == self.lists.get(self.category).catalog);
                std.debug.assert(std.mem.eql(u8, job.query, self.query.items));
                self.filtering = false;
                const matches = result catch |err| {
                    self.filter_failure = err;
                    return;
                };
                self.filter_failure = null;
                self.present(gpa, job.catalog.retain(), matches);
            },
            .preview => |result| {
                std.debug.assert(std.mem.eql(u8, request.preview.path, self.previewed.items));
                self.reading = false;
                self.snapshot = result catch |err| {
                    self.preview_failure = err;
                    return;
                };
            },
        }
    }

    /// The open document listed under `label`, from any category.
    fn opened(self: *const Finder, label: []const u8) ?Document {
        const list = self.lists.getPtrConst(.open);
        const catalog = list.catalog orelse return null;
        const index = catalog.find(label) orelse return null;
        return list.documents[catalog.entries[index].origin];
    }

    /// Keeps the preview on the visible selection. An open document needs no
    /// read; a file is read in the background unless it is already shown or
    /// being read, or `reread` asks for it again. Running out of memory shows
    /// as an unavailable preview and is retried by the next look.
    fn look(self: *Finder, gpa: Allocator, io: Io, background: *jobs.Jobs, reread: bool) void {
        const wanted: ?[]const u8 = wanted: {
            if (!self.visible) break :wanted null;
            const entry = self.selection() orelse break :wanted null;
            if (self.opened(entry.label) != null) break :wanted null;
            break :wanted entry.path;
        };
        if (wanted) |path| {
            if (!reread and std.mem.eql(u8, path, self.previewed.items)) return;
        }
        background.cancel(gpa, .preview);
        if (self.snapshot) |*snapshot| snapshot.deinit(gpa);
        self.snapshot = null;
        self.previewed.clearRetainingCapacity();
        self.preview_failure = null;
        self.reading = false;
        const path = wanted orelse return;
        self.read(gpa, io, background, path) catch |err| {
            self.previewed.clearRetainingCapacity();
            self.preview_failure = err;
        };
    }

    fn read(
        self: *Finder,
        gpa: Allocator,
        io: Io,
        background: *jobs.Jobs,
        path: []const u8,
    ) Allocator.Error!void {
        // Only discovered listings select paths, and they need the root.
        const root = self.root.?;
        try self.previewed.appendSlice(gpa, path);
        const owned = try gpa.dupeSentinel(u8, path, 0);
        background.submit(gpa, io, .preview, .{ .preview = .{ .root = root.dir, .path = owned } });
        self.reading = true;
    }

    /// Lists the open documents again, relative to a root that has just
    /// arrived, so they are recognised in every category.
    fn relabel(self: *Finder, gpa: Allocator, background: *jobs.Jobs) Allocator.Error!void {
        const list = self.lists.getPtrConst(.open);
        const catalog = list.catalog orelse return;
        const open = try gpa.alloc(OpenFile, catalog.entries.len);
        defer gpa.free(open);
        for (catalog.entries, open) |entry, *file| {
            const listed = list.documents[entry.origin];
            file.* = .{
                .id = listed.id,
                .path = entry.path,
                .modified = listed.modified,
                .used = listed.used,
            };
        }
        // `open` borrows the old catalog, which outlives the call.
        const kept = catalog.retain();
        defer kept.release(gpa);
        try self.listOpen(gpa, background, open);
    }

    fn selection(self: *const Finder) ?match.Entry {
        const catalog = self.shown orelse return null;
        if (self.matches.len == 0) return null;
        return catalog.entries[self.matches[self.selected].index];
    }

    fn clear(self: *Finder, gpa: Allocator) void {
        if (self.shown) |catalog| catalog.release(gpa);
        gpa.free(self.matches);
        self.shown = null;
        self.matches = &.{};
        self.selected = 0;
    }

    /// Takes ownership of a reference to `catalog` and of `matches`. Selects
    /// the same path as before where it is still listed.
    fn present(
        self: *Finder,
        gpa: Allocator,
        catalog: *match.Catalog,
        matches: []match.Match,
    ) void {
        var wanted: ?[]const u8 = null;
        if (!self.restart) {
            if (self.selection()) |entry| wanted = entry.label;
            if (wanted == null and self.keep.items.len != 0) wanted = self.keep.items;
        }
        var selected: usize = 0;
        if (wanted) |label| if (catalog.find(label)) |index| {
            for (matches, 0..) |result, position| if (result.index == index) {
                selected = position;
                break;
            };
        };
        self.clear(gpa);
        self.shown = catalog;
        self.matches = matches;
        self.selected = selected;
        self.restart = false;
        self.keep.clearRetainingCapacity();
    }

    /// Filters the current category's catalog: in a job for a search of a
    /// discovered listing, inline otherwise. Either way any older filter is
    /// abandoned first.
    fn show(self: *Finder, gpa: Allocator, io: Io, background: *jobs.Jobs) Allocator.Error!void {
        background.cancel(gpa, .filter);
        self.filtering = false;
        const catalog = self.lists.get(self.category).catalog orelse return;
        if (self.category != .open and self.query.items.len != 0) {
            const query = try gpa.dupe(u8, self.query.items);
            const request: jobs.Request = .{
                .filter = .{ .catalog = catalog.retain(), .query = query },
            };
            background.submit(gpa, io, .filter, request);
            self.filtering = true;
            return;
        }
        const matches = try self.filterInline(gpa, catalog, self.lists.get(.open).documents);
        self.present(gpa, catalog.retain(), matches);
    }

    /// Open lists are small, and every empty query keeps catalog order, so
    /// these never need a job. With an empty query Open puts the most
    /// recently used first.
    fn filterInline(
        self: *const Finder,
        gpa: Allocator,
        catalog: *const match.Catalog,
        documents: []const Document,
    ) Allocator.Error![]match.Match {
        const filtered = match.filter(gpa, catalog, self.query.items, null);
        const matches = filtered catch |err| switch (err) {
            error.Canceled => unreachable,
            error.OutOfMemory => |e| return e,
        };
        if (self.category == .open and self.query.items.len == 0) {
            const Recency = struct {
                catalog: *const match.Catalog,
                documents: []const Document,

                fn later(context: @This(), a: match.Match, b: match.Match) bool {
                    const first = context.catalog.entries[a.index].origin;
                    const second = context.catalog.entries[b.index].origin;
                    return context.documents[first].used > context.documents[second].used;
                }
            };
            const context: Recency = .{ .catalog = catalog, .documents = documents };
            std.mem.sort(match.Match, matches, context, Recency.later);
        }
        return matches;
    }

    fn discover(self: *Finder, gpa: Allocator, io: Io, background: *jobs.Jobs) void {
        const root = self.root orelse return;
        const request: jobs.Request = switch (self.category) {
            .project => .{ .project = .{ .root = root.dir, .git = root.git } },
            .all => .{ .all = root.dir },
            .open => unreachable,
        };
        // The categories share a lane, so this supersedes the other one.
        background.submit(gpa, io, .discovery, request);
        self.lists.getPtr(.project).discovering = self.category == .project;
        self.lists.getPtr(.all).discovering = self.category == .all;
    }

    /// Lists open documents: relative to the root when they lie beneath it,
    /// otherwise by absolute path, which is never classified. Shown only when
    /// Open is focused; other categories look documents up by label.
    fn listOpen(
        self: *Finder,
        gpa: Allocator,
        background: *jobs.Jobs,
        open: []const OpenFile,
    ) Allocator.Error!void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        const ends = try gpa.alloc(usize, open.len);
        var ends_owned = true;
        defer if (ends_owned) gpa.free(ends);
        const documents = try gpa.alloc(Document, open.len);
        errdefer gpa.free(documents);
        for (open, ends, documents) |file, *end, *document| {
            const relative = if (self.root) |root| beneath(root.path, file.path) else null;
            const path = relative orelse file.path;
            try bytes.appendSlice(gpa, path);
            end.* = bytes.items.len;
            try bytes.append(gpa, 0);
            document.* = .{ .id = file.id, .modified = file.modified, .used = file.used };
        }
        const owned = try bytes.toOwnedSlice(gpa);
        ends_owned = false;
        const created = match.Catalog.create(gpa, .{ .bytes = owned, .ends = ends }, null);
        const catalog = created catch |err| {
            return switch (err) {
                error.Canceled => unreachable,
                error.OutOfMemory => |e| e,
            };
        };
        errdefer catalog.release(gpa);
        // Commit only once nothing else can fail, so the shown rows always
        // belong to the listed documents.
        const list = self.lists.getPtr(.open);
        if (self.category != .open) return list.replace(gpa, catalog, documents);
        const matches = try self.filterInline(gpa, catalog, documents);
        background.cancel(gpa, .filter);
        self.filtering = false;
        list.replace(gpa, catalog, documents);
        self.present(gpa, catalog.retain(), matches);
    }

    /// Sends the next batch of the current category's unclassified paths to
    /// `git check-ignore`. One batch is in flight at a time.
    fn classifyNext(
        self: *Finder,
        gpa: Allocator,
        io: Io,
        background: *jobs.Jobs,
    ) Allocator.Error!void {
        if (self.batch != null or self.category == .project) return;
        const root = self.root orelse return;
        if (!root.git) return;
        const list = self.lists.getPtr(self.category);
        const catalog = list.catalog orelse return;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        var ends: std.ArrayList(usize) = .empty;
        defer ends.deinit(gpa);
        var end = list.classified;
        while (end < catalog.entries.len and ends.items.len < batch_size) : (end += 1) {
            const path = catalog.entries[end].path;
            if (path[0] == '/') continue;
            try bytes.ensureUnusedCapacity(gpa, path.len + 1);
            try ends.ensureUnusedCapacity(gpa, 1);
            bytes.appendSliceAssumeCapacity(path);
            ends.appendAssumeCapacity(bytes.items.len);
            bytes.appendAssumeCapacity(0);
        }
        if (ends.items.len == 0) {
            list.classified = end;
            return;
        }
        const ends_owned = try ends.toOwnedSlice(gpa);
        errdefer gpa.free(ends_owned);
        const paths: discovery.Inventory = .{
            .bytes = try bytes.toOwnedSlice(gpa),
            .ends = ends_owned,
        };
        const request: jobs.Request = .{ .classify = .{ .root = root.dir, .batch = paths } };
        background.submit(gpa, io, .classification, request);
        self.batch = .{
            .category = self.category,
            .catalog = catalog.retain(),
            .start = list.classified,
            .end = end,
        };
        list.classified = end;
    }

    /// Records a batch's verdict on the catalog it was taken from, which may
    /// since have been replaced. Takes ownership of `result`.
    fn classify(
        self: *Finder,
        gpa: Allocator,
        count: usize,
        result: jobs.Error!discovery.Classified,
    ) void {
        const batch = self.batch.?;
        self.batch = null;
        defer batch.catalog.release(gpa);
        const list = self.lists.getPtr(batch.category);
        const current = list.catalog == batch.catalog;
        var reason: []u8 = &.{};
        const failure: jobs.Error = failed: {
            const classified = result catch |err| break :failed err;
            switch (classified) {
                .ignored => |ignored| {
                    defer gpa.free(ignored);
                    var next: usize = 0;
                    const range = batch.catalog.entries[batch.start..batch.end];
                    for (range, batch.start..) |entry, index| {
                        if (entry.path[0] == '/') continue;
                        batch.catalog.ignored[index] = if (ignored[next]) .ignored else .visible;
                        next += 1;
                    }
                    return;
                },
                .failed => |message| {
                    reason = message;
                    break :failed error.HelperFailed;
                },
            }
        };
        if (!current) return gpa.free(reason);
        list.unclassified += count;
        list.ignore_failure = failure;
        gpa.free(list.ignore_reason);
        list.ignore_reason = reason;
    }
};

const Batch = struct {
    category: Category,
    /// Holds a reference.
    catalog: *match.Catalog,
    start: usize,
    end: usize,
};

/// `path` relative to `root`, when it lies beneath it without `.` or `..`
/// components that could lead elsewhere.
fn beneath(root: []const u8, path: []const u8) ?[]const u8 {
    const base = std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, path, base) or path.len <= base.len + 1) return null;
    if (path[base.len] != '/') return null;
    const relative = path[base.len + 1 ..];
    var components = std.mem.splitScalar(u8, relative, '/');
    while (components.next()) |component| {
        const special = std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..");
        if (component.len == 0 or special) return null;
    }
    return relative;
}

const testing = std.testing;
const Scratch = discovery.Scratch;

/// A worktree with tracked, untracked, hidden, ignored and tracked-but-matching
/// files, at `repo` in `scratch`.
fn repository(scratch: *const Scratch) !void {
    try scratch.git(&.{ "init", "-q", "repo" });
    const ignore_file = "*.log\nbuild/\n";
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = ignore_file });
    for ([_][]const u8{
        "repo/src/main.zig", "repo/src/util.zig", "repo/README",      "repo/.hidden",
        "repo/debug.log",    "repo/build/out.o",  "repo/tracked.log",
    }) |relative| try scratch.put(relative);
    try scratch.git(&.{ "-C", "repo", "add", ".gitignore", "src", "README" });
    // Tracked files are never ignored, even when a pattern matches them.
    try scratch.git(&.{ "-C", "repo", "add", "-f", "tracked.log" });
}

/// Applies completions until every lane is idle.
fn settle(finder: *Finder, background: *jobs.Jobs) !void {
    while (true) {
        while (background.collect(testing.allocator, testing.io)) |completion| {
            try finder.receive(testing.allocator, testing.io, background, completion);
        }
        const busy = background.busy(.discovery) or background.busy(.classification) or
            background.busy(.filter) or background.busy(.preview);
        if (!busy) return;
        var fds = [_]std.os.linux.pollfd{
            .{ .fd = background.wake_fd, .events = std.os.linux.POLL.IN, .revents = 0 },
        };
        if (std.os.linux.poll(&fds, 1, 10_000) == 0) return error.Timeout;
    }
}

fn id(value: u64) session.Id {
    return @fromBackingInt(@intCast(value));
}

fn openFile(number: u64, path: []const u8, modified: bool, used: u64) OpenFile {
    return .{ .id = id(number), .path = path, .modified = modified, .used = used };
}

fn expectRows(finder: *const Finder, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, finder.matches.len);
    for (expected, finder.matches) |label, result| {
        try testing.expectEqualStrings(label, finder.row(result).label);
    }
}

fn rowOf(finder: *const Finder, label: []const u8) !Row {
    for (finder.matches) |result| {
        const shown = finder.row(result);
        if (std.mem.eql(u8, shown.label, label)) return shown;
    }
    return error.NotListed;
}

fn selectedLabel(finder: *const Finder) []const u8 {
    return finder.row(finder.matches[finder.selected]).label;
}

/// A finder rooted at `repo`, settled on the project listing.
fn begin(finder: *Finder, background: *jobs.Jobs, scratch: *const Scratch, buffer: []u8) !void {
    const how: discovery.Start = .{ .directory = scratch.join(buffer, "repo") };
    finder.start(testing.allocator, testing.io, background, how);
    try testing.expect(finder.resolving());
    // Focus before the root arrives; discovery follows it.
    try finder.focus(testing.allocator, testing.io, background, .project, &.{});
    try settle(finder, background);
}

test "the project lists Git's files, searches them and chooses a raw path" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    try begin(&finder, &background, &scratch, &buffer);
    try testing.expect(!finder.resolving() and finder.root.?.git);
    const project = finder.lists.getPtrConst(.project);
    try testing.expect(!project.discovering and !project.unfiltered and !project.partial);
    try expectRows(&finder, &.{
        ".gitignore", ".hidden", "README", "src/main.zig", "src/util.zig", "tracked.log",
    });
    // Project candidates are never classified, so nothing is dimmed.
    for (finder.matches) |result| {
        try testing.expectEqual(match.Ignore.unknown, finder.row(result).ignore);
    }
    try finder.search(testing.allocator, testing.io, &background, "main");
    try testing.expect(finder.filtering);
    try settle(&finder, &background);
    try expectRows(&finder, &.{"src/main.zig"});
    try testing.expectEqualStrings("src/main.zig", finder.choice().?.path);
    // Clearing the query while its filter runs abandons that filter.
    try finder.search(testing.allocator, testing.io, &background, "util");
    try finder.search(testing.allocator, testing.io, &background, "");
    try testing.expect(!finder.filtering);
    try testing.expectEqual(@as(usize, 6), finder.matches.len);
    try settle(&finder, &background);
    try testing.expectEqual(@as(usize, 6), finder.matches.len);
    try finder.search(testing.allocator, testing.io, &background, "main");
    try settle(&finder, &background);
    var positions: [match.max_query]usize = undefined;
    const highlighted = finder.highlight(finder.matches[0], &positions);
    try testing.expectEqualSlices(usize, &.{ 4, 5, 6, 7 }, highlighted);
    try finder.search(testing.allocator, testing.io, &background, "MAIN");
    try settle(&finder, &background);
    try expectRows(&finder, &.{});
    try testing.expectEqual(@as(?Choice, null), finder.choice());
    const long: [match.max_query + 1]u8 = @splat('a');
    const refused = finder.search(testing.allocator, testing.io, &background, &long);
    try testing.expectError(error.QueryTooLong, refused);
}

test "All adds hidden and ignored files and dims only those Git ignores" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    try begin(&finder, &background, &scratch, &buffer);
    try finder.focus(testing.allocator, testing.io, &background, .all, &.{});
    try testing.expect(finder.lists.getPtrConst(.all).discovering);
    try settle(&finder, &background);
    try expectRows(&finder, &.{
        ".gitignore",   ".hidden",      "README",      "build/out.o", "debug.log",
        "src/main.zig", "src/util.zig", "tracked.log",
    });
    try testing.expectEqual(match.Ignore.ignored, (try rowOf(&finder, "debug.log")).ignore);
    try testing.expectEqual(match.Ignore.ignored, (try rowOf(&finder, "build/out.o")).ignore);
    try testing.expectEqual(match.Ignore.visible, (try rowOf(&finder, "tracked.log")).ignore);
    try testing.expectEqual(match.Ignore.visible, (try rowOf(&finder, ".hidden")).ignore);
    const all = finder.lists.getPtrConst(.all);
    try testing.expectEqual(@as(usize, 8), all.classified);
    try testing.expectEqual(@as(usize, 0), all.unclassified);
    // Dimming never hides a match or changes its rank.
    try finder.search(testing.allocator, testing.io, &background, "log");
    try settle(&finder, &background);
    try expectRows(&finder, &.{ "debug.log", "tracked.log" });
}

test "category changes and refreshes keep the query and the selected path where they can" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    try begin(&finder, &background, &scratch, &buffer);
    try finder.search(testing.allocator, testing.io, &background, "zig");
    try settle(&finder, &background);
    try expectRows(&finder, &.{ "src/main.zig", "src/util.zig" });
    finder.move(testing.allocator, testing.io, &background, 1);
    try finder.focus(testing.allocator, testing.io, &background, .all, &.{});
    // Another category's results are never shown under this one.
    try expectRows(&finder, &.{});
    try settle(&finder, &background);
    try testing.expectEqualStrings("zig", finder.query.items);
    try testing.expectEqualStrings("src/util.zig", selectedLabel(&finder));
    // Files created since appear on refresh, and the selection stays put.
    try scratch.put("repo/src/new.zig");
    try finder.focus(testing.allocator, testing.io, &background, .all, &.{});
    try settle(&finder, &background);
    try expectRows(&finder, &.{ "src/main.zig", "src/new.zig", "src/util.zig" });
    try testing.expectEqualStrings("src/util.zig", selectedLabel(&finder));
    // A selection that disappears falls back to the best match.
    try scratch.dir.deleteFile(testing.io, "repo/src/util.zig");
    try finder.focus(testing.allocator, testing.io, &background, .all, &.{});
    try settle(&finder, &background);
    try expectRows(&finder, &.{ "src/main.zig", "src/new.zig" });
    try testing.expectEqual(@as(usize, 0), finder.selected);
    // A new query selects its best match.
    finder.move(testing.allocator, testing.io, &background, 1);
    try finder.search(testing.allocator, testing.io, &background, "zi");
    try settle(&finder, &background);
    try testing.expectEqual(@as(usize, 0), finder.selected);
}

test "Open lists every open document, most recent first, with markers and ignore status" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    try scratch.link("src", "repo/link");
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    try begin(&finder, &background, &scratch, &buffer);
    var paths: [3][256]u8 = undefined;
    const open = [_]OpenFile{
        openFile(1, scratch.join(&paths[0], "repo/src/main.zig"), true, 3),
        openFile(2, scratch.join(&paths[1], "repo/debug.log"), false, 5),
        openFile(3, "/elsewhere/x.txt", false, 1),
        openFile(4, scratch.join(&paths[2], "repo/src/../README"), false, 2),
    };
    try finder.focus(testing.allocator, testing.io, &background, .open, &open);
    // Open needs no discovery, so its rows are there at once.
    try expectRows(&finder, &.{ "debug.log", "src/main.zig", open[3].path, "/elsewhere/x.txt" });
    try testing.expectEqual(id(2), finder.choice().?.document);
    try settle(&finder, &background);
    try testing.expectEqual(match.Ignore.ignored, (try rowOf(&finder, "debug.log")).ignore);
    try testing.expectEqual(match.Ignore.visible, (try rowOf(&finder, "src/main.zig")).ignore);
    // Paths outside the root, or that might leave it, are never classified.
    try testing.expectEqual(match.Ignore.unknown, (try rowOf(&finder, "/elsewhere/x.txt")).ignore);
    try testing.expectEqual(match.Ignore.unknown, (try rowOf(&finder, open[3].path)).ignore);
    try testing.expect((try rowOf(&finder, "src/main.zig")).modified);
    try testing.expect(!(try rowOf(&finder, "debug.log")).modified);
    // Searching Open needs no job. The scratch path has no `t` or `x` after
    // any `.`, so only one document matches whatever its random name.
    try finder.search(testing.allocator, testing.io, &background, ".txt");
    try testing.expect(!finder.filtering);
    try expectRows(&finder, &.{"/elsewhere/x.txt"});
    try testing.expectEqual(id(3), finder.choice().?.document);
    // A batch Git refuses stays unknown and says why.
    var linked: [256]u8 = undefined;
    const refused = [_]OpenFile{
        openFile(5, scratch.join(&linked, "repo/link/main.zig"), false, 6),
    };
    try finder.search(testing.allocator, testing.io, &background, "");
    try finder.focus(testing.allocator, testing.io, &background, .open, &refused);
    try settle(&finder, &background);
    try testing.expectEqual(match.Ignore.unknown, (try rowOf(&finder, "link/main.zig")).ignore);
    const list = finder.lists.getPtrConst(.open);
    try testing.expectEqual(@as(usize, 1), list.unclassified);
    try testing.expectEqual(@as(?jobs.Error, error.HelperFailed), list.ignore_failure);
    try testing.expect(std.mem.indexOf(u8, list.ignore_reason, "beyond a symbolic link") != null);
}

test "without Git, listings say they are unfiltered and nothing is classified" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.put("plain/a.txt");
    try scratch.put("plain/.hidden");
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    const plain: discovery.Start = .{ .directory = scratch.join(&buffer, "plain") };
    finder.start(testing.allocator, testing.io, &background, plain);
    try finder.focus(testing.allocator, testing.io, &background, .project, &.{});
    try settle(&finder, &background);
    try testing.expect(!finder.root.?.git and finder.root.?.reason.len != 0);
    const project = finder.lists.getPtrConst(.project);
    try testing.expect(project.unfiltered);
    try testing.expectEqualStrings("Not a Git worktree; listing unfiltered", project.reason);
    try finder.focus(testing.allocator, testing.io, &background, .all, &.{});
    try settle(&finder, &background);
    try expectRows(&finder, &.{ ".hidden", "a.txt" });
    try testing.expectEqual(match.Ignore.unknown, (try rowOf(&finder, ".hidden")).ignore);
    try testing.expectEqual(@as(usize, 0), finder.lists.getPtrConst(.all).classified);
}

test "a missing root is reported and nothing is discovered" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    const missing: discovery.Start = .{ .directory = scratch.join(&buffer, "missing") };
    finder.start(testing.allocator, testing.io, &background, missing);
    try finder.focus(testing.allocator, testing.io, &background, .project, &.{});
    try settle(&finder, &background);
    try testing.expect(!finder.resolving());
    try testing.expectEqual(@as(?jobs.Error, error.FileNotFound), finder.root_failure);
    try expectRows(&finder, &.{});
    try testing.expect(!finder.lists.getPtrConst(.project).discovering);
}

/// Open documents at `/p/fNN`, used in order, so the newest is last.
fn openFiles(storage: *[25][8]u8, files: *[25]OpenFile) void {
    for (storage, files, 0..) |*path, *file, index| {
        const spelled = std.fmt.bufPrint(path, "/p/f{d:0>2}", .{index}) catch unreachable;
        file.* = openFile(index, spelled, false, index);
    }
}

test "results are paginated, never truncated, and the page follows the selection" {
    var storage: [25][8]u8 = undefined;
    var files: [25]OpenFile = undefined;
    openFiles(&storage, &files);
    var finder: Finder = .{ .category = .open };
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    try finder.focus(testing.allocator, testing.io, &background, .open, &files);
    try testing.expectEqual(@as(usize, 25), finder.matches.len);
    try testing.expectEqualStrings("/p/f24", selectedLabel(&finder));
    try testing.expectEqual(@as(usize, 10), finder.page(10).len);
    finder.move(testing.allocator, testing.io, &background, 12);
    try testing.expectEqualStrings("/p/f12", selectedLabel(&finder));
    try testing.expectEqualStrings("/p/f14", finder.row(finder.page(10)[0]).label);
    finder.move(testing.allocator, testing.io, &background, 100);
    try testing.expectEqual(@as(usize, 5), finder.page(10).len);
    try testing.expectEqualStrings("/p/f00", selectedLabel(&finder));
    finder.move(testing.allocator, testing.io, &background, -100);
    try testing.expectEqual(@as(usize, 0), finder.selected);
    try testing.expectEqual(@as(usize, 0), finder.page(0).len);
    // Refreshing keeps the selected document even though its rank moved.
    finder.move(testing.allocator, testing.io, &background, 3);
    files[21].used = 30;
    try finder.focus(testing.allocator, testing.io, &background, .open, &files);
    try testing.expectEqualStrings("/p/f21", selectedLabel(&finder));
    try testing.expectEqual(@as(usize, 0), finder.selected);
}

test "allocation failure while listing, searching or refreshing Open leaves the finder whole" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var storage: [25][8]u8 = undefined;
            var files: [25]OpenFile = undefined;
            openFiles(&storage, &files);
            var finder: Finder = .{};
            defer finder.deinit(gpa, testing.io);
            var background: jobs.Jobs = try .init();
            defer background.deinit(gpa, testing.io);
            try finder.focus(gpa, testing.io, &background, .open, &files);
            try finder.search(gpa, testing.io, &background, "f1");
            try testing.expectEqual(@as(usize, 12), finder.matches.len);
            finder.move(testing.allocator, testing.io, &background, 4);
            try finder.focus(gpa, testing.io, &background, .open, files[10..]);
            try testing.expectEqualStrings("/p/f14", selectedLabel(&finder));
        }
    }.run, .{});
}

/// The previewed file's bytes, once read.
fn previewText(finder: *const Finder) ![]const u8 {
    return switch (finder.preview()) {
        .file => |snapshot| snapshot.bytes,
        else => error.NotPreviewed,
    };
}

test "the selection is previewed in the background, follows moves and rereads on refresh" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "repo/README", .data = "first" });
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "repo/src/util.zig", .data = "util" });
    try scratch.put("repo/swap");
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    try begin(&finder, &background, &scratch, &buffer);
    try testing.expectEqualStrings(".gitignore", selectedLabel(&finder));
    try testing.expectEqualStrings("*.log\nbuild/\n", try previewText(&finder));
    finder.move(testing.allocator, testing.io, &background, 2);
    try testing.expect(finder.preview() == .loading);
    // Moving never restarts discovery.
    try testing.expect(!background.busy(.discovery));
    try settle(&finder, &background);
    try testing.expectEqualStrings("first", try previewText(&finder));
    // Quick moves supersede each other; only the last selection is shown.
    finder.move(testing.allocator, testing.io, &background, 1);
    finder.move(testing.allocator, testing.io, &background, 1);
    try settle(&finder, &background);
    try testing.expectEqualStrings("src/util.zig", selectedLabel(&finder));
    try testing.expectEqualStrings("util", try previewText(&finder));
    // A preview is read once per selection, not per change of results, but
    // again on refresh.
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "repo/src/util.zig", .data = "changed" });
    try finder.search(testing.allocator, testing.io, &background, "util");
    try settle(&finder, &background);
    try testing.expectEqualStrings("util", try previewText(&finder));
    try finder.focus(testing.allocator, testing.io, &background, .project, &.{});
    try testing.expect(finder.preview() == .loading);
    try settle(&finder, &background);
    try testing.expectEqualStrings("changed", try previewText(&finder));
    // A file replaced by a FIFO since it was listed is refused without blocking,
    // and Enter still offers it to the validating loader.
    try scratch.dir.deleteFile(testing.io, "repo/swap");
    const fifo_mode = std.os.linux.S.IFIFO | 0o600;
    const fifo = std.os.linux.mknodat(scratch.dir.handle, "repo/swap", fifo_mode, 0);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fifo));
    try finder.search(testing.allocator, testing.io, &background, "swap");
    try settle(&finder, &background);
    const refused: Preview = .{ .unavailable = error.UnsupportedFileType };
    try testing.expectEqual(refused, finder.preview());
    try testing.expectEqualStrings("swap", finder.choice().?.path);
    try finder.search(testing.allocator, testing.io, &background, "nothing");
    try settle(&finder, &background);
    try testing.expect(finder.preview() == .none);
}

test "an open file previews its document in every category, never its disk bytes" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    var path: [256]u8 = undefined;
    const open = [_]OpenFile{openFile(7, scratch.join(&path, "repo/README"), true, 1)};
    const how: discovery.Start = .{ .directory = scratch.join(&buffer, "repo") };
    finder.start(testing.allocator, testing.io, &background, how);
    // Listed before the root arrives, the document is still recognised after.
    try finder.focus(testing.allocator, testing.io, &background, .project, &open);
    try settle(&finder, &background);
    const document: Preview = .{ .document = id(7) };
    try finder.search(testing.allocator, testing.io, &background, "README");
    try settle(&finder, &background);
    try testing.expectEqual(document, finder.preview());
    for ([_]Category{ .project, .all, .open }) |category| {
        try finder.focus(testing.allocator, testing.io, &background, category, &open);
        try finder.search(testing.allocator, testing.io, &background, "README");
        try settle(&finder, &background);
        try testing.expectEqualStrings("README", selectedLabel(&finder));
        try testing.expectEqual(document, finder.preview());
        try testing.expect((try rowOf(&finder, "README")).modified);
        try testing.expectEqual(@as(usize, 0), finder.previewed.items.len);
    }
    // Closed, it previews from disk again.
    try finder.focus(testing.allocator, testing.io, &background, .project, &.{});
    try settle(&finder, &background);
    try testing.expectEqualStrings("", try previewText(&finder));
    try testing.expect(!(try rowOf(&finder, "README")).modified);
}

test "running out of memory shows the preview unavailable until the next look" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var buffer: [256]u8 = undefined;
    try begin(&finder, &background, &scratch, &buffer);
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    finder.move(failing.allocator(), testing.io, &background, 1);
    const exhausted: Preview = .{ .unavailable = error.OutOfMemory };
    try testing.expectEqual(exhausted, finder.preview());
    finder.move(testing.allocator, testing.io, &background, 0);
    try settle(&finder, &background);
    try testing.expectEqualStrings("", try previewText(&finder));
}

test "a hidden finder discovers and previews nothing until it is focused" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    var path: [256]u8 = undefined;
    const readme = scratch.join(&path, "repo/README");
    const how: discovery.Start = .{ .file = readme };
    finder.start(testing.allocator, testing.io, &background, how);
    try settle(&finder, &background);
    try testing.expect(!finder.resolving());
    try testing.expect(finder.lists.getPtrConst(.project).catalog == null);
    try testing.expectEqualStrings("README", finder.display(readme));
    try testing.expectEqualStrings("/elsewhere/x", finder.display("/elsewhere/x"));
    try finder.focus(testing.allocator, testing.io, &background, .project, &.{});
    try testing.expect(finder.lists.getPtrConst(.project).discovering);
    try settle(&finder, &background);
    try testing.expectEqualStrings("*.log\nbuild/\n", try previewText(&finder));
    // Leaving abandons the read of a newly selected file and frees the last.
    finder.move(testing.allocator, testing.io, &background, 1);
    try testing.expect(background.busy(.preview) or finder.snapshot != null);
    finder.leave(testing.allocator, testing.io, &background);
    try testing.expectEqual(Preview.none, finder.preview());
    try testing.expect(finder.snapshot == null and !finder.reading);
    try settle(&finder, &background);
    try testing.expect(finder.snapshot == null);
    // Results arriving while hidden start no read.
    try finder.search(testing.allocator, testing.io, &background, "main");
    try settle(&finder, &background);
    try expectRows(&finder, &.{"src/main.zig"});
    try testing.expectEqual(@as(usize, 0), finder.previewed.items.len);
    try finder.focus(testing.allocator, testing.io, &background, .project, &.{});
    try settle(&finder, &background);
    try testing.expectEqualStrings("", try previewText(&finder));
    try testing.expectEqualStrings("src/main.zig", finder.previewed.items);
}

test "open paths are relative only when they stay beneath the root" {
    try testing.expectEqualStrings("a/b", beneath("/r", "/r/a/b").?);
    try testing.expectEqualStrings("a", beneath("/", "/a").?);
    try testing.expectEqual(@as(?[]const u8, null), beneath("/r", "/rx/a"));
    try testing.expectEqual(@as(?[]const u8, null), beneath("/r", "/r/"));
    try testing.expectEqual(@as(?[]const u8, null), beneath("/r", "/r/a/../../etc"));
    try testing.expectEqual(@as(?[]const u8, null), beneath("/r", "/r/./a"));
}

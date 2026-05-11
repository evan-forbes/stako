//! Notes-root storage reader: list stacks, list items, read one item.
//!
//! Layout (see `todos/design_init_and_layout.md` and
//! `todos/design_stack_item_format.md`):
//!
//!     <notes-root>/stacks/<stack>/stack.toml
//!     <notes-root>/stacks/<stack>/<id>-<slug>/meta.toml
//!     <notes-root>/stacks/<stack>/<id>-<slug>/prompt.md          (optional)
//!
//! This is a pure read path. It reuses milestone-1 item parsing and
//! milestone-2 stack-config parsing rather than redefining either schema.

const std = @import("std");
const item_mod = @import("item.zig");
const stack_config = @import("stack_config.zig");

pub const Error = error{
    NotFound,
    BadItemId,
    Toml,
    BadType,
    OutOfMemory,
} || item_mod.ParseError || stack_config.ParseError || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.StatError;

/// A lightweight reference to a stack on disk. Names come from the directory
/// listing under `<notes-root>/stacks/`.
pub const StackSummary = struct {
    name: []const u8,
};

/// A lightweight reference to an item on disk. Mostly the `(id, slug)` pair
/// plus enough metadata to render a list view without a full parse.
pub const ItemSummary = struct {
    id: []const u8,
    slug: []const u8,
    kind: []const u8,
    status: []const u8,
};

/// Reader bound to a notes root.
pub const Reader = struct {
    allocator: std.mem.Allocator,
    notes_root_abs: []u8,

    pub fn init(allocator: std.mem.Allocator, notes_root: []const u8) !Reader {
        // Resolve to an absolute path so all subsequent operations are
        // independent of the daemon's cwd.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = try std.fs.cwd().realpath(notes_root, &buf);
        return .{
            .allocator = allocator,
            .notes_root_abs = try allocator.dupe(u8, abs),
        };
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.notes_root_abs);
    }

    fn openStacksDir(self: *const Reader) !std.fs.Dir {
        const path = try std.fs.path.join(self.allocator, &.{ self.notes_root_abs, "stacks" });
        defer self.allocator.free(path);
        return std.fs.openDirAbsolute(path, .{ .iterate = true });
    }

    fn openStackDir(self: *const Reader, stack: []const u8) !std.fs.Dir {
        if (!isValidStackName(stack)) return error.NotFound;
        const path = try std.fs.path.join(self.allocator, &.{ self.notes_root_abs, "stacks", stack });
        defer self.allocator.free(path);
        return std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.NotFound,
            else => return e,
        };
    }

    /// Allocate-and-return a sorted list of stack names. Caller frees via
    /// `freeStackList`.
    pub fn listStacks(self: *const Reader) ![][]const u8 {
        var stacks_dir = self.openStacksDir() catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return self.allocator.alloc([]const u8, 0),
            else => return e,
        };
        defer stacks_dir.close();

        var out = std.ArrayList([]const u8){};
        errdefer {
            for (out.items) |s| self.allocator.free(s);
            out.deinit(self.allocator);
        }

        var it = stacks_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (!isValidStackName(entry.name)) continue;
            try out.append(self.allocator, try self.allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, out.items, {}, lessThanString);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeStackList(self: *const Reader, list: [][]const u8) void {
        for (list) |s| self.allocator.free(s);
        self.allocator.free(list);
    }

    /// Return the parsed `stack.toml` config for a stack. Caller deinits.
    pub fn readStackConfig(self: *const Reader, stack: []const u8) !stack_config.StackConfig {
        var d = try self.openStackDir(stack);
        defer d.close();
        var f = d.openFile("stack.toml", .{}) catch |e| switch (e) {
            error.FileNotFound => return error.NotFound,
            else => return e,
        };
        defer f.close();
        const stat = try f.stat();
        const src = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(src);
        const n = try f.readAll(src);
        return try stack_config.parseSlice(self.allocator, src[0..n]);
    }

    /// List items in a stack, ordered by id ascending. Each item is parsed
    /// just enough to populate `ItemSummary`. Caller frees via `freeItemList`.
    pub fn listItems(self: *const Reader, stack: []const u8) ![]ItemSummary {
        var d = try self.openStackDir(stack);
        defer d.close();

        var out = std.ArrayList(ItemSummary){};
        errdefer freeOwnedSummaries(self.allocator, out.items);
        errdefer out.deinit(self.allocator);

        var it = d.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            // Expect `<id>-<slug>`.
            const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
            const id_part = entry.name[0..dash];
            const slug_part = entry.name[dash + 1 ..];
            if (!item_mod.isValidId(id_part)) continue;
            if (!item_mod.isValidSlug(slug_part)) continue;

            // Read meta.toml just enough to extract kind+status without the
            // full item validation pass.
            const meta_path = try std.fs.path.join(self.allocator, &.{ entry.name, "meta.toml" });
            defer self.allocator.free(meta_path);

            var f = d.openFile(meta_path, .{}) catch continue; // skip malformed
            defer f.close();
            const stat = try f.stat();
            const src = try self.allocator.alloc(u8, stat.size);
            defer self.allocator.free(src);
            const n = try f.readAll(src);

            var diag: item_mod.ParseDiagnostic = .{};
            var parsed = item_mod.parseSlice(self.allocator, src[0..n], &diag) catch continue;
            defer parsed.deinit();

            try out.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, parsed.id),
                .slug = try self.allocator.dupe(u8, parsed.slug),
                .kind = try self.allocator.dupe(u8, parsed.kind.toString()),
                .status = try self.allocator.dupe(u8, parsed.status.toString()),
            });
        }

        std.mem.sort(ItemSummary, out.items, {}, lessThanItem);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeItemList(self: *const Reader, list: []ItemSummary) void {
        freeOwnedSummaries(self.allocator, list);
        self.allocator.free(list);
    }

    /// Read a single item by id. Caller deinits the returned `Item`.
    pub fn readItem(self: *const Reader, stack: []const u8, id: []const u8) !item_mod.Item {
        if (!item_mod.isValidId(id)) return error.BadItemId;
        var d = try self.openStackDir(stack);
        defer d.close();
        // Scan directory listings to find `<id>-<slug>/`.
        var it = d.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
            if (!std.mem.eql(u8, entry.name[0..dash], id)) continue;
            const meta_rel = try std.fs.path.join(self.allocator, &.{ entry.name, "meta.toml" });
            defer self.allocator.free(meta_rel);
            var f = d.openFile(meta_rel, .{}) catch return error.NotFound;
            defer f.close();
            const stat = try f.stat();
            const src = try self.allocator.alloc(u8, stat.size);
            defer self.allocator.free(src);
            const n = try f.readAll(src);
            var diag: item_mod.ParseDiagnostic = .{};
            return try item_mod.parseSlice(self.allocator, src[0..n], &diag);
        }
        return error.NotFound;
    }
};

fn freeOwnedSummaries(a: std.mem.Allocator, items: []const ItemSummary) void {
    for (items) |s| {
        a.free(s.id);
        a.free(s.slug);
        a.free(s.kind);
        a.free(s.status);
    }
}

/// Stack-name rules per the design docs: kebab-case lowercase identifiers.
pub fn isValidStackName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.' or s[0] == '-') return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanItem(_: void, a: ItemSummary, b: ItemSummary) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

// ---------- unit tests ----------

test "isValidStackName" {
    try std.testing.expect(isValidStackName("default"));
    try std.testing.expect(isValidStackName("foo-bar"));
    try std.testing.expect(isValidStackName("smoke"));
    try std.testing.expect(!isValidStackName(""));
    try std.testing.expect(!isValidStackName(".hidden"));
    try std.testing.expect(!isValidStackName("-leading"));
    try std.testing.expect(!isValidStackName("Upper"));
    try std.testing.expect(!isValidStackName("../bad"));
    try std.testing.expect(!isValidStackName("with space"));
}

test "Reader: listStacks empty when stacks/ absent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    var r = try Reader.init(a, abs);
    defer r.deinit();
    const stacks = try r.listStacks();
    defer r.freeStackList(stacks);
    try std.testing.expectEqual(@as(usize, 0), stacks.len);
}

test "Reader: listStacks finds well-named subdirectories" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/default");
    try tmp.dir.makePath("stacks/smoke");
    try tmp.dir.makePath("stacks/.skip");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    var r = try Reader.init(a, abs);
    defer r.deinit();
    const stacks = try r.listStacks();
    defer r.freeStackList(stacks);
    try std.testing.expectEqual(@as(usize, 2), stacks.len);
    try std.testing.expectEqualStrings("default", stacks[0]);
    try std.testing.expectEqualStrings("smoke", stacks[1]);
}

test "Reader: readStackConfig and listItems" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/0001-hi");
    {
        var f = try tmp.dir.createFile("stacks/demo/stack.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"demo\"\ncreated_at = 2026-05-10T14:00:00Z\n");
    }
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hi/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hi"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\provider = "anthropic"
            \\model = "claude-opus-4-7"
            \\match = "exact"
            \\
        );
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    var r = try Reader.init(a, abs);
    defer r.deinit();

    var cfg = try r.readStackConfig("demo");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("demo", cfg.description.?);

    const items = try r.listItems("demo");
    defer r.freeItemList(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("0001", items[0].id);
    try std.testing.expectEqualStrings("hi", items[0].slug);
    try std.testing.expectEqualStrings("prompt", items[0].kind);
    try std.testing.expectEqualStrings("queued", items[0].status);

    var item = try r.readItem("demo", "0001");
    defer item.deinit();
    try std.testing.expectEqualStrings("0001", item.id);
}

test "Reader: unknown stack returns NotFound" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    var r = try Reader.init(a, abs);
    defer r.deinit();
    try std.testing.expectError(error.NotFound, r.readStackConfig("does-not-exist"));
    try std.testing.expectError(error.NotFound, r.listItems("does-not-exist"));
}

test "Reader: malformed item id rejected with BadItemId" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    var r = try Reader.init(a, abs);
    defer r.deinit();
    try std.testing.expectError(error.BadItemId, r.readItem("demo", "abc"));
}

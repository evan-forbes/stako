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
const routine_mod = @import("routine.zig");
const stack_config = @import("stack_config.zig");
const stack_thread = @import("stack_thread.zig");

pub const Error = error{
    NotFound,
    BadItemId,
    BadThreadName,
    Toml,
    BadType,
    OutOfMemory,
} || item_mod.ParseError || stack_config.ParseError || stack_thread.ParseError || routine_mod.Error || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.StatError;

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

pub const ThreadSummary = struct {
    name: []const u8,
    status: []const u8,
    updated_at: []const u8,
};

pub const RoutineSummary = routine_mod.Summary;

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

    fn openRoutinesDir(self: *const Reader) !std.fs.Dir {
        const path = try std.fs.path.join(self.allocator, &.{ self.notes_root_abs, "routines" });
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

            if (try self.readItemSummary(&d, entry.name)) |summary| {
                try out.append(self.allocator, summary);
            }
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

    pub fn listThreads(self: *const Reader, stack: []const u8) ![]ThreadSummary {
        var stack_dir = try self.openStackDir(stack);
        defer stack_dir.close();

        var threads_dir = stack_dir.openDir("threads", .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return self.allocator.alloc(ThreadSummary, 0),
            else => return e,
        };
        defer threads_dir.close();

        var out = std.ArrayList(ThreadSummary){};
        errdefer freeOwnedThreadSummaries(self.allocator, out.items);
        errdefer out.deinit(self.allocator);

        var it = threads_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
            const name = entry.name[0 .. entry.name.len - ".toml".len];
            if (!stack_thread.isValidName(name)) continue;
            if (try self.readThreadSummary(&threads_dir, entry.name)) |summary| {
                try out.append(self.allocator, summary);
            }
        }

        std.mem.sort(ThreadSummary, out.items, {}, lessThanThread);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeThreadList(self: *const Reader, list: []ThreadSummary) void {
        freeOwnedThreadSummaries(self.allocator, list);
        self.allocator.free(list);
    }

    pub fn listRoutines(self: *const Reader) ![]RoutineSummary {
        var routines_dir = self.openRoutinesDir() catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return self.allocator.alloc(RoutineSummary, 0),
            else => return e,
        };
        defer routines_dir.close();

        var out = std.ArrayList(RoutineSummary){};
        errdefer freeOwnedRoutineSummaries(self.allocator, out.items);
        errdefer out.deinit(self.allocator);

        var it = routines_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
            const name = entry.name[0 .. entry.name.len - ".toml".len];
            if (!isValidRoutineFileName(name)) continue;
            if (try self.readRoutineSummary(&routines_dir, entry.name)) |summary| {
                try out.append(self.allocator, summary);
            }
        }

        std.mem.sort(RoutineSummary, out.items, {}, lessThanRoutine);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeRoutineList(self: *const Reader, list: []RoutineSummary) void {
        freeOwnedRoutineSummaries(self.allocator, list);
        self.allocator.free(list);
    }

    pub fn readRoutine(self: *const Reader, name: []const u8) !routine_mod.Routine {
        if (!isValidRoutineFileName(name)) return error.NotFound;
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.toml", .{name});
        defer self.allocator.free(file_name);
        const path = try std.fs.path.join(self.allocator, &.{ self.notes_root_abs, "routines", file_name });
        defer self.allocator.free(path);
        var diag: routine_mod.Diagnostic = .{};
        return routine_mod.parseFile(self.allocator, path, &diag) catch |e| switch (e) {
            error.MissingPromptFile => return error.NotFound,
            else => return e,
        };
    }

    pub fn readThread(self: *const Reader, stack: []const u8, name: []const u8) !stack_thread.Thread {
        if (!stack_thread.isValidName(name)) return error.BadThreadName;
        var d = try self.openStackDir(stack);
        defer d.close();
        const rel = try std.fmt.allocPrint(self.allocator, "threads/{s}.toml", .{name});
        defer self.allocator.free(rel);
        var f = d.openFile(rel, .{}) catch |e| switch (e) {
            error.FileNotFound, error.IsDir => return error.NotFound,
            else => return e,
        };
        defer f.close();
        const stat = try f.stat();
        const src = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(src);
        const n = try f.readAll(src);
        var diag: stack_thread.ParseDiagnostic = .{};
        return try stack_thread.parseSlice(self.allocator, src[0..n], &diag);
    }

    /// Return null for incomplete or malformed item directories. Operational
    /// read errors still propagate so real items do not disappear silently.
    fn readItemSummary(self: *const Reader, stack_dir: *std.fs.Dir, dir_name: []const u8) !?ItemSummary {
        const meta_path = try std.fs.path.join(self.allocator, &.{ dir_name, "meta.toml" });
        defer self.allocator.free(meta_path);

        var f = stack_dir.openFile(meta_path, .{}) catch |e| switch (e) {
            error.FileNotFound, error.IsDir => return null,
            else => return e,
        };
        defer f.close();
        const stat = try f.stat();
        const src = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(src);
        const n = try f.readAll(src);

        var diag: item_mod.ParseDiagnostic = .{};
        var parsed = item_mod.parseSlice(self.allocator, src[0..n], &diag) catch return null;
        defer parsed.deinit();

        return .{
            .id = try self.allocator.dupe(u8, parsed.id),
            .slug = try self.allocator.dupe(u8, parsed.slug),
            .kind = try self.allocator.dupe(u8, parsed.kind.toString()),
            .status = try self.allocator.dupe(u8, parsed.status.toString()),
        };
    }

    fn readThreadSummary(self: *const Reader, threads_dir: *std.fs.Dir, file_name: []const u8) !?ThreadSummary {
        var f = threads_dir.openFile(file_name, .{}) catch |e| switch (e) {
            error.FileNotFound, error.IsDir => return null,
            else => return e,
        };
        defer f.close();
        const stat = try f.stat();
        const src = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(src);
        const n = try f.readAll(src);

        var diag: stack_thread.ParseDiagnostic = .{};
        var parsed = stack_thread.parseSlice(self.allocator, src[0..n], &diag) catch return null;
        defer parsed.deinit();

        return .{
            .name = try self.allocator.dupe(u8, parsed.name),
            .status = try self.allocator.dupe(u8, parsed.status.toString()),
            .updated_at = try self.allocator.dupe(u8, parsed.updated_at),
        };
    }

    fn readRoutineSummary(self: *const Reader, routines_dir: *std.fs.Dir, file_name: []const u8) !?RoutineSummary {
        var f = routines_dir.openFile(file_name, .{}) catch |e| switch (e) {
            error.FileNotFound, error.IsDir => return null,
            else => return e,
        };
        defer f.close();
        const stat = try f.stat();
        const src = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(src);
        const n = try f.readAll(src);

        const name = file_name[0 .. file_name.len - ".toml".len];
        var diag: routine_mod.Diagnostic = .{};
        var parsed = routine_mod.parseSliceWithDefaultName(self.allocator, src[0..n], name, &diag) catch return null;
        defer parsed.deinit();

        return .{
            .name = try self.allocator.dupe(u8, parsed.name),
            .description = if (parsed.description) |d| try self.allocator.dupe(u8, d) else null,
        };
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

fn freeOwnedThreadSummaries(a: std.mem.Allocator, items: []const ThreadSummary) void {
    for (items) |s| {
        a.free(s.name);
        a.free(s.status);
        a.free(s.updated_at);
    }
}

fn freeOwnedRoutineSummaries(a: std.mem.Allocator, items: []const RoutineSummary) void {
    for (items) |s| {
        a.free(s.name);
        if (s.description) |d| a.free(d);
    }
}

/// Stack-name rules per the design docs: lowercase identifiers with words
/// separated by single dashes or underscores.
pub fn isValidStackName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.' or s[0] == '-' or s[0] == '_') return false;
    if (s[s.len - 1] == '-' or s[s.len - 1] == '_') return false;
    var prev_sep = false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
        const sep = c == '-' or c == '_';
        if (sep and prev_sep) return false;
        prev_sep = sep;
    }
    return true;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanItem(_: void, a: ItemSummary, b: ItemSummary) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessThanThread(_: void, a: ThreadSummary, b: ThreadSummary) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessThanRoutine(_: void, a: RoutineSummary, b: RoutineSummary) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn isValidRoutineFileName(s: []const u8) bool {
    return isValidStackName(s);
}

// ---------- unit tests ----------

test "isValidStackName" {
    try std.testing.expect(isValidStackName("default"));
    try std.testing.expect(isValidStackName("foo-bar"));
    try std.testing.expect(isValidStackName("foo_bar"));
    try std.testing.expect(isValidStackName("smoke"));
    try std.testing.expect(!isValidStackName(""));
    try std.testing.expect(!isValidStackName(".hidden"));
    try std.testing.expect(!isValidStackName("-leading"));
    try std.testing.expect(!isValidStackName("_leading"));
    try std.testing.expect(!isValidStackName("trailing-"));
    try std.testing.expect(!isValidStackName("trailing_"));
    try std.testing.expect(!isValidStackName("double--dash"));
    try std.testing.expect(!isValidStackName("double__underscore"));
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

test "Reader: listThreads empty when threads directory absent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo");
    var cfg = try tmp.dir.createFile("stacks/demo/stack.toml", .{ .truncate = true });
    defer cfg.close();
    try cfg.writeAll("created_at = 2026-05-10T14:00:00Z\n");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    var r = try Reader.init(a, abs);
    defer r.deinit();
    const threads = try r.listThreads("demo");
    defer r.freeThreadList(threads);
    try std.testing.expectEqual(@as(usize, 0), threads.len);
}

test "Reader: listThreads and readThread" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/threads");
    {
        var f = try tmp.dir.createFile("stacks/demo/threads/admin.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
        );
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    var r = try Reader.init(a, abs);
    defer r.deinit();
    const threads = try r.listThreads("demo");
    defer r.freeThreadList(threads);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expectEqualStrings("admin", threads[0].name);
    try std.testing.expectEqualStrings("active", threads[0].status);

    var thread = try r.readThread("demo", "admin");
    defer thread.deinit();
    try std.testing.expectEqualStrings("admin", thread.name);
}

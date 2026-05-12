//! Daemon Config: typed view over `.organo/config.toml` and
//! `.organo/config.local.toml`.
//!
//! Load order: `config.toml` first, then `config.local.toml` overlaid on top.
//! Per `todos/design_init_and_layout.md`:
//!   - Scalar leaf keys: last-write-wins (local overrides committed).
//!   - `[identity.<name>]` tables: replaced wholesale (no field-level merge).
//!     A local identity entry shadows rather than partially overrides.
//!
//! This module owns the typed view; the rest of the daemon reads `Config`
//! and never re-parses the TOML directly.

const std = @import("std");
const toml = @import("toml.zig");

pub const Identity = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    description: ?[]const u8 = null,
    capabilities: ?[]const []const u8 = null,
};

pub const Daemon = struct {
    loopback_only: bool = true,
    default_stack: []const u8 = "default",
    port: u16 = 7421,
};

pub const Workdir = struct {
    allowlist: []const []const u8 = &.{},
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    daemon: Daemon = .{},
    workdir: Workdir = .{},
    identities: []const Identity = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn findIdentity(self: *const Config, name: []const u8) ?*const Identity {
        for (self.identities) |*idn| {
            if (std.mem.eql(u8, idn.name, name)) return idn;
        }
        return null;
    }
};

pub const LoadError = error{
    BadType,
    UnknownContinuity,
    PortOutOfRange,
    Toml,
    OutOfMemory,
    FileTooLarge,
} || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.StatError;

/// Load the daemon configuration from a notes root.
///
/// Looks at `<notes_root>/.organo/config.toml` and (optionally)
/// `<notes_root>/.organo/config.local.toml`. Missing files are tolerated:
/// load returns the defaults for any field not specified. This lets tests
/// run against a temp dir that only has the bits they need.
pub fn loadFromRoot(allocator: std.mem.Allocator, notes_root: []const u8) LoadError!Config {
    var cfg: Config = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer cfg.deinit();
    const arena = cfg.arena.allocator();
    // Default values use the arena so the lifetime is uniform.
    cfg.daemon.default_stack = try arena.dupe(u8, "default");

    var root = try std.fs.cwd().openDir(notes_root, .{});
    defer root.close();

    // Layer 1: config.toml.
    if (try readOptional(arena, &root, ".organo/config.toml")) |bytes| {
        try applyLayer(arena, &cfg, bytes, .committed);
    }
    // Layer 2: config.local.toml (overrides).
    if (try readOptional(arena, &root, ".organo/config.local.toml")) |bytes| {
        try applyLayer(arena, &cfg, bytes, .local);
    }

    return cfg;
}

const Layer = enum { committed, local };

fn readOptional(arena: std.mem.Allocator, dir: *std.fs.Dir, rel: []const u8) LoadError!?[]const u8 {
    var f = dir.openFile(rel, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer f.close();
    const stat = try f.stat();
    const buf = try arena.alloc(u8, stat.size);
    const n = try f.readAll(buf);
    return buf[0..n];
}

fn applyLayer(
    arena: std.mem.Allocator,
    cfg: *Config,
    source: []const u8,
    layer: Layer,
) LoadError!void {
    _ = layer;
    const doc = toml.parse(arena, source) catch return error.Toml;
    // Don't deinit doc — arena owns the strings.

    // Identity tables: collect a fresh per-layer set, then merge by replacement.
    var layer_identities = std.ArrayList(Identity){};
    defer layer_identities.deinit(arena);

    for (doc.entries.items) |e| {
        if (e.table.len == 0) {
            // Top-level entries are not used by daemon config.
            continue;
        }
        if (std.mem.eql(u8, e.table, "daemon")) {
            try applyDaemonField(arena, &cfg.daemon, e);
        } else if (std.mem.eql(u8, e.table, "workdir")) {
            try applyWorkdirField(arena, &cfg.workdir, e);
        } else if (std.mem.startsWith(u8, e.table, "identity.")) {
            try applyIdentityField(arena, &layer_identities, e);
        }
        // Unknown tables (e.g. [provider.*]) are tolerated for forward-compat.
    }

    // Merge identities: any name appearing in this layer fully replaces a
    // same-named identity from a prior layer.
    if (layer_identities.items.len > 0) {
        var merged = std.ArrayList(Identity){};
        defer merged.deinit(arena);
        // Carry over prior-layer identities that aren't shadowed.
        for (cfg.identities) |prior| {
            var shadowed = false;
            for (layer_identities.items) |new_id| {
                if (std.mem.eql(u8, prior.name, new_id.name)) {
                    shadowed = true;
                    break;
                }
            }
            if (!shadowed) try merged.append(arena, prior);
        }
        // Append the new layer.
        for (layer_identities.items) |new_id| try merged.append(arena, new_id);
        cfg.identities = try merged.toOwnedSlice(arena);
    }
}

fn applyDaemonField(arena: std.mem.Allocator, d: *Daemon, e: toml.Entry) LoadError!void {
    if (std.mem.eql(u8, e.key, "loopback_only")) {
        if (e.value != .boolean) return error.BadType;
        d.loopback_only = e.value.boolean;
    } else if (std.mem.eql(u8, e.key, "default_stack")) {
        if (e.value != .string) return error.BadType;
        d.default_stack = try arena.dupe(u8, e.value.string);
    } else if (std.mem.eql(u8, e.key, "port")) {
        if (e.value != .integer) return error.BadType;
        if (e.value.integer < 1 or e.value.integer > 65535) return error.PortOutOfRange;
        d.port = @intCast(e.value.integer);
    }
    // Unknown daemon keys silently tolerated for forward-compat.
}

fn applyWorkdirField(arena: std.mem.Allocator, w: *Workdir, e: toml.Entry) LoadError!void {
    if (std.mem.eql(u8, e.key, "allowlist")) {
        if (e.value != .string_array) return error.BadType;
        const src = e.value.string_array;
        const out = try arena.alloc([]const u8, src.len);
        for (src, 0..) |s, i| out[i] = try arena.dupe(u8, s);
        w.allowlist = out;
    }
}

fn applyIdentityField(
    arena: std.mem.Allocator,
    layer_identities: *std.ArrayList(Identity),
    e: toml.Entry,
) LoadError!void {
    const name = e.table["identity.".len..];
    if (name.len == 0) return;
    // Find or create.
    var idx: ?usize = null;
    for (layer_identities.items, 0..) |id, i| {
        if (std.mem.eql(u8, id.name, name)) {
            idx = i;
            break;
        }
    }
    if (idx == null) {
        try layer_identities.append(arena, .{ .name = try arena.dupe(u8, name) });
        idx = layer_identities.items.len - 1;
    }
    var id = &layer_identities.items[idx.?];

    if (std.mem.eql(u8, e.key, "type")) {
        if (e.value != .string) return error.BadType;
        id.type = try arena.dupe(u8, e.value.string);
    } else if (std.mem.eql(u8, e.key, "description")) {
        if (e.value != .string) return error.BadType;
        id.description = try arena.dupe(u8, e.value.string);
    } else if (std.mem.eql(u8, e.key, "capabilities")) {
        if (e.value != .string_array) return error.BadType;
        const src = e.value.string_array;
        const out = try arena.alloc([]const u8, src.len);
        for (src, 0..) |s, i| out[i] = try arena.dupe(u8, s);
        id.capabilities = out;
    }
}

// ---------- unit tests ----------

test "loadFromRoot: empty notes root yields defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var cfg = try loadFromRoot(a, abs);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.daemon.loopback_only);
    try std.testing.expectEqualStrings("default", cfg.daemon.default_stack);
    try std.testing.expectEqual(@as(u16, 7421), cfg.daemon.port);
    try std.testing.expectEqual(@as(usize, 0), cfg.identities.len);
}

test "loadFromRoot: layered with config.toml + config.local.toml" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    {
        var f = try tmp.dir.createFile(".organo/config.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\[daemon]
            \\loopback_only = true
            \\default_stack = "default"
            \\port = 9000
            \\
        );
    }
    {
        var f = try tmp.dir.createFile(".organo/config.local.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\[daemon]
            \\port = 7421
            \\
        );
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var cfg = try loadFromRoot(a, abs);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 7421), cfg.daemon.port); // local wins
    try std.testing.expectEqualStrings("default", cfg.daemon.default_stack);
}

test "loadFromRoot: identity tables replace wholesale, not merge" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    {
        var f = try tmp.dir.createFile(".organo/config.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\[identity.local]
            \\type = "user"
            \\description = "project default local"
            \\capabilities = ["stack.default.read"]
            \\
            \\[identity.codex-local]
            \\type = "mcp"
            \\capabilities = ["stack.default.read"]
            \\
        );
    }
    {
        var f = try tmp.dir.createFile(".organo/config.local.toml", .{ .truncate = true });
        defer f.close();
        // Only set capabilities; type/description must NOT carry over from
        // the committed file (full replacement semantics).
        try f.writeAll(
            \\[identity.local]
            \\capabilities = ["*"]
            \\
        );
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var cfg = try loadFromRoot(a, abs);
    defer cfg.deinit();

    const local = cfg.findIdentity("local") orelse return error.MissingIdentity;
    try std.testing.expect(local.type == null);
    try std.testing.expect(local.description == null);
    try std.testing.expect(local.capabilities != null);
    try std.testing.expectEqual(@as(usize, 1), local.capabilities.?.len);
    try std.testing.expectEqualStrings("*", local.capabilities.?[0]);

    // Non-shadowed identity from the committed file survives.
    const codex = cfg.findIdentity("codex-local") orelse return error.MissingIdentity;
    try std.testing.expectEqualStrings("mcp", codex.type.?);
}

test "loadFromRoot: workdir.allowlist" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    {
        var f = try tmp.dir.createFile(".organo/config.local.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\[workdir]
            \\allowlist = ["~/code", "/tmp/x"]
            \\
        );
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var cfg = try loadFromRoot(a, abs);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.workdir.allowlist.len);
    try std.testing.expectEqualStrings("~/code", cfg.workdir.allowlist[0]);
    try std.testing.expectEqualStrings("/tmp/x", cfg.workdir.allowlist[1]);
}

test "loadFromRoot: invalid port rejected" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    var f = try tmp.dir.createFile(".organo/config.local.toml", .{ .truncate = true });
    defer f.close();
    try f.writeAll("[daemon]\nport = 99999\n");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.PortOutOfRange, loadFromRoot(a, abs));
}

test "loadFromRoot: config read errors are not treated as missing config" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo/config.toml");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.IsDir, loadFromRoot(a, abs));
}

test "loadFromRoot: malformed TOML in config.local.toml surfaces error.Toml" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    var f = try tmp.dir.createFile(".organo/config.local.toml", .{ .truncate = true });
    defer f.close();
    // Unterminated string ⇒ TOML parse failure.
    try f.writeAll("[daemon]\nport = \"oops\n");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.Toml, loadFromRoot(a, abs));
}

test "loadFromRoot: wrong scalar type rejected with error.BadType" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    var f = try tmp.dir.createFile(".organo/config.local.toml", .{ .truncate = true });
    defer f.close();
    // port is declared as a string instead of integer.
    try f.writeAll("[daemon]\nport = \"7421\"\n");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.BadType, loadFromRoot(a, abs));
}

test "loadFromRoot: loopback_only wrong type rejected" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    var f = try tmp.dir.createFile(".organo/config.local.toml", .{ .truncate = true });
    defer f.close();
    try f.writeAll("[daemon]\nloopback_only = \"yes\"\n");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.BadType, loadFromRoot(a, abs));
}

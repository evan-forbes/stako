//! Per-stack configuration: `<notes-root>/stacks/<name>/stack.toml`.
//!
//! See `todos/design_stack_config.md` for the canonical schema and field
//! semantics. Milestone 2 only needs the defaults writer plus a reader that
//! accepts an empty-or-defaults file, so the layout produced by `organo init`
//! round-trips cleanly. Wiring (`paused`, `continuity`, `allowed_harnesses`,
//! etc.) into runtime behavior lands in later milestones.

const std = @import("std");
const toml = @import("toml.zig");

pub const Continuity = enum {
    fresh,
    chain,

    pub fn fromString(s: []const u8) ?Continuity {
        if (std.mem.eql(u8, s, "fresh")) return .fresh;
        if (std.mem.eql(u8, s, "chain")) return .chain;
        return null;
    }

    pub fn toString(self: Continuity) []const u8 {
        return switch (self) {
            .fresh => "fresh",
            .chain => "chain",
        };
    }
};

/// Defaults match `todos/design_stack_config.md`'s "Field Semantics" table.
pub const StackConfig = struct {
    arena: std.heap.ArenaAllocator,

    description: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    paused: bool = false,
    continuity: Continuity = .fresh,
    max_concurrent_per_stack: i64 = 1,
    default_workdir: ?[]const u8 = null,
    allowed_harnesses: ?[]const []const u8 = null,

    pub fn deinit(self: *StackConfig) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    Toml,
    BadType,
    UnknownContinuity,
    InvalidConcurrency,
    OutOfMemory,
};

pub fn parseSlice(allocator: std.mem.Allocator, source: []const u8) ParseError!StackConfig {
    var doc = toml.parse(allocator, source) catch return error.Toml;
    defer doc.deinit();

    var cfg: StackConfig = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer cfg.deinit();
    const arena = cfg.arena.allocator();

    for (doc.entries.items) |e| {
        if (e.table.len != 0) {
            // Stack config is flat (no tables) in the design. Tolerate unknown
            // tables silently for forward-compat.
            continue;
        }
        if (std.mem.eql(u8, e.key, "description")) {
            if (e.value != .string) return error.BadType;
            cfg.description = try arena.dupe(u8, e.value.string);
        } else if (std.mem.eql(u8, e.key, "created_at")) {
            if (e.value != .datetime) return error.BadType;
            cfg.created_at = try arena.dupe(u8, e.value.datetime);
        } else if (std.mem.eql(u8, e.key, "paused")) {
            if (e.value != .boolean) return error.BadType;
            cfg.paused = e.value.boolean;
        } else if (std.mem.eql(u8, e.key, "continuity")) {
            if (e.value != .string) return error.BadType;
            cfg.continuity = Continuity.fromString(e.value.string) orelse return error.UnknownContinuity;
        } else if (std.mem.eql(u8, e.key, "max_concurrent_per_stack")) {
            if (e.value != .integer) return error.BadType;
            if (e.value.integer < 1) return error.InvalidConcurrency;
            cfg.max_concurrent_per_stack = e.value.integer;
        } else if (std.mem.eql(u8, e.key, "default_workdir")) {
            if (e.value != .string) return error.BadType;
            cfg.default_workdir = try arena.dupe(u8, e.value.string);
        } else if (std.mem.eql(u8, e.key, "allowed_harnesses")) {
            if (e.value != .string_array) return error.BadType;
            const src = e.value.string_array;
            const out = try arena.alloc([]const u8, src.len);
            for (src, 0..) |s, i| out[i] = try arena.dupe(u8, s);
            cfg.allowed_harnesses = out;
        }
        // Unknown keys: silently tolerated for forward-compat; the design says
        // they trigger a warning at daemon startup, but the warning belongs in
        // milestone 3.
    }

    return cfg;
}

/// Write the canonical "all defaults" stack.toml. Used by `organo init` for
/// `stacks/default/stack.toml` and as the baseline for any new stack.
pub fn writeDefaults(w: anytype, created_at: []const u8) !void {
    // Keep this output byte-stable; tests snapshot it.
    try w.writeAll("# stacks/default/stack.toml — created by `organo init`.\n");
    try w.writeAll("# All fields below are at their documented defaults. Edit freely;\n");
    try w.writeAll("# see todos/design_stack_config.md for field semantics.\n");
    try w.writeAll("\n");
    try w.writeAll("description = \"default stack\"\n");
    try w.writeAll("created_at = ");
    try w.writeAll(created_at);
    try w.writeByte('\n');
    try w.writeAll("paused = false\n");
    try w.writeAll("continuity = \"fresh\"\n");
    try w.writeAll("max_concurrent_per_stack = 1\n");
}

test "writeDefaults round-trips through parser" {
    var out = std.ArrayList(u8){};
    defer out.deinit(std.testing.allocator);
    try writeDefaults(out.writer(std.testing.allocator), "2026-05-10T14:00:00Z");

    var cfg = try parseSlice(std.testing.allocator, out.items);
    defer cfg.deinit();

    try std.testing.expect(cfg.description != null);
    try std.testing.expectEqualStrings("default stack", cfg.description.?);
    try std.testing.expectEqualStrings("2026-05-10T14:00:00Z", cfg.created_at.?);
    try std.testing.expectEqual(false, cfg.paused);
    try std.testing.expectEqual(Continuity.fresh, cfg.continuity);
    try std.testing.expectEqual(@as(i64, 1), cfg.max_concurrent_per_stack);
    try std.testing.expect(cfg.default_workdir == null);
    try std.testing.expect(cfg.allowed_harnesses == null);
}

test "parseSlice: empty source yields all defaults" {
    var cfg = try parseSlice(std.testing.allocator, "");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.paused);
    try std.testing.expectEqual(Continuity.fresh, cfg.continuity);
    try std.testing.expectEqual(@as(i64, 1), cfg.max_concurrent_per_stack);
}

test "parseSlice: chain continuity" {
    const src = "continuity = \"chain\"\n";
    var cfg = try parseSlice(std.testing.allocator, src);
    defer cfg.deinit();
    try std.testing.expectEqual(Continuity.chain, cfg.continuity);
}

test "parseSlice: unknown continuity errors" {
    const src = "continuity = \"forever\"\n";
    try std.testing.expectError(error.UnknownContinuity, parseSlice(std.testing.allocator, src));
}

test "parseSlice: allowed_harnesses array" {
    const src = "allowed_harnesses = [\"claude\", \"codex\"]\n";
    var cfg = try parseSlice(std.testing.allocator, src);
    defer cfg.deinit();
    try std.testing.expect(cfg.allowed_harnesses != null);
    try std.testing.expectEqual(@as(usize, 2), cfg.allowed_harnesses.?.len);
    try std.testing.expectEqualStrings("claude", cfg.allowed_harnesses.?[0]);
}

test "parseSlice: max_concurrent_per_stack must be positive" {
    try std.testing.expectError(error.InvalidConcurrency, parseSlice(std.testing.allocator, "max_concurrent_per_stack = 0\n"));
    try std.testing.expectError(error.InvalidConcurrency, parseSlice(std.testing.allocator, "max_concurrent_per_stack = -1\n"));
}

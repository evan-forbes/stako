//! Per-harness adapter contract (milestone 6).
//!
//! Each supported CLI (claude, codex, gemini, plus the fake test harness)
//! implements this interface. The session manager creates one adapter
//! instance per item, drives stdin (rare) and stdout/stderr through the
//! adapter, and consumes a stream of `NormalizedEvent`s.
//!
//! See `todos/design_execution_harness.md` ("Per-Harness Adapter Contract").
//!
//! v1 design choices:
//!
//!   - Adapter is stateful per session (small per-session memory: e.g. the
//!     harness-side `session_id` once parsed).
//!   - Adapter does not write to disk; the session manager owns transcript
//!     and runtime-file IO.
//!   - `parse_line` returns owned event slices. The caller frees the slice
//!     and each event's `data_json` after fanout.
//!   - Errors during parse become a single `error` normalized event so a
//!     single malformed line doesn't drop the session.

const std = @import("std");
const events = @import("events.zig");
const item_mod = @import("item.zig");

pub const Capability = enum {
    @"resume",
    compact,
    clear,
    partial_messages,
    file_change_events,
};

/// One emitted event plus its owning storage so the caller can free it.
pub const OwnedEvent = struct {
    ev: events.Event,
    /// Backing storage for `ev.data_json` and any borrowed slices.
    storage: []u8,
};

/// Adapter vtable. Concrete adapters keep an internal state struct and
/// pass `*Adapter` (the embedded vtable) to the session manager.
pub const Adapter = struct {
    name: []const u8,
    /// Pointer to the concrete adapter struct.
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        parse_line: *const fn (impl: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]OwnedEvent,
        parse_stderr_line: *const fn (impl: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]OwnedEvent,
        on_exit: *const fn (impl: *anyopaque, allocator: std.mem.Allocator, exit_code: i32, ran_to_completion: bool) anyerror!OwnedEvent,
        supports: *const fn (impl: *anyopaque, cap: Capability) bool,
        deinit: *const fn (impl: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn parseLine(self: Adapter, a: std.mem.Allocator, raw: []const u8) ![]OwnedEvent {
        return self.vtable.parse_line(self.impl, a, raw);
    }
    pub fn parseStderrLine(self: Adapter, a: std.mem.Allocator, raw: []const u8) ![]OwnedEvent {
        return self.vtable.parse_stderr_line(self.impl, a, raw);
    }
    pub fn onExit(self: Adapter, a: std.mem.Allocator, exit_code: i32, ran_to_completion: bool) !OwnedEvent {
        return self.vtable.on_exit(self.impl, a, exit_code, ran_to_completion);
    }
    pub fn supports(self: Adapter, cap: Capability) bool {
        return self.vtable.supports(self.impl, cap);
    }
    pub fn deinit(self: Adapter, a: std.mem.Allocator) void {
        self.vtable.deinit(self.impl, a);
    }
};

/// Free one OwnedEvent's storage.
pub fn freeOwned(allocator: std.mem.Allocator, e: OwnedEvent) void {
    if (e.storage.len > 0) allocator.free(e.storage);
}

pub fn freeOwnedSlice(allocator: std.mem.Allocator, evs: []OwnedEvent) void {
    for (evs) |e| freeOwned(allocator, e);
    allocator.free(evs);
}

/// Result of an adapter's `invocation` builder. Caller owns argv and env_map.
pub const Invocation = struct {
    argv: [][]const u8,
    env_map: ?*std.process.EnvMap = null,
    cwd: ?[]const u8 = null,
    /// Optional input fed to the subprocess's stdin; null leaves stdin closed
    /// (the typical case for adapters that pass the prompt via argv).
    stdin: ?[]const u8 = null,

    pub fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        for (self.argv) |a| allocator.free(a);
        allocator.free(self.argv);
        if (self.env_map) |m| {
            m.deinit();
            allocator.destroy(m);
        }
        if (self.cwd) |c| allocator.free(c);
        if (self.stdin) |s| allocator.free(s);
    }
};

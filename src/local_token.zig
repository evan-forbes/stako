//! Local mutation token: ensure `.stako/local_token` exists, load it into
//! memory, and provide a constant-time verifier used by mutation endpoints
//! once they land (milestone 5).
//!
//! On disk shape (created by `stako init` in milestone 2):
//!   - 64 lowercase hex characters + a trailing newline.
//!   - File mode 0600.
//!   - Gitignored.
//!
//! In milestone 3 the daemon only generates the token if absent (e.g. when
//! a user spins up the daemon against a directory that predates stako's
//! init flow) and exposes a verifier for the future mutation path.

const std = @import("std");

pub const TokenError = anyerror;

pub const Token = struct {
    /// The raw token text WITHOUT the trailing newline.
    bytes: []const u8,

    pub fn verify(self: Token, presented: []const u8) bool {
        if (self.bytes.len != presented.len) return false;
        // Constant-time compare to avoid leaking the prefix length.
        var diff: u8 = 0;
        for (self.bytes, presented) |a, b| diff |= a ^ b;
        return diff == 0;
    }
};

/// Resolve `<notes_root>/.stako/local_token`. If absent, generate one with
/// 0600 perms; otherwise leave the file untouched. Returns the in-memory
/// token, owned by `allocator`.
pub fn ensureAndLoad(
    allocator: std.mem.Allocator,
    notes_root: []const u8,
) TokenError!Token {
    var root = try std.fs.cwd().openDir(notes_root, .{});
    defer root.close();

    // Try open-for-read first.
    if (root.openFile(".stako/local_token", .{})) |f| {
        defer f.close();
        // Re-tighten perms in case the file was created or chmod'd with
        // looser permissions by something outside stako. The token must
        // stay 0600; verified on every load to keep the contract.
        std.posix.fchmod(f.handle, 0o600) catch {};
        return try readToken(allocator, f);
    } else |open_err| switch (open_err) {
        error.FileNotFound => {
            // Generate.
            try root.makePath(".stako");
            const fresh = try generateHex(allocator);
            errdefer allocator.free(fresh);
            var f = try root.createFile(".stako/local_token", .{ .truncate = true, .mode = 0o600 });
            defer f.close();
            try f.writeAll(fresh);
            try f.writeAll("\n");
            return .{ .bytes = fresh };
        },
        else => return open_err,
    }
}

fn readToken(allocator: std.mem.Allocator, f: std.fs.File) TokenError!Token {
    const stat = try f.stat();
    if (stat.size == 0) return error.BadShape;
    var tmp = try allocator.alloc(u8, stat.size);
    defer allocator.free(tmp);
    const n = try f.readAll(tmp);
    var end = n;
    while (end > 0 and (tmp[end - 1] == '\n' or tmp[end - 1] == '\r')) end -= 1;
    if (end == 0) return error.BadShape;
    if (!isHexLike(tmp[0..end])) return error.BadShape;
    // Return a clean allocation (no trailing newline) so the caller can free
    // it without slicing artifacts.
    const out = try allocator.dupe(u8, tmp[0..end]);
    return .{ .bytes = out };
}

fn isHexLike(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn generateHex(allocator: std.mem.Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, raw.len * 2);
    for (raw, 0..) |b, i| {
        out[i * 2 + 0] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

// ---------- tests ----------

test "verify: constant-time compare matches identical bytes" {
    const t: Token = .{ .bytes = "abc123" };
    try std.testing.expect(t.verify("abc123"));
    try std.testing.expect(!t.verify("abc124"));
    try std.testing.expect(!t.verify("abc12")); // different length
}

test "ensureAndLoad: existing token read verbatim" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".stako");
    var f = try tmp.dir.createFile(".stako/local_token", .{ .truncate = true });
    try f.writeAll("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n");
    f.close();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    const tok = try ensureAndLoad(a, abs);
    defer a.free(tok.bytes);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", tok.bytes);
}

test "ensureAndLoad: absent token generated with hex shape" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    const tok = try ensureAndLoad(a, abs);
    defer a.free(tok.bytes);
    try std.testing.expectEqual(@as(usize, 64), tok.bytes.len);
    for (tok.bytes) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
    // File now exists.
    try tmp.dir.access(".stako/local_token", .{});
}

test "ensureAndLoad: rejects malformed token file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".stako");
    var f = try tmp.dir.createFile(".stako/local_token", .{ .truncate = true });
    try f.writeAll("not hex!\n");
    f.close();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.BadShape, ensureAndLoad(a, abs));
}

test "ensureAndLoad: rejects short uppercase and overlong token files" {
    const a = std.testing.allocator;
    inline for (.{ "0123456789abcdef\n", "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef\n", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef00\n" }) |contents| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makePath(".stako");
        var f = try tmp.dir.createFile(".stako/local_token", .{ .truncate = true });
        try f.writeAll(contents);
        f.close();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = try tmp.dir.realpath(".", &buf);
        try std.testing.expectError(error.BadShape, ensureAndLoad(a, abs));
    }
}

test "ensureAndLoad: rejects empty token file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".stako");
    var f = try tmp.dir.createFile(".stako/local_token", .{ .truncate = true });
    f.close();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.BadShape, ensureAndLoad(a, abs));
}

test "ensureAndLoad: generated token file has 0600 perms" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    const tok = try ensureAndLoad(a, abs);
    defer a.free(tok.bytes);

    var f = try tmp.dir.openFile(".stako/local_token", .{});
    defer f.close();
    const stat = try f.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
}

test "ensureAndLoad: re-tightens perms on a previously widened token file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".stako");
    {
        var f = try tmp.dir.createFile(".stako/local_token", .{ .truncate = true, .mode = 0o644 });
        try f.writeAll("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n");
        f.close();
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    const tok = try ensureAndLoad(a, abs);
    defer a.free(tok.bytes);

    var f = try tmp.dir.openFile(".stako/local_token", .{});
    defer f.close();
    const stat = try f.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
}

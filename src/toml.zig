//! Minimal TOML reader/writer tailored to stako's plan.toml schema.
//!
//! This is deliberately a small, hand-rolled implementation rather than a
//! vendored full TOML parser. The supported subset:
//!
//!   - Top-level key/value pairs, `[table]` headers, and `[[array-of-tables]]`
//!     headers (each `[[name]]` opens a new element of the `name` array).
//!   - String, bool, integer, RFC3339-datetime values, and arrays of strings.
//!   - Comments (`# ...`) and blank lines (ignored on read; not preserved).
//!   - One key per line, no inline tables, no dotted keys.
//!
//! Datetimes are stored as their literal source text. The validator separately
//! checks RFC3339 shape. The writer prints them back verbatim so a value read
//! from a file and rewritten produces the same bytes.
//!
//! Why a hand-rolled parser: plan.toml is fully under our control, and the
//! schema is fixed. A full TOML library would add an external dependency for
//! features we never use. Round-trip stability is easier to guarantee when we
//! own the key emission order.

const std = @import("std");

pub const ValueKind = enum {
    string,
    integer,
    boolean,
    datetime,
    string_array,
};

pub const Value = union(ValueKind) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    /// Stored as the literal source text, e.g. `2026-05-10T14:32:00Z`.
    datetime: []const u8,
    string_array: [][]const u8,
};

/// One parsed key/value entry, in source order. `table` is "" for top-level
/// keys and the bare table name (e.g. "target") otherwise. `array_index` is
/// set when the entry belongs to an `[[array-of-tables]]` element and names
/// which element (0-based, in source order); it is null for top-level keys and
/// single `[table]` entries.
pub const Entry = struct {
    table: []const u8,
    key: []const u8,
    value: Value,
    array_index: ?usize = null,
};

/// One `[[array-of-tables]]` name and how many elements were parsed for it.
pub const ArrayTable = struct {
    name: []const u8,
    count: usize,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    /// Every `[table]` header observed, in source order. Includes empty
    /// tables (which have no entries). Top-level "" is not recorded.
    tables: std.ArrayList([]const u8),
    /// Every `[[array-of-tables]]` name and its element count, in first-seen
    /// order. Used to iterate `[[thread]]`/`[[prompt]]` blocks.
    array_tables: std.ArrayList(ArrayTable),
    /// Owned backing storage for all strings/arrays inside `entries`.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void {
        self.entries.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.array_tables.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Find the first top-level or single-`[table]` entry matching (table, key).
    /// Array-of-tables entries are skipped; use `findInArray` for those.
    pub fn find(self: *const Document, table: []const u8, key: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (e.array_index != null) continue;
            if (std.mem.eql(u8, e.table, table) and std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    pub fn hasTable(self: *const Document, table: []const u8) bool {
        for (self.tables.items) |t| {
            if (std.mem.eql(u8, t, table)) return true;
        }
        return false;
    }

    /// Number of `[[name]]` elements parsed, or 0 if `name` is not an array of
    /// tables.
    pub fn arrayCount(self: *const Document, name: []const u8) usize {
        for (self.array_tables.items) |at| {
            if (std.mem.eql(u8, at.name, name)) return at.count;
        }
        return 0;
    }

    /// Find `key` within element `index` of the `[[name]]` array of tables.
    pub fn findInArray(self: *const Document, name: []const u8, index: usize, key: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            const ai = e.array_index orelse continue;
            if (ai != index) continue;
            if (std.mem.eql(u8, e.table, name) and std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }
};

pub const ParseError = error{
    UnterminatedString,
    UnterminatedArray,
    UnexpectedCharacter,
    InvalidEscape,
    InvalidNumber,
    InvalidBoolean,
    MissingEquals,
    EmptyKey,
    UnclosedTableHeader,
    EmptyTableName,
    TrailingGarbage,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Document {
    var doc = Document{
        .allocator = allocator,
        .entries = .empty,
        .tables = .empty,
        .array_tables = .empty,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer doc.deinit();
    const arena_alloc = doc.arena.allocator();

    var current_table: []const u8 = "";
    // null while top-level or under a single `[table]`; set under `[[name]]`.
    var current_array_index: ?usize = null;
    var i: usize = 0;
    while (i < source.len) {
        // skip leading whitespace
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
        if (i >= source.len) break;

        // skip blank/comment line
        if (source[i] == '\n') {
            i += 1;
            continue;
        }
        if (source[i] == '\r') {
            i += 1;
            if (i < source.len and source[i] == '\n') i += 1;
            continue;
        }
        if (source[i] == '#') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }

        if (source[i] == '[') {
            const is_array = i + 1 < source.len and source[i + 1] == '[';
            i += if (is_array) 2 else 1;
            const name_start = i;
            while (i < source.len and source[i] != ']' and source[i] != '\n') : (i += 1) {}
            if (i >= source.len or source[i] != ']') return error.UnclosedTableHeader;
            if (is_array and (i + 1 >= source.len or source[i + 1] != ']')) return error.UnclosedTableHeader;
            const name = std.mem.trim(u8, source[name_start..i], " \t");
            if (name.len == 0) return error.EmptyTableName;
            current_table = try arena_alloc.dupe(u8, name);
            i += if (is_array) 2 else 1; // consume `]` or `]]`
            if (is_array) {
                current_array_index = try bumpArrayTable(&doc, current_table);
            } else {
                current_array_index = null;
                try doc.tables.append(allocator, current_table);
            }
            // skip trailing whitespace + optional comment, then newline
            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
            if (i < source.len and source[i] == '#') {
                while (i < source.len and source[i] != '\n') : (i += 1) {}
            }
            if (i < source.len) {
                if (source[i] == '\r') i += 1;
                if (i < source.len and source[i] == '\n') i += 1 else if (i < source.len) {
                    return error.TrailingGarbage;
                }
            }
            continue;
        }

        // key = value
        const key_start = i;
        while (i < source.len and source[i] != '=' and source[i] != '\n' and source[i] != ' ' and source[i] != '\t') : (i += 1) {}
        const key_end = i;
        if (key_end == key_start) return error.EmptyKey;
        const key = source[key_start..key_end];
        // skip spaces
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
        if (i >= source.len or source[i] != '=') return error.MissingEquals;
        i += 1; // '='
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}

        const value = try parseValue(arena_alloc, source, &i);
        // skip trailing whitespace/comment
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
        if (i < source.len and source[i] == '#') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
        }
        if (i < source.len) {
            if (source[i] == '\r') i += 1;
            if (i < source.len and source[i] == '\n') i += 1 else if (i < source.len) {
                // unexpected non-newline trailing
                return error.TrailingGarbage;
            }
        }

        try doc.entries.append(allocator, .{
            .table = current_table,
            .key = try arena_alloc.dupe(u8, key),
            .value = value,
            .array_index = current_array_index,
        });
    }

    return doc;
}

/// Record one more `[[name]]` element and return its 0-based index.
fn bumpArrayTable(doc: *Document, name: []const u8) ParseError!usize {
    for (doc.array_tables.items) |*at| {
        if (std.mem.eql(u8, at.name, name)) {
            const idx = at.count;
            at.count += 1;
            return idx;
        }
    }
    try doc.array_tables.append(doc.allocator, .{ .name = name, .count = 1 });
    return 0;
}

fn parseValue(arena: std.mem.Allocator, source: []const u8, i_ptr: *usize) ParseError!Value {
    var i = i_ptr.*;
    defer i_ptr.* = i;
    if (i >= source.len) return error.UnexpectedCharacter;

    if (source[i] == '"') {
        const s = try parseString(arena, source, &i);
        return Value{ .string = s };
    }
    if (source[i] == '[') {
        const arr = try parseStringArray(arena, source, &i);
        return Value{ .string_array = arr };
    }
    if (source[i] == 't' or source[i] == 'f') {
        const start = i;
        while (i < source.len and (std.ascii.isAlphabetic(source[i]))) : (i += 1) {}
        const lit = source[start..i];
        if (std.mem.eql(u8, lit, "true")) return Value{ .boolean = true };
        if (std.mem.eql(u8, lit, "false")) return Value{ .boolean = false };
        return error.InvalidBoolean;
    }
    // number or datetime: collect non-space, non-newline, non-# token then classify
    const start = i;
    while (i < source.len and source[i] != '\n' and source[i] != '\r' and source[i] != '#') : (i += 1) {}
    var end = i;
    // trim trailing spaces
    while (end > start and (source[end - 1] == ' ' or source[end - 1] == '\t')) : (end -= 1) {}
    const tok = source[start..end];
    if (tok.len == 0) return error.UnexpectedCharacter;

    // datetime: contains 'T' or starts with year digits followed by '-'
    if (looksLikeDatetime(tok)) {
        return Value{ .datetime = try arena.dupe(u8, tok) };
    }

    // integer
    const n = std.fmt.parseInt(i64, tok, 10) catch return error.InvalidNumber;
    return Value{ .integer = n };
}

fn looksLikeDatetime(tok: []const u8) bool {
    if (tok.len < 10) return false;
    // YYYY-MM-DD prefix
    for (0..4) |idx| if (!std.ascii.isDigit(tok[idx])) return false;
    if (tok[4] != '-') return false;
    for (5..7) |idx| if (!std.ascii.isDigit(tok[idx])) return false;
    if (tok[7] != '-') return false;
    for (8..10) |idx| if (!std.ascii.isDigit(tok[idx])) return false;
    return true;
}

fn parseString(arena: std.mem.Allocator, source: []const u8, i_ptr: *usize) ParseError![]const u8 {
    var i = i_ptr.*;
    std.debug.assert(source[i] == '"');
    i += 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    while (i < source.len) {
        const c = source[i];
        if (c == '"') {
            i += 1;
            i_ptr.* = i;
            return try buf.toOwnedSlice(arena);
        }
        if (c == '\\') {
            i += 1;
            if (i >= source.len) return error.UnterminatedString;
            const esc = source[i];
            i += 1;
            switch (esc) {
                'n' => try buf.append(arena, '\n'),
                't' => try buf.append(arena, '\t'),
                'r' => try buf.append(arena, '\r'),
                '"' => try buf.append(arena, '"'),
                '\\' => try buf.append(arena, '\\'),
                else => return error.InvalidEscape,
            }
            continue;
        }
        if (c == '\n') return error.UnterminatedString;
        try buf.append(arena, c);
        i += 1;
    }
    return error.UnterminatedString;
}

fn parseStringArray(arena: std.mem.Allocator, source: []const u8, i_ptr: *usize) ParseError![][]const u8 {
    var i = i_ptr.*;
    std.debug.assert(source[i] == '[');
    i += 1;
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(arena);
    while (i < source.len) {
        // skip whitespace and newlines and comments
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) : (i += 1) {}
        if (i < source.len and source[i] == '#') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (i >= source.len) return error.UnterminatedArray;
        if (source[i] == ']') {
            i += 1;
            i_ptr.* = i;
            return try items.toOwnedSlice(arena);
        }
        if (source[i] != '"') return error.UnexpectedCharacter;
        const s = try parseString(arena, source, &i);
        try items.append(arena, s);
        // skip whitespace
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) : (i += 1) {}
        if (i < source.len and source[i] == ',') {
            i += 1;
            continue;
        }
        if (i < source.len and source[i] == ']') {
            i += 1;
            i_ptr.* = i;
            return try items.toOwnedSlice(arena);
        }
        // Token after a string wasn't `,` or `]`, so the array can't be
        // continued or closed; the right diagnostic is "unexpected", not
        // "unterminated".
        return error.UnexpectedCharacter;
    }
    return error.UnterminatedArray;
}

// ---------- writer ----------

pub fn writeString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

pub fn writeStringArray(w: anytype, items: []const []const u8) !void {
    try w.writeByte('[');
    for (items, 0..) |s, idx| {
        if (idx != 0) try w.writeAll(", ");
        try writeString(w, s);
    }
    try w.writeByte(']');
}

test "parse top level" {
    const src =
        \\id = "0001"
        \\count = 7
        \\enabled = true
        \\
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.entries.items.len);
    try std.testing.expectEqualStrings("0001", doc.entries.items[0].value.string);
    try std.testing.expectEqual(@as(i64, 7), doc.entries.items[1].value.integer);
    try std.testing.expectEqual(true, doc.entries.items[2].value.boolean);
}

test "parse table and array" {
    const src =
        \\[target]
        \\provider = "anthropic"
        \\
        \\[requires]
        \\tools = ["a", "b"]
        \\
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.entries.items.len);
    try std.testing.expectEqualStrings("target", doc.entries.items[0].table);
    try std.testing.expectEqualStrings("provider", doc.entries.items[0].key);
    try std.testing.expectEqualStrings("anthropic", doc.entries.items[0].value.string);
    try std.testing.expectEqualStrings("requires", doc.entries.items[1].table);
    const arr = doc.entries.items[1].value.string_array;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("a", arr[0]);
}

test "parse array of tables" {
    const src =
        \\name = "refactor-loop"
        \\
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[thread]]
        \\name = "reviewer"
        \\command = "claude"
        \\
        \\[[prompt]]
        \\name = "impl-1"
        \\thread = "impl"
        \\blocked_by = []
        \\
        \\[[prompt]]
        \\name = "review-1"
        \\thread = "reviewer"
        \\blocked_by = ["impl-1"]
        \\
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expectEqualStrings("refactor-loop", doc.find("", "name").?.value.string);
    try std.testing.expectEqual(@as(usize, 2), doc.arrayCount("thread"));
    try std.testing.expectEqual(@as(usize, 2), doc.arrayCount("prompt"));
    try std.testing.expectEqual(@as(usize, 0), doc.arrayCount("missing"));

    try std.testing.expectEqualStrings("impl", doc.findInArray("thread", 0, "name").?.value.string);
    try std.testing.expectEqualStrings("codex", doc.findInArray("thread", 0, "command").?.value.string);
    try std.testing.expectEqualStrings("reviewer", doc.findInArray("thread", 1, "name").?.value.string);

    try std.testing.expectEqualStrings("review-1", doc.findInArray("prompt", 1, "name").?.value.string);
    const blockers = doc.findInArray("prompt", 1, "blocked_by").?.value.string_array;
    try std.testing.expectEqual(@as(usize, 1), blockers.len);
    try std.testing.expectEqualStrings("impl-1", blockers[0]);

    // Top-level `find` must not return array-of-tables entries.
    try std.testing.expect(doc.find("thread", "name") == null);
}

test "array-of-tables header rejects single-bracket close" {
    try std.testing.expectError(error.UnclosedTableHeader, parse(std.testing.allocator,
        \\[[thread]
        \\name = "impl"
        \\
    ));
}

test "parse datetime" {
    const src =
        \\created_at = 2026-05-10T14:32:00Z
        \\
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqualStrings("2026-05-10T14:32:00Z", doc.entries.items[0].value.datetime);
}

test "parse table header rejects trailing garbage" {
    const src =
        \\[target] junk
        \\provider = "anthropic"
        \\
    ;
    try std.testing.expectError(error.TrailingGarbage, parse(std.testing.allocator, src));
}

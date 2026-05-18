//! Routine file format: reusable batch item templates under `<notes-root>/routines`.

const std = @import("std");
const item_mod = @import("item.zig");
const stack_thread = @import("stack_thread.zig");
const toml = @import("toml.zig");

pub const Error = error{
    Toml,
    MissingField,
    BadType,
    UnsupportedVersion,
    ValidationFailed,
    DuplicateStep,
    MissingStepReference,
    Cycle,
    MissingPromptFile,
    OutOfMemory,
} || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.StatError;

pub const Diagnostic = struct {
    err: Error = error.ValidationFailed,
    message: []const u8 = "",
    field: []const u8 = "",
};

pub const Step = struct {
    name: []const u8,
    slug: []const u8,
    kind: item_mod.Kind,
    prompts: ?[]const []const u8 = null,
    command: ?item_mod.Command = null,
    thread: ?[]const u8 = null,
};

pub const Routine = struct {
    arena: std.heap.ArenaAllocator,
    version: i64,
    name: []const u8,
    description: ?[]const u8 = null,
    thread: ?[]const u8 = null,
    source_dir_abs: ?[]const u8 = null,
    steps: []const Step,

    pub fn deinit(self: *Routine) void {
        self.arena.deinit();
    }

    pub fn topologicalOrder(self: *const Routine, allocator: std.mem.Allocator) Error![]usize {
        const order = try allocator.alloc(usize, self.steps.len);
        for (order, 0..) |*slot, i| slot.* = i;
        return order;
    }

    pub fn resolvePrompt(self: *const Routine, allocator: std.mem.Allocator, step: *const Step) Error![]u8 {
        if (step.prompts) |prompts| return self.resolvePromptList(allocator, prompts);
        return allocator.alloc(u8, 0);
    }

    fn resolvePromptList(self: *const Routine, allocator: std.mem.Allocator, prompts: []const []const u8) Error![]u8 {
        if (prompts.len == 0) return error.ValidationFailed;
        var out = std.ArrayList(u8){};
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        for (prompts, 0..) |rel, i| {
            if (!isValidPromptPath(rel)) return error.ValidationFailed;
            const base = self.source_dir_abs orelse ".";
            const abs = try std.fs.path.join(allocator, &.{ base, rel });
            defer allocator.free(abs);
            var f = std.fs.cwd().openFile(abs, .{}) catch |e| switch (e) {
                error.FileNotFound, error.IsDir => return error.MissingPromptFile,
                else => return e,
            };
            defer f.close();
            const stat = try f.stat();
            const buf = try allocator.alloc(u8, stat.size);
            defer allocator.free(buf);
            const n = try f.readAll(buf);
            if (i != 0) try w.writeAll("\n\n---\n\n");
            try w.writeAll(stripTomlFrontmatter(buf[0..n]));
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const Summary = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub fn parseSlice(allocator: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Routine {
    return parseSliceWithDefaultName(allocator, source, null, diag);
}

pub fn parseSliceWithDefaultName(
    allocator: std.mem.Allocator,
    source: []const u8,
    default_name: ?[]const u8,
    diag: *Diagnostic,
) Error!Routine {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const first_section = findRoutineSectionHeader(source) orelse source.len;
    var root_doc = toml.parse(allocator, source[0..first_section]) catch {
        diag.* = .{ .err = error.Toml, .message = "TOML parse failed", .field = "" };
        return error.Toml;
    };
    defer root_doc.deinit();

    const version = if (find(&root_doc, "", "version")) |_| try requireInt(&root_doc, "", "version", diag) else 1;
    if (version != 1) {
        diag.* = .{ .err = error.UnsupportedVersion, .message = "routine version must be 1", .field = "version" };
        return error.UnsupportedVersion;
    }
    const name_src = if (find(&root_doc, "", "name")) |e|
        try requireValueString(e.value, "name", diag)
    else
        default_name orelse {
            diag.* = .{ .err = error.MissingField, .message = "missing required field", .field = "name" };
            return error.MissingField;
        };
    const name = try aa.dupe(u8, name_src);
    if (!isValidRoutineName(name)) {
        diag.* = .{ .err = error.ValidationFailed, .message = "routine name must be lowercase identifier text", .field = "name" };
        return error.ValidationFailed;
    }
    const description = if (find(&root_doc, "", "description")) |e| try aa.dupe(u8, try requireValueString(e.value, "description", diag)) else null;
    const root_thread = if (find(&root_doc, "", "thread")) |e| blk: {
        const t = try requireValueString(e.value, "thread", diag);
        if (!stack_thread.isValidName(t)) {
            diag.* = .{ .err = error.ValidationFailed, .message = "invalid thread name", .field = "thread" };
            return error.ValidationFailed;
        }
        break :blk try aa.dupe(u8, t);
    } else null;

    var steps = std.ArrayList(Step){};
    defer steps.deinit(allocator);
    var pos = first_section;
    while (pos < source.len) {
        const header = findRoutineSectionHeader(source[pos..]) orelse break;
        const header_abs = pos + header;
        const content_start = header_abs + sectionHeaderLen(source[header_abs..]);
        const next_rel = findRoutineSectionHeader(source[content_start..]) orelse source.len - content_start;
        const content = source[content_start .. content_start + next_rel];
        try steps.append(allocator, try parseStep(allocator, aa, content, steps.items.len, root_thread, diag));
        pos = content_start + next_rel;
    }
    if (steps.items.len == 0) {
        diag.* = .{ .err = error.MissingField, .message = "routine must contain at least one [[step]]", .field = "step" };
        return error.MissingField;
    }

    const owned_steps = try aa.alloc(Step, steps.items.len);
    @memcpy(owned_steps, steps.items);
    try validateSteps(allocator, owned_steps, diag);

    return .{
        .arena = arena,
        .version = version,
        .name = name,
        .description = description,
        .thread = root_thread,
        .steps = owned_steps,
    };
}

pub fn parseFile(allocator: std.mem.Allocator, path_abs: []const u8, diag: *Diagnostic) Error!Routine {
    var f = std.fs.cwd().openFile(path_abs, .{}) catch |e| switch (e) {
        error.FileNotFound, error.IsDir => return error.MissingPromptFile,
        else => return e,
    };
    defer f.close();
    const stat = try f.stat();
    const src = try allocator.alloc(u8, stat.size);
    defer allocator.free(src);
    const n = try f.readAll(src);
    const base = std.fs.path.basename(path_abs);
    const default_name = if (std.mem.endsWith(u8, base, ".toml")) base[0 .. base.len - ".toml".len] else base;
    var r = try parseSliceWithDefaultName(allocator, src[0..n], default_name, diag);
    errdefer r.deinit();
    const dir = std.fs.path.dirname(path_abs) orelse ".";
    r.source_dir_abs = try r.arena.allocator().dupe(u8, dir);
    return r;
}

pub fn write(routine: *const Routine, w: anytype) !void {
    try w.print("version = {d}\n", .{routine.version});
    try w.writeAll("name = ");
    try toml.writeString(w, routine.name);
    try w.writeByte('\n');
    if (routine.description) |d| {
        try w.writeAll("description = ");
        try toml.writeString(w, d);
        try w.writeByte('\n');
    }
    if (routine.thread) |t| {
        try w.writeAll("thread = ");
        try toml.writeString(w, t);
        try w.writeByte('\n');
    }
    for (routine.steps) |step| {
        try w.writeAll("\n[[step]]\n");
        if (step.thread) |t| {
            if (routine.thread == null or !std.mem.eql(u8, routine.thread.?, t)) {
                try w.writeAll("thread = ");
                try toml.writeString(w, t);
                try w.writeByte('\n');
            }
        }
        if (step.prompts) |p| try writeStringArrayField(w, "prompts", p);
        if (step.command) |c| {
            try w.writeAll("command = ");
            try toml.writeString(w, c.toString());
            try w.writeByte('\n');
        }
    }
}

fn parseStep(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    index: usize,
    default_thread: ?[]const u8,
    diag: *Diagnostic,
) Error!Step {
    var doc = toml.parse(allocator, source) catch {
        diag.* = .{ .err = error.Toml, .message = "step TOML parse failed", .field = "step" };
        return error.Toml;
    };
    defer doc.deinit();

    for (doc.entries.items) |e| {
        const known_top_level = std.mem.eql(u8, e.table, "") and
            (std.mem.eql(u8, e.key, "thread") or
                std.mem.eql(u8, e.key, "prompts") or
                std.mem.eql(u8, e.key, "command"));
        if (!known_top_level) {
            diag.* = .{ .err = error.ValidationFailed, .message = "unknown routine step field", .field = e.key };
            return error.ValidationFailed;
        }
    }

    const prompts = if (find(&doc, "", "prompts")) |e| try dupeStringArray(arena, try requireValueStringArray(e.value, "step.prompts", diag)) else null;
    const command = if (find(&doc, "", "command")) |e| blk: {
        const raw = try requireValueString(e.value, "step.command", diag);
        const s = if (std.mem.startsWith(u8, raw, "/")) raw[1..] else raw;
        break :blk item_mod.Command.fromString(s) orelse {
            diag.* = .{ .err = error.ValidationFailed, .message = "unknown command", .field = "step.command" };
            return error.ValidationFailed;
        };
    } else null;
    if (command != null and prompts != null) {
        diag.* = .{ .err = error.ValidationFailed, .message = "command step cannot also declare prompts", .field = "step.command" };
        return error.ValidationFailed;
    }
    if (command == null and prompts == null) {
        diag.* = .{ .err = error.ValidationFailed, .message = "prompt step requires prompts", .field = "step.prompts" };
        return error.ValidationFailed;
    }
    const kind = if (command) |c| c.toKind() else item_mod.Kind.prompt;
    const slug = try deriveElementSlug(arena, prompts, command, index);
    const name = try arena.dupe(u8, slug);
    const thread = if (find(&doc, "", "thread")) |e| blk: {
        const t = try requireValueString(e.value, "step.thread", diag);
        break :blk try arena.dupe(u8, t);
    } else if (default_thread) |t| try arena.dupe(u8, t) else null;
    if (thread == null) {
        diag.* = .{ .err = error.MissingField, .message = "routine step requires a root or step thread", .field = "step.thread" };
        return error.MissingField;
    }

    return .{
        .name = name,
        .slug = slug,
        .kind = kind,
        .prompts = prompts,
        .command = command,
        .thread = thread,
    };
}

fn validateSteps(allocator: std.mem.Allocator, steps: []const Step, diag: *Diagnostic) Error!void {
    for (steps, 0..) |step, i| {
        if (!isValidStepName(step.name)) {
            diag.* = .{ .err = error.ValidationFailed, .message = "invalid step name", .field = "step.name" };
            return error.ValidationFailed;
        }
        if (!item_mod.isValidSlug(step.slug)) {
            diag.* = .{ .err = error.ValidationFailed, .message = "invalid step slug", .field = "step.slug" };
            return error.ValidationFailed;
        }
        if (step.prompts) |prompts| {
            if (prompts.len == 0) {
                diag.* = .{ .err = error.ValidationFailed, .message = "prompts must be non-empty", .field = "step.prompts" };
                return error.ValidationFailed;
            }
            for (prompts) |path| {
                if (!isValidPromptPath(path)) {
                    diag.* = .{ .err = error.ValidationFailed, .message = "invalid prompt path", .field = "step.prompts" };
                    return error.ValidationFailed;
                }
            }
        }
        if (step.thread) |t| {
            if (!stack_thread.isValidName(t)) {
                diag.* = .{ .err = error.ValidationFailed, .message = "invalid thread name", .field = "step.thread" };
                return error.ValidationFailed;
            }
        } else {
            diag.* = .{ .err = error.MissingField, .message = "routine step requires a root or step thread", .field = "step.thread" };
            return error.MissingField;
        }
        if (step.command == null and step.prompts == null) {
            diag.* = .{ .err = error.ValidationFailed, .message = "prompt step requires prompts", .field = "step.prompts" };
            return error.ValidationFailed;
        }
        for (steps[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, step.name)) {
                diag.* = .{ .err = error.DuplicateStep, .message = "duplicate step name", .field = "step.name" };
                return error.DuplicateStep;
            }
        }
    }
    _ = allocator;
}

fn findRoutineSectionHeader(source: []const u8) ?usize {
    var line_start: usize = 0;
    while (line_start <= source.len) {
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        const line = std.mem.trim(u8, source[line_start..line_end], " \t\r");
        if (std.mem.eql(u8, line, "[[step]]")) return line_start;
        if (line_end == source.len) break;
        line_start = line_end + 1;
    }
    return null;
}

fn sectionHeaderLen(source: []const u8) usize {
    var i: usize = 0;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return if (i < source.len) i + 1 else i;
}

fn deriveElementSlug(arena: std.mem.Allocator, prompts: ?[]const []const u8, command: ?item_mod.Command, index: usize) ![]const u8 {
    if (command) |c| return arena.dupe(u8, c.toString());
    const path = if (prompts) |ps| ps[0] else return std.fmt.allocPrint(arena, "element-{d}", .{index + 1});
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem = base[0..dot];
    if (item_mod.isValidSlug(stem)) return arena.dupe(u8, stem);
    return std.fmt.allocPrint(arena, "element-{d}", .{index + 1});
}

fn stripTomlFrontmatter(content: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, content, "+++\n") and !std.mem.startsWith(u8, content, "+++\r\n")) return content;
    const first_end: usize = if (std.mem.startsWith(u8, content, "+++\r\n")) 5 else 4;
    var pos = first_end;
    while (pos <= content.len) {
        const line_start = pos;
        var line_end = line_start;
        while (line_end < content.len and content[line_end] != '\n') : (line_end += 1) {}
        const line = std.mem.trim(u8, content[line_start..line_end], " \t\r");
        if (std.mem.eql(u8, line, "+++")) {
            const after = if (line_end < content.len) line_end + 1 else line_end;
            return content[after..];
        }
        if (line_end == content.len) break;
        pos = line_end + 1;
    }
    return content;
}

fn find(doc: *const toml.Document, table: []const u8, key: []const u8) ?*const toml.Entry {
    return doc.find(table, key);
}

fn requireInt(doc: *const toml.Document, table: []const u8, key: []const u8, diag: *Diagnostic) Error!i64 {
    const e = find(doc, table, key) orelse {
        diag.* = .{ .err = error.MissingField, .message = "missing required field", .field = key };
        return error.MissingField;
    };
    if (e.value != .integer) {
        diag.* = .{ .err = error.BadType, .message = "expected integer", .field = key };
        return error.BadType;
    }
    return e.value.integer;
}

fn requireValueString(v: toml.Value, field: []const u8, diag: *Diagnostic) Error![]const u8 {
    if (v != .string) {
        diag.* = .{ .err = error.BadType, .message = "expected string", .field = field };
        return error.BadType;
    }
    return v.string;
}

fn requireValueStringArray(v: toml.Value, field: []const u8, diag: *Diagnostic) Error![]const []const u8 {
    if (v != .string_array) {
        diag.* = .{ .err = error.BadType, .message = "expected string array", .field = field };
        return error.BadType;
    }
    return v.string_array;
}

fn dupeStringArray(arena: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, src.len);
    for (src, 0..) |s, i| out[i] = try arena.dupe(u8, s);
    return out;
}

fn writeStringArrayField(w: anytype, key: []const u8, values: []const []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    try toml.writeStringArray(w, values);
    try w.writeByte('\n');
}

fn isValidRoutineName(name: []const u8) bool {
    return isValidStepName(name);
}

fn isValidPromptPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".")) return false;
    }
    return true;
}

fn isValidStepName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

test "routine parser round trip" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    var r = try parseSlice(a,
        \\version = 1
        \\name = "planning"
        \\description = "Plan work."
        \\thread = "admin"
        \\
        \\[[step]]
        \\prompts = ["../prompts/research.md"]
        \\
        \\[[step]]
        \\thread = "builder"
        \\prompts = ["../prompts/write.md"]
        \\
    , &diag);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.steps.len);
    try std.testing.expectEqualStrings("planning", r.name);
    try std.testing.expectEqualStrings("research", r.steps[0].name);
    try std.testing.expectEqualStrings("admin", r.steps[0].thread.?);
    try std.testing.expectEqualStrings("builder", r.steps[1].thread.?);
    const order = try r.topologicalOrder(a);
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 0), order[0]);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try write(&r, out.writer(a));
    var r2 = try parseSlice(a, out.items, &diag);
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 2), r2.steps.len);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[[step]]") != null);
}

test "routine order is source order" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    var r = try parseSlice(a,
        \\version = 1
        \\name = "ordered"
        \\thread = "admin"
        \\
        \\[[step]]
        \\prompts = ["a.md"]
        \\
        \\[[step]]
        \\prompts = ["b.md"]
        \\
    , &diag);
    defer r.deinit();
    const order = try r.topologicalOrder(a);
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    try std.testing.expectEqual(@as(usize, 1), order[1]);
}

test "routine parser rejects legacy step fields" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.ValidationFailed, parseSlice(a,
        \\name = "legacy"
        \\thread = "admin"
        \\
        \\[[step]]
        \\prompts = ["a.md"]
        \\kind = "prompt"
        \\
    , &diag));
}

test "routine parser rejects missing effective thread" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.MissingField, parseSlice(a,
        \\name = "missing-thread"
        \\
        \\[[step]]
        \\prompts = ["a.md"]
        \\
    , &diag));
}

test "routine parser accepts slash command spelling" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    var r = try parseSlice(a,
        \\name = "compact-only"
        \\thread = "admin"
        \\
        \\[[step]]
        \\command = "/compact"
        \\
    , &diag);
    defer r.deinit();
    try std.testing.expectEqual(item_mod.Command.compact, r.steps[0].command.?);
}

test "routine parser accepts minimal steps and resolves prompt paths" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("routines");
    try tmp.dir.makePath("prompts/admin-review");
    {
        var f = try tmp.dir.createFile("prompts/admin-review/evaluate.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\+++
            \\title = "evaluate"
            \\+++
            \\Evaluate.
        );
    }
    {
        var f = try tmp.dir.createFile("routines/admin-review.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\thread = "admin"
            \\
            \\[[step]]
            \\prompts = ["../prompts/admin-review/evaluate.md"]
            \\
        );
    }
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    const routine_path = try std.fs.path.join(a, &.{ root, "routines", "admin-review.toml" });
    defer a.free(routine_path);
    var diag: Diagnostic = .{};
    var r = try parseFile(a, routine_path, &diag);
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 1), r.version);
    try std.testing.expectEqualStrings("admin-review", r.name);
    try std.testing.expectEqualStrings("evaluate", r.steps[0].name);
    try std.testing.expectEqualStrings("evaluate", r.steps[0].slug);
    try std.testing.expectEqualStrings("admin", r.steps[0].thread.?);
    try std.testing.expectEqualStrings("../prompts/admin-review/evaluate.md", r.steps[0].prompts.?[0]);
    const prompt = try r.resolvePrompt(a, &r.steps[0]);
    defer a.free(prompt);
    try std.testing.expectEqualStrings("Evaluate.", prompt);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try write(&r, out.writer(a));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[[step]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "slug") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "kind") == null);
}

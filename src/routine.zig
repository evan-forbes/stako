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

pub const Target = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    match: ?item_mod.Match = null,
    workdir: ?[]const u8 = null,
};

pub const Step = struct {
    name: []const u8,
    slug: []const u8,
    kind: item_mod.Kind,
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    after: []const []const u8 = &.{},
    inputs_from: []const []const u8 = &.{},
    thread: ?[]const u8 = null,
    thread_mode: ?item_mod.ThreadMode = null,
    target: Target = .{},
};

pub const Routine = struct {
    arena: std.heap.ArenaAllocator,
    version: i64,
    name: []const u8,
    description: ?[]const u8 = null,
    source_dir_abs: ?[]const u8 = null,
    steps: []const Step,

    pub fn deinit(self: *Routine) void {
        self.arena.deinit();
    }

    pub fn topologicalOrder(self: *const Routine, allocator: std.mem.Allocator) Error![]usize {
        return computeOrder(allocator, self.steps);
    }

    pub fn resolvePrompt(self: *const Routine, allocator: std.mem.Allocator, step: *const Step) Error![]u8 {
        if (step.prompt) |p| return allocator.dupe(u8, p);
        const rel = step.prompt_file orelse return allocator.alloc(u8, 0);
        if (std.fs.path.isAbsolute(rel) or !item_mod.isValidInputFilePath(rel)) return error.ValidationFailed;
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
        errdefer allocator.free(buf);
        const n = try f.readAll(buf);
        return buf[0..n];
    }
};

pub const Summary = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub fn parseSlice(allocator: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Routine {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const first_step = findStepHeader(source) orelse source.len;
    var root_doc = toml.parse(allocator, source[0..first_step]) catch {
        diag.* = .{ .err = error.Toml, .message = "TOML parse failed", .field = "" };
        return error.Toml;
    };
    defer root_doc.deinit();

    const version = try requireInt(&root_doc, "", "version", diag);
    if (version != 1) {
        diag.* = .{ .err = error.UnsupportedVersion, .message = "routine version must be 1", .field = "version" };
        return error.UnsupportedVersion;
    }
    const name = try aa.dupe(u8, try requireString(&root_doc, "", "name", diag));
    if (!isValidRoutineName(name)) {
        diag.* = .{ .err = error.ValidationFailed, .message = "routine name must be lowercase identifier text", .field = "name" };
        return error.ValidationFailed;
    }
    const description = if (find(&root_doc, "", "description")) |e| try aa.dupe(u8, try requireValueString(e.value, "description", diag)) else null;

    var steps = std.ArrayList(Step){};
    defer steps.deinit(allocator);
    var pos = first_step;
    while (pos < source.len) {
        const header = findStepHeader(source[pos..]) orelse break;
        const content_start = pos + header + stepHeaderLen(source[pos + header ..]);
        const next_rel = findStepHeader(source[content_start..]) orelse source.len - content_start;
        const content = source[content_start .. content_start + next_rel];
        try steps.append(allocator, try parseStep(allocator, aa, content, diag));
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
    var r = try parseSlice(allocator, src[0..n], diag);
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
    for (routine.steps) |step| {
        try w.writeAll("\n[[step]]\n");
        try w.writeAll("name = ");
        try toml.writeString(w, step.name);
        try w.writeAll("\nslug = ");
        try toml.writeString(w, step.slug);
        try w.writeAll("\nkind = ");
        try toml.writeString(w, step.kind.toString());
        try w.writeByte('\n');
        if (step.prompt) |p| {
            try w.writeAll("prompt = ");
            try toml.writeString(w, p);
            try w.writeByte('\n');
        }
        if (step.prompt_file) |p| {
            try w.writeAll("prompt_file = ");
            try toml.writeString(w, p);
            try w.writeByte('\n');
        }
        if (step.after.len > 0) try writeStringArrayField(w, "after", step.after);
        if (step.inputs_from.len > 0) try writeStringArrayField(w, "inputs_from", step.inputs_from);
        if (step.thread) |t| {
            try w.writeAll("thread = ");
            try toml.writeString(w, t);
            try w.writeByte('\n');
        }
        if (step.thread_mode) |m| {
            try w.writeAll("thread_mode = ");
            try toml.writeString(w, m.toString());
            try w.writeByte('\n');
        }
        if (targetHasAnyField(step.target)) {
            try w.writeAll("\n[step.target]\n");
            if (step.target.provider) |s| {
                try w.writeAll("provider = ");
                try toml.writeString(w, s);
                try w.writeByte('\n');
            }
            if (step.target.model) |s| {
                try w.writeAll("model = ");
                try toml.writeString(w, s);
                try w.writeByte('\n');
            }
            if (step.target.match) |m| {
                try w.writeAll("match = ");
                try toml.writeString(w, m.toString());
                try w.writeByte('\n');
            }
            if (step.target.workdir) |s| {
                try w.writeAll("workdir = ");
                try toml.writeString(w, s);
                try w.writeByte('\n');
            }
        }
    }
}

fn parseStep(allocator: std.mem.Allocator, arena: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Step {
    var doc = toml.parse(allocator, source) catch {
        diag.* = .{ .err = error.Toml, .message = "step TOML parse failed", .field = "step" };
        return error.Toml;
    };
    defer doc.deinit();

    const name = try arena.dupe(u8, try requireString(&doc, "", "name", diag));
    const slug = try arena.dupe(u8, try requireString(&doc, "", "slug", diag));
    const kind_s = try requireString(&doc, "", "kind", diag);
    const kind = item_mod.Kind.fromString(kind_s) orelse {
        diag.* = .{ .err = error.ValidationFailed, .message = "unknown step kind", .field = "step.kind" };
        return error.ValidationFailed;
    };
    const prompt = if (find(&doc, "", "prompt")) |e| try arena.dupe(u8, try requireValueString(e.value, "step.prompt", diag)) else null;
    const prompt_file = if (find(&doc, "", "prompt_file")) |e| try arena.dupe(u8, try requireValueString(e.value, "step.prompt_file", diag)) else null;
    if ((prompt == null) == (prompt_file == null)) {
        diag.* = .{ .err = error.ValidationFailed, .message = "step requires exactly one of prompt or prompt_file", .field = "step.prompt" };
        return error.ValidationFailed;
    }
    const after = if (find(&doc, "", "after")) |e| try dupeStringArray(arena, try requireValueStringArray(e.value, "step.after", diag)) else &.{};
    const inputs_from = if (find(&doc, "", "inputs_from")) |e| try dupeStringArray(arena, try requireValueStringArray(e.value, "step.inputs_from", diag)) else &.{};
    const thread = if (find(&doc, "", "thread")) |e| try arena.dupe(u8, try requireValueString(e.value, "step.thread", diag)) else null;
    const thread_mode = if (find(&doc, "", "thread_mode")) |e| blk: {
        const s = try requireValueString(e.value, "step.thread_mode", diag);
        break :blk item_mod.ThreadMode.fromString(s) orelse {
            diag.* = .{ .err = error.ValidationFailed, .message = "unknown thread_mode", .field = "step.thread_mode" };
            return error.ValidationFailed;
        };
    } else null;

    var target: Target = .{};
    if (findAnyTarget(&doc, "provider")) |e| target.provider = try arena.dupe(u8, try requireValueString(e.value, "step.target.provider", diag));
    if (findAnyTarget(&doc, "model")) |e| target.model = try arena.dupe(u8, try requireValueString(e.value, "step.target.model", diag));
    if (findAnyTarget(&doc, "match")) |e| {
        const s = try requireValueString(e.value, "step.target.match", diag);
        target.match = item_mod.Match.fromString(s) orelse {
            diag.* = .{ .err = error.ValidationFailed, .message = "unknown target match", .field = "step.target.match" };
            return error.ValidationFailed;
        };
    }
    if (findAnyTarget(&doc, "workdir")) |e| target.workdir = try arena.dupe(u8, try requireValueString(e.value, "step.target.workdir", diag));

    return .{
        .name = name,
        .slug = slug,
        .kind = kind,
        .prompt = prompt,
        .prompt_file = prompt_file,
        .after = after,
        .inputs_from = inputs_from,
        .thread = thread,
        .thread_mode = thread_mode,
        .target = target,
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
        if (step.thread) |t| {
            if (!stack_thread.isValidName(t)) {
                diag.* = .{ .err = error.ValidationFailed, .message = "invalid thread name", .field = "step.thread" };
                return error.ValidationFailed;
            }
        } else if (step.thread_mode != null) {
            diag.* = .{ .err = error.ValidationFailed, .message = "thread_mode requires thread", .field = "step.thread_mode" };
            return error.ValidationFailed;
        }
        if (step.thread_mode) |mode| switch (mode) {
            .fresh, .@"resume" => {},
            .@"continue", .fork => {
                diag.* = .{ .err = error.ValidationFailed, .message = "routine thread_mode must be fresh or resume", .field = "step.thread_mode" };
                return error.ValidationFailed;
            },
        };
        for (steps[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, step.name)) {
                diag.* = .{ .err = error.DuplicateStep, .message = "duplicate step name", .field = "step.name" };
                return error.DuplicateStep;
            }
        }
    }
    const order = computeOrder(allocator, steps) catch |e| {
        diag.* = .{ .err = e, .message = switch (e) {
            error.MissingStepReference => "step reference does not exist",
            error.Cycle => "routine step graph contains a cycle",
            else => "invalid routine step graph",
        }, .field = "step.after" };
        return e;
    };
    allocator.free(order);
}

fn computeOrder(allocator: std.mem.Allocator, steps: []const Step) Error![]usize {
    const n = steps.len;
    var indegree = try allocator.alloc(usize, n);
    defer allocator.free(indegree);
    @memset(indegree, 0);
    var edges = try allocator.alloc(std.ArrayList(usize), n);
    defer {
        for (edges) |*e| e.deinit(allocator);
        allocator.free(edges);
    }
    for (edges) |*e| e.* = .{};

    for (steps, 0..) |step, i| {
        for (step.after) |dep| {
            const j = findStepIndex(steps, dep) orelse return error.MissingStepReference;
            try edges[j].append(allocator, i);
            indegree[i] += 1;
        }
        for (step.inputs_from) |dep| {
            const j = findStepIndex(steps, dep) orelse return error.MissingStepReference;
            try edges[j].append(allocator, i);
            indegree[i] += 1;
        }
    }

    var out = std.ArrayList(usize){};
    errdefer out.deinit(allocator);
    while (out.items.len < n) {
        var picked: ?usize = null;
        for (steps, 0..) |_, i| {
            if (indegree[i] == 0 and !containsIndex(out.items, i)) {
                picked = i;
                break;
            }
        }
        const idx = picked orelse return error.Cycle;
        try out.append(allocator, idx);
        for (edges[idx].items) |to| indegree[to] -= 1;
    }
    return out.toOwnedSlice(allocator);
}

fn findStepIndex(steps: []const Step, name: []const u8) ?usize {
    for (steps, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
    return null;
}

fn containsIndex(items: []const usize, needle: usize) bool {
    for (items) |v| if (v == needle) return true;
    return false;
}

fn findStepHeader(source: []const u8) ?usize {
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

fn stepHeaderLen(source: []const u8) usize {
    var i: usize = 0;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return if (i < source.len) i + 1 else i;
}

fn find(doc: *const toml.Document, table: []const u8, key: []const u8) ?*const toml.Entry {
    return doc.find(table, key);
}

fn findAnyTarget(doc: *const toml.Document, key: []const u8) ?*const toml.Entry {
    return doc.find("step.target", key) orelse doc.find("target", key);
}

fn requireString(doc: *const toml.Document, table: []const u8, key: []const u8, diag: *Diagnostic) Error![]const u8 {
    const e = find(doc, table, key) orelse {
        diag.* = .{ .err = error.MissingField, .message = "missing required field", .field = key };
        return error.MissingField;
    };
    return requireValueString(e.value, key, diag);
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

fn targetHasAnyField(t: Target) bool {
    return t.provider != null or t.model != null or t.match != null or t.workdir != null;
}

fn isValidRoutineName(name: []const u8) bool {
    return isValidStepName(name);
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
        \\
        \\[[step]]
        \\name = "research"
        \\slug = "research"
        \\kind = "prompt"
        \\prompt = "Research."
        \\thread = "admin"
        \\thread_mode = "resume"
        \\
        \\[step.target]
        \\provider = "openai"
        \\match = "compatible"
        \\
        \\[[step]]
        \\name = "write-plan"
        \\slug = "write-plan"
        \\kind = "prompt"
        \\prompt_file = "prompts/write.md"
        \\after = ["research"]
        \\inputs_from = ["research"]
        \\
    , &diag);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.steps.len);
    try std.testing.expectEqualStrings("planning", r.name);
    try std.testing.expectEqualStrings("research", r.steps[0].name);
    try std.testing.expectEqualStrings("openai", r.steps[0].target.provider.?);
    const order = try r.topologicalOrder(a);
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 0), order[0]);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try write(&r, out.writer(a));
    var r2 = try parseSlice(a, out.items, &diag);
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 2), r2.steps.len);
}

test "routine parser rejects cycles" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.Cycle, parseSlice(a,
        \\version = 1
        \\name = "cycle"
        \\
        \\[[step]]
        \\name = "a"
        \\slug = "a"
        \\kind = "prompt"
        \\prompt = "A"
        \\after = ["b"]
        \\
        \\[[step]]
        \\name = "b"
        \\slug = "b"
        \\kind = "prompt"
        \\prompt = "B"
        \\after = ["a"]
        \\
    , &diag));
}

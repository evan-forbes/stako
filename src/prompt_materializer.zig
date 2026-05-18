//! Prompt input resolution and rendered prompt materialization.
//!
//! The source of truth remains on disk: item metadata declares registered
//! inputs, prior item summaries/files are read directly from the notes root,
//! and the exact prompt sent to the harness is written as rendered_prompt.md.

const std = @import("std");
const item_mod = @import("item.zig");

pub const MAX_INPUT_BYTES: usize = 1024 * 1024;

pub const IO_CONTRACT =
    \\## Stako I/O Contract
    \\
    \\Treat registered inputs as the explicit input packet for this prompt. Prior items and commits are commit context: inspect git history only as needed for those references. The durable output is the commit produced by this prompt. If a summary or decision is useful, write it as an ordinary file in the workdir or notes tree chosen by the prompt, then make the final response identify the durable files, decisions, and follow-up prompt, thread, routine, item, or commit context that should be passed forward.
    \\
;

pub const Error = error{
    InputMissing,
    InputTooLarge,
    ValidationFailed,
    OutOfMemory,
} || std.fs.File.OpenError || std.fs.File.StatError || std.fs.File.ReadError || std.fs.File.WriteError || std.fs.Dir.MakeError;

pub fn hasRegisteredInputs(item: *const item_mod.Item) bool {
    const inp = item.inputs orelse return false;
    return (inp.items != null and inp.items.?.len > 0) or
        (inp.files != null and inp.files.?.len > 0) or
        (inp.commits != null and inp.commits.?.len > 0);
}

pub fn shouldMaterializePrompt(item: *const item_mod.Item) bool {
    return item.kind == .prompt;
}

pub fn materializePrompt(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack_name: []const u8,
    item: *const item_mod.Item,
    item_dir_abs: []const u8,
) Error!void {
    if (!shouldMaterializePrompt(item)) return;
    const rendered = try resolvePrompt(allocator, notes_root_abs, stack_name, item, item_dir_abs);
    defer allocator.free(rendered);
    const path = try std.fs.path.join(allocator, &.{ item_dir_abs, "rendered_prompt.md" });
    defer allocator.free(path);
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(rendered);
}

pub fn resolvePrompt(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack_name: []const u8,
    item: *const item_mod.Item,
    item_dir_abs: []const u8,
) Error![]u8 {
    const base = try readBasePrompt(allocator, item, item_dir_abs);
    defer allocator.free(base);
    if (!hasRegisteredInputs(item)) return renderPrompt(allocator, base, .prepend, &.{});

    var sections = std.ArrayList(InputSection){};
    defer {
        for (sections.items) |*s| s.deinit(allocator);
        sections.deinit(allocator);
    }

    var total_input_bytes: usize = 0;
    const inputs = item.inputs.?;
    if (inputs.items) |ids| {
        for (ids) |id| {
            if (!item_mod.isValidId(id)) return error.ValidationFailed;
            const dir_name = try findItemDir(allocator, notes_root_abs, stack_name, id);
            defer allocator.free(dir_name);
            const source_rel = try std.fmt.allocPrint(allocator, "stacks/{s}/{s}", .{ stack_name, dir_name });
            errdefer allocator.free(source_rel);
            const content = try std.fmt.allocPrint(
                allocator,
                "Use this item as relevant context. Inspect the notes git history for commits touching `{s}` and surrounding commits when the task needs the prior item's output details.\n",
                .{source_rel},
            );
            errdefer allocator.free(content);
            total_input_bytes += content.len;
            if (total_input_bytes > MAX_INPUT_BYTES) return error.InputTooLarge;
            try sections.append(allocator, .{
                .kind = .item,
                .title = try allocator.dupe(u8, id),
                .source = source_rel,
                .content = content,
            });
        }
    }
    if (inputs.files) |paths| {
        for (paths) |path| {
            if (!item_mod.isValidInputFilePath(path)) return error.ValidationFailed;
            const abs = if (std.fs.path.isAbsolute(path))
                try allocator.dupe(u8, path)
            else
                try std.fs.path.join(allocator, &.{ notes_root_abs, path });
            defer allocator.free(abs);
            const content = try readInputFileCapped(allocator, abs, &total_input_bytes);
            errdefer allocator.free(content);
            try sections.append(allocator, .{
                .kind = .file,
                .title = try allocator.dupe(u8, path),
                .source = null,
                .content = content,
            });
        }
    }
    if (inputs.commits) |commits| {
        for (commits) |commit| {
            try sections.append(allocator, .{
                .kind = .commit,
                .title = try allocator.dupe(u8, commit),
                .source = null,
                .content = try allocator.dupe(u8, "Use this commit as relevant context. Inspect the notes/workdir git history for the commit diff and surrounding commits when the task needs those details."),
            });
        }
    }

    return renderPrompt(allocator, base, inputs.mode, sections.items);
}

const SectionKind = enum { item, file, commit };

const InputSection = struct {
    kind: SectionKind,
    title: []u8,
    source: ?[]u8 = null,
    content: []u8,

    fn deinit(self: *InputSection, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.source) |s| allocator.free(s);
        allocator.free(self.content);
    }
};

fn renderPrompt(
    allocator: std.mem.Allocator,
    base: []const u8,
    mode: item_mod.InputMode,
    sections: []const InputSection,
) ![]u8 {
    var inputs_buf = std.ArrayList(u8){};
    defer inputs_buf.deinit(allocator);
    const iw = inputs_buf.writer(allocator);
    if (sections.len > 0) {
        try iw.writeAll("## Registered Inputs\n");
        for (sections) |s| {
            try iw.writeByte('\n');
            switch (s.kind) {
                .item => {
                    try iw.print("### Item {s}\n\n", .{s.title});
                    if (s.source) |src| try iw.print("Source: {s}\n\n", .{src});
                },
                .file => try iw.print("### File {s}\n\n", .{s.title}),
                .commit => try iw.print("### Commit {s}\n\n", .{s.title}),
            }
            try iw.writeAll(s.content);
            if (!std.mem.endsWith(u8, s.content, "\n")) try iw.writeByte('\n');
        }
    }
    const inputs_rendered = try inputs_buf.toOwnedSlice(allocator);
    defer allocator.free(inputs_rendered);

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll(IO_CONTRACT);
    try w.writeAll("---\n\n");
    switch (mode) {
        .append => {
            try w.writeAll(base);
            if (inputs_rendered.len > 0) {
                try w.writeAll("\n\n---\n\n");
                try w.writeAll(inputs_rendered);
            }
        },
        .prepend => {
            if (inputs_rendered.len > 0) {
                try w.writeAll(inputs_rendered);
                try w.writeAll("\n---\n\n");
            }
            try w.writeAll(base);
        },
    }
    return out.toOwnedSlice(allocator);
}

fn readBasePrompt(allocator: std.mem.Allocator, item: *const item_mod.Item, item_dir_abs: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ item_dir_abs, "prompt.md" });
    defer allocator.free(path);
    const content = readWholeFile(allocator, path) catch |e| switch (e) {
        error.FileNotFound => return allocator.dupe(u8, item.slug),
        else => return e,
    };
    if (content.len == 0) {
        allocator.free(content);
        return allocator.dupe(u8, item.slug);
    }
    return content;
}

fn readInputFileCapped(allocator: std.mem.Allocator, abs_path: []const u8, total: *usize) Error![]u8 {
    var f = std.fs.cwd().openFile(abs_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return error.InputMissing,
        else => return e,
    };
    defer f.close();
    const stat = try f.stat();
    if (stat.size > MAX_INPUT_BYTES) return error.InputTooLarge;
    const size: usize = @intCast(stat.size);
    if (total.* + size > MAX_INPUT_BYTES) return error.InputTooLarge;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const n = try f.readAll(buf);
    total.* += n;
    return try allocator.realloc(buf, n);
}

fn readWholeFile(allocator: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(abs_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try f.readAll(buf);
    return try allocator.realloc(buf, n);
}

fn findItemDir(allocator: std.mem.Allocator, notes_root_abs: []const u8, stack_name: []const u8, id: []const u8) Error![]u8 {
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack_name });
    defer allocator.free(stack_abs);
    var d = std.fs.openDirAbsolute(stack_abs, .{ .iterate = true }) catch return error.InputMissing;
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        if (std.mem.eql(u8, entry.name[0..dash], id)) return allocator.dupe(u8, entry.name);
    }
    return error.InputMissing;
}

pub fn renderedPromptRel(allocator: std.mem.Allocator, stack_name: []const u8, dir_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/{s}/rendered_prompt.md", .{ stack_name, dir_name });
}

pub fn renderedPromptExists(allocator: std.mem.Allocator, notes_root_abs: []const u8, stack_name: []const u8, dir_name: []const u8) !bool {
    const rel = try renderedPromptRel(allocator, stack_name, dir_name);
    defer allocator.free(rel);
    const abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rel });
    defer allocator.free(abs);
    var f = std.fs.cwd().openFile(abs, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    f.close();
    return true;
}

test "render prompt appends registered item input" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    try tmp.dir.makePath("stacks/demo/0001-plan");
    try tmp.dir.makePath("stacks/demo/0002-next");
    {
        var f = try tmp.dir.createFile("stacks/demo/0002-next/prompt.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll("base prompt");
    }
    var it = item_mod.Item{
        .arena = std.heap.ArenaAllocator.init(a),
        .id = "0002",
        .slug = "next",
        .kind = .prompt,
        .status = .queued,
        .created_at = "2026-05-10T14:00:00Z",
        .updated_at = "2026-05-10T14:00:00Z",
    };
    defer it.deinit();
    const aa = it.arena.allocator();
    const ids = try aa.alloc([]const u8, 1);
    ids[0] = try aa.dupe(u8, "0001");
    it.inputs = .{ .items = ids };
    const item_dir = try std.fs.path.join(a, &.{ root, "stacks/demo/0002-next" });
    defer a.free(item_dir);
    const rendered = try resolvePrompt(a, root, "demo", &it, item_dir);
    defer a.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, rendered, IO_CONTRACT));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "base prompt\n\n---\n\n## Registered Inputs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Source: stacks/demo/0001-plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "commits touching `stacks/demo/0001-plan`") != null);
}

test "render prompt prepends I/O contract without registered inputs" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/0001-next");
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-next/prompt.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll("base prompt");
    }
    var it = item_mod.Item{
        .arena = std.heap.ArenaAllocator.init(a),
        .id = "0001",
        .slug = "next",
        .kind = .prompt,
        .status = .queued,
        .created_at = "2026-05-10T14:00:00Z",
        .updated_at = "2026-05-10T14:00:00Z",
    };
    defer it.deinit();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    const item_dir = try std.fs.path.join(a, &.{ root, "stacks/demo/0001-next" });
    defer a.free(item_dir);
    const rendered = try resolvePrompt(a, root, "demo", &it, item_dir);
    defer a.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, rendered, IO_CONTRACT));
    try std.testing.expect(std.mem.endsWith(u8, rendered, "base prompt"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "## Registered Inputs") == null);
}

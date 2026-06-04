const std = @import("std");
const toml = @import("toml.zig");

pub const ParseError = error{
    MissingFrontMatter,
    UnterminatedFrontMatter,
    BadType,
    MissingId,
    MissingThread,
    MissingCommand,
    BadAction,
    BadName,
    BadToml,
    OutOfMemory,
} || toml.ParseError;

pub const Action = enum {
    none,
    new,
    clear,
    compact,

    pub fn parse(s: []const u8) ParseError!Action {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "new")) return .new;
        if (std.mem.eql(u8, s, "clear")) return .clear;
        if (std.mem.eql(u8, s, "compact")) return .compact;
        return error.BadAction;
    }

    pub fn command(self: Action) []const u8 {
        return switch (self) {
            .none => "",
            .new => "/new",
            .clear => "/clear",
            .compact => "/compact",
        };
    }
};

pub const StackFile = struct {
    allocator: std.mem.Allocator,
    command: []const u8,
    cwd: []const u8,
    body: []const u8,

    pub fn deinit(self: *StackFile) void {
        self.allocator.free(self.command);
        self.allocator.free(self.cwd);
        self.allocator.free(self.body);
    }
};

pub const ThreadFile = struct {
    allocator: std.mem.Allocator,
    thread: []const u8,
    command: []const u8,
    body: []const u8,

    pub fn deinit(self: *ThreadFile) void {
        self.allocator.free(self.thread);
        self.allocator.free(self.command);
        self.allocator.free(self.body);
    }
};

pub const PromptFile = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    thread: []const u8,
    action: Action,
    after: []const []const u8,
    inputs: []const []const u8,
    body: []const u8,

    pub fn deinit(self: *PromptFile) void {
        self.allocator.free(self.id);
        self.allocator.free(self.thread);
        for (self.after) |dep| self.allocator.free(dep);
        self.allocator.free(self.after);
        for (self.inputs) |input| self.allocator.free(input);
        self.allocator.free(self.inputs);
        self.allocator.free(self.body);
    }
};

pub const InputResult = struct {
    id: []const u8,
    path: []const u8,
};

const Split = struct {
    front: []const u8,
    body: []const u8,
};

fn splitFrontMatter(source: []const u8) ParseError!Split {
    if (!std.mem.startsWith(u8, source, "+++\n") and !std.mem.startsWith(u8, source, "+++\r\n")) {
        return error.MissingFrontMatter;
    }
    const first_end: usize = if (std.mem.startsWith(u8, source, "+++\r\n")) 5 else 4;
    const marker = "\n+++";
    const close_start = std.mem.indexOfPos(u8, source, first_end, marker) orelse return error.UnterminatedFrontMatter;
    var body_start = close_start + marker.len;
    if (body_start < source.len and source[body_start] == '\r') body_start += 1;
    if (body_start < source.len and source[body_start] == '\n') body_start += 1;
    return .{
        .front = source[first_end..close_start],
        .body = source[body_start..],
    };
}

pub fn parseStackFile(allocator: std.mem.Allocator, source: []const u8) ParseError!StackFile {
    const split = try splitFrontMatter(source);
    var doc = try toml.parse(allocator, split.front);
    defer doc.deinit();

    const command = stringField(&doc, "command") orelse "codex";
    if (command.len == 0) return error.MissingCommand;
    const cwd = stringField(&doc, "cwd") orelse "";
    return .{
        .allocator = allocator,
        .command = try allocator.dupe(u8, command),
        .cwd = try allocator.dupe(u8, cwd),
        .body = try allocator.dupe(u8, trimBody(split.body)),
    };
}

pub fn parseThreadFile(allocator: std.mem.Allocator, source: []const u8) ParseError!ThreadFile {
    const split = try splitFrontMatter(source);
    var doc = try toml.parse(allocator, split.front);
    defer doc.deinit();

    const typ = stringField(&doc, "type") orelse return error.BadType;
    if (!std.mem.eql(u8, typ, "thread")) return error.BadType;
    const thread = stringField(&doc, "thread") orelse return error.MissingThread;
    if (!isValidName(thread)) return error.BadName;
    const command = stringField(&doc, "command") orelse "";
    if (doc.find("", "command") != null and command.len == 0) return error.MissingCommand;
    return .{
        .allocator = allocator,
        .thread = try allocator.dupe(u8, thread),
        .command = try allocator.dupe(u8, command),
        .body = try allocator.dupe(u8, trimBody(split.body)),
    };
}

pub fn parsePromptFile(allocator: std.mem.Allocator, source: []const u8) ParseError!PromptFile {
    const split = try splitFrontMatter(source);
    var doc = try toml.parse(allocator, split.front);
    defer doc.deinit();

    const id = stringField(&doc, "id") orelse return error.MissingId;
    const thread = stringField(&doc, "thread") orelse return error.MissingThread;
    if (!isValidName(id) or !isValidName(thread)) return error.BadName;
    const action = try Action.parse(stringField(&doc, "action") orelse "none");
    const deps_src = stringArrayField(&doc, "after") orelse &.{};
    const inputs_src = stringArrayField(&doc, "inputs") orelse &.{};

    var deps: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (deps.items) |dep| allocator.free(dep);
        deps.deinit(allocator);
    }
    for (deps_src) |dep| {
        if (!isValidName(dep)) return error.BadName;
        try deps.append(allocator, try allocator.dupe(u8, dep));
    }

    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (inputs.items) |input| allocator.free(input);
        inputs.deinit(allocator);
    }
    for (inputs_src) |input| {
        if (!isValidName(input)) return error.BadName;
        try inputs.append(allocator, try allocator.dupe(u8, input));
    }

    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .thread = try allocator.dupe(u8, thread),
        .action = action,
        .after = try deps.toOwnedSlice(allocator),
        .inputs = try inputs.toOwnedSlice(allocator),
        .body = try allocator.dupe(u8, trimBody(split.body)),
    };
}

pub fn isValidName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_') continue;
        return false;
    }
    return true;
}

pub fn renderPromptAlloc(
    allocator: std.mem.Allocator,
    stack_body: []const u8,
    thread_body: []const u8,
    prompt_body: []const u8,
    result_path: []const u8,
    completion_path: []const u8,
    inputs: []const InputResult,
) ![]u8 {
    // Caller owns returned memory.
    var input_block: std.ArrayList(u8) = .empty;
    defer input_block.deinit(allocator);
    if (inputs.len != 0) {
        try input_block.appendSlice(allocator,
            \\Input result files from completed prompts:
            \\
        );
        for (inputs) |input| {
            try input_block.appendSlice(allocator, "- ");
            try input_block.appendSlice(allocator, input.id);
            try input_block.appendSlice(allocator, ": ");
            try input_block.appendSlice(allocator, input.path);
            try input_block.append(allocator, '\n');
        }
        try input_block.appendSlice(allocator,
            \\
            \\Read these files before doing the task. These files are the durable handoff content from other threads; do not infer handoff content from zellij pane text.
            \\
            \\
        );
    }

    return std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\{s}
        \\
        \\{s}{s}
        \\
        \\Result file contract:
        \\Write your final durable result to this exact file:
        \\{s}
        \\
        \\The result file must contain only the content that downstream prompts should read. Other threads receive this file path, not the zellij pane contents.
        \\
        \\When the result file has been written and this request is completely finished, create this exact completion marker file:
        \\{s}
        \\
        \\The completion marker can be empty, but it must not exist before the result file is complete.
        \\
    , .{ stack_body, thread_body, input_block.items, prompt_body, result_path, completion_path });
}

fn trimBody(body: []const u8) []const u8 {
    return std.mem.trim(u8, body, " \t\r\n");
}

fn stringField(doc: *const toml.Document, key: []const u8) ?[]const u8 {
    const entry = doc.find("", key) orelse return null;
    return switch (entry.value) {
        .string => |s| s,
        else => null,
    };
}

fn stringArrayField(doc: *const toml.Document, key: []const u8) ?[]const []const u8 {
    const entry = doc.find("", key) orelse return null;
    return switch (entry.value) {
        .string_array => |s| s,
        else => null,
    };
}

test "parse prompt markdown front matter" {
    const src =
        \\+++
        \\id = "implement-api"
        \\thread = "builder"
        \\action = "clear"
        \\after = ["plan-api"]
        \\inputs = ["review-api"]
        \\+++
        \\
        \\Build it.
    ;
    var p = try parsePromptFile(std.testing.allocator, src);
    defer p.deinit();
    try std.testing.expectEqualStrings("implement-api", p.id);
    try std.testing.expectEqualStrings("builder", p.thread);
    try std.testing.expectEqual(Action.clear, p.action);
    try std.testing.expectEqual(@as(usize, 1), p.after.len);
    try std.testing.expectEqualStrings("plan-api", p.after[0]);
    try std.testing.expectEqual(@as(usize, 1), p.inputs.len);
    try std.testing.expectEqualStrings("review-api", p.inputs[0]);
    try std.testing.expectEqualStrings("Build it.", p.body);
}

test "parse stack and thread markdown front matter" {
    var stack = try parseStackFile(std.testing.allocator,
        \\+++
        \\command = "claude"
        \\cwd = "/work/repo"
        \\+++
        \\Stack rules.
    );
    defer stack.deinit();
    try std.testing.expectEqualStrings("claude", stack.command);
    try std.testing.expectEqualStrings("/work/repo", stack.cwd);
    try std.testing.expectEqualStrings("Stack rules.", stack.body);

    var thread = try parseThreadFile(std.testing.allocator,
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\command = "claude"
        \\+++
        \\Thread rules.
    );
    defer thread.deinit();
    try std.testing.expectEqualStrings("builder", thread.thread);
    try std.testing.expectEqualStrings("claude", thread.command);
    try std.testing.expectEqualStrings("Thread rules.", thread.body);
}

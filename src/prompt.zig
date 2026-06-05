//! Prompt rendering: composing the bytes delivered to an agent for one graph
//! node. The graph model and name/action types live in `plan.zig`; this module
//! only assembles body + inputs contract + output contract. The runtime
//! (`runtime.zig`) resolves bodies from disk and supplies absolute paths.

const std = @import("std");

/// One blocker's durable result, rendered into a node's inputs contract: the
/// blocker node name and the absolute path to its `result.md`.
pub const RenderInput = struct {
    node: []const u8,
    path: []const u8,
};

/// Compose the bytes delivered to an agent for one node: the resolved body,
/// then the inputs contract (blocker result paths to read), then the output
/// contract (where to write `result.md` and the `done` marker). The session
/// action is delivered separately by the runtime, so it is not part of these
/// bytes. Paths are absolute because the agent runs in the stack's agent cwd,
/// not the stack directory. Caller owns the result.
pub fn composeAlloc(
    gpa: std.mem.Allocator,
    body: []const u8,
    result_path: []const u8,
    done_path: []const u8,
    inputs: []const RenderInput,
) ![]u8 {
    // Caller owns returned memory.
    var input_block: std.ArrayList(u8) = .empty;
    defer input_block.deinit(gpa);
    if (inputs.len != 0) {
        try input_block.appendSlice(gpa,
            \\Input result files from completed prompts:
            \\
        );
        for (inputs) |input| {
            try input_block.appendSlice(gpa, "- ");
            try input_block.appendSlice(gpa, input.node);
            try input_block.appendSlice(gpa, ": ");
            try input_block.appendSlice(gpa, input.path);
            try input_block.append(gpa, '\n');
        }
        try input_block.appendSlice(gpa,
            \\
            \\Read these files before doing the task. These files are the durable handoff content from other threads; do not infer handoff content from zellij pane text.
            \\
            \\
        );
    }

    return std.fmt.allocPrint(gpa,
        \\{s}
        \\
        \\{s}Result file contract:
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
    , .{ body, input_block.items, result_path, done_path });
}

// ---------- tests ----------

test "composeAlloc folds body, inputs, and output contract" {
    const a = std.testing.allocator;
    const inputs = [_]RenderInput{.{ .node = "impl-1", .path = "/abs/runs/impl-1/result.md" }};
    const out = try composeAlloc(a, "Do the work.", "/abs/runs/n/result.md", "/abs/runs/n/done", &inputs);
    defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "Do the work."));
    try std.testing.expect(std.mem.indexOf(u8, out, "impl-1: /abs/runs/impl-1/result.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/abs/runs/n/result.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/abs/runs/n/done") != null);
}

test "composeAlloc without inputs omits the inputs block" {
    const a = std.testing.allocator;
    const out = try composeAlloc(a, "Body.", "/r/result.md", "/r/done", &.{});
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Input result files") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Result file contract:") != null);
}

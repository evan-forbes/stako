//! Server-rendered HTML for the daemon's browser-facing pages (milestone 9).
//!
//! See `todos/design_web_view.md`. The same daemon process serves both JSON
//! (existing read endpoints) and HTML (these renderers) on the same routes;
//! the daemon's request handler picks one based on the `Accept` header.
//!
//! Pages rendered here:
//!   - `index`       — `/`              : stack list + daemon health.
//!   - `stack`       — `/stacks/<name>` : stack detail with item table.
//!   - `item`        — `/stacks/<name>/items/<id>` : item detail with
//!                                                    transcript snapshot.
//!
//! HTML escaping is funneled through `escape`. Every dynamic insertion of
//! user-controlled text (item ids, slugs, statuses, prompt bodies, transcript
//! contents, error messages, paths) must run through `escape` — there is no
//! `writeRaw` path for dynamic data here. Untrusted-by-default.
//!
//! No SPA, no client bundler. The optional inline script on the item page
//! subscribes to `/stacks/<name>/events` over SSE so the transcript updates
//! live; pages remain useful with JS disabled.

const std = @import("std");
const item_mod = @import("item.zig");
const stack_config = @import("stack_config.zig");
const storage = @import("storage.zig");

/// Escape one byte sequence for safe inclusion in HTML text or attribute
/// values. Escapes `<`, `>`, `&`, `"`, `'`. The same escaper covers both
/// element text and attribute values because we always use double-quoted
/// attributes — single-quote escaping is included for defense in depth.
pub fn escape(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(c),
        }
    }
}

/// Convenience: escape `s` into an allocated buffer. Used by tests; the
/// renderers themselves stream into ArrayList writers.
pub fn escapeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try escape(w, s);
    return buf.toOwnedSlice(allocator);
}

/// Single hand-written stylesheet served from `/static/style.css`. Kept
/// minimal and printable — no CDN, no framework.
pub const STYLE_CSS: []const u8 =
    \\:root {
    \\  --fg: #1a1a1a;
    \\  --bg: #fafafa;
    \\  --muted: #555;
    \\  --border: #ddd;
    \\  --accent: #2a5db0;
    \\  --warn: #b04a2a;
    \\  --ok: #2a8a4a;
    \\}
    \\body {
    \\  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\  color: var(--fg);
    \\  background: var(--bg);
    \\  margin: 0;
    \\  padding: 1.5rem;
    \\  line-height: 1.4;
    \\}
    \\h1, h2, h3 { margin-top: 0; }
    \\a { color: var(--accent); text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\header { border-bottom: 1px solid var(--border); padding-bottom: .5rem; margin-bottom: 1rem; }
    \\nav.crumbs { font-size: .9rem; color: var(--muted); margin-bottom: .25rem; }
    \\table { border-collapse: collapse; width: 100%; margin-bottom: 1rem; }
    \\th, td { text-align: left; padding: .35rem .5rem; border-bottom: 1px solid var(--border); font-size: .92rem; }
    \\th { background: #f0f0f0; font-weight: 600; }
    \\.badge { display: inline-block; padding: .1rem .45rem; border-radius: .25rem; font-size: .8rem; border: 1px solid var(--border); background: #fff; }
    \\.badge.status-queued { background: #f6f6f6; }
    \\.badge.status-running { background: #fff5d6; border-color: #d0b060; }
    \\.badge.status-completed { background: #e6f4e6; border-color: var(--ok); color: var(--ok); }
    \\.badge.status-failed { background: #fde6e6; border-color: var(--warn); color: var(--warn); }
    \\.badge.status-canceled { background: #efe6f4; }
    \\.badge.status-blocked { background: #fde6cc; border-color: var(--warn); }
    \\.badge.status-paused { background: #e6e6f4; }
    \\.badge.status-superseded { background: #ececec; color: var(--muted); }
    \\.kv { margin: 0 0 1rem 0; }
    \\.kv dt { font-weight: 600; color: var(--muted); float: left; clear: left; width: 8rem; }
    \\.kv dd { margin: 0 0 .1rem 8.5rem; }
    \\pre.prompt, pre.transcript-evt { background: #fff; border: 1px solid var(--border); padding: .6rem; overflow-x: auto; white-space: pre-wrap; font-size: .9rem; }
    \\ul.transcript { list-style: none; padding: 0; }
    \\ul.transcript li { margin-bottom: .35rem; }
    \\.transcript-kind { font-weight: 600; color: var(--accent); }
    \\.transcript-ts { color: var(--muted); font-size: .8rem; }
    \\footer { color: var(--muted); font-size: .85rem; margin-top: 2rem; border-top: 1px solid var(--border); padding-top: .5rem; }
    \\section.controls { margin: .5rem 0 1rem 0; }
    \\section.controls form { display: inline-block; margin-right: .5rem; }
    \\section.controls button { padding: .3rem .8rem; font-size: .9rem; border: 1px solid var(--border); background: #fff; color: var(--fg); border-radius: .25rem; cursor: pointer; }
    \\section.controls button:hover { background: #f0f0f0; }
;

/// Page header written by every renderer. `title` is escaped.
fn writeHeader(w: anytype, title: []const u8) !void {
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>");
    try escape(w, title);
    try w.writeAll("</title><link rel=\"stylesheet\" href=\"/static/style.css\"></head><body>");
}

fn writeFooter(w: anytype) !void {
    try w.writeAll("<footer>organo daemon</footer></body></html>");
}

// ---------- page: index ----------

/// Render `/` (daemon home / stack list).
pub fn renderIndex(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    stacks: []const []const u8,
) !void {
    const w = out.writer(allocator);
    try writeHeader(w, "organo");
    try w.writeAll("<header><h1>organo</h1></header>");
    try w.writeAll("<h2>Stacks</h2>");
    if (stacks.len == 0) {
        try w.writeAll("<p><em>No stacks yet. Run <code>organo stack create &lt;name&gt;</code>.</em></p>");
    } else {
        try w.writeAll("<ul>");
        for (stacks) |name| {
            try w.writeAll("<li><a href=\"/stacks/");
            try escape(w, name);
            try w.writeAll("\">");
            try escape(w, name);
            try w.writeAll("</a></li>");
        }
        try w.writeAll("</ul>");
    }
    try writeFooter(w);
}

// ---------- page: stack detail ----------

pub const StackPageInput = struct {
    name: []const u8,
    config: *const stack_config.StackConfig,
    items: []const storage.ItemSummary,
    running_count: usize = 0,
    /// When non-null, render the pause/resume mutation form embedding this
    /// local mutation token as a hidden `_token` field. The token MUST only
    /// be embedded when the request came over the loopback interface — the
    /// caller is responsible for that gate. Pages render without the form
    /// when null (used by snapshot tests and JSON callers).
    local_token: ?[]const u8 = null,
};

/// Render `/stacks/<name>`.
pub fn renderStack(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: StackPageInput,
) !void {
    const w = out.writer(allocator);
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "stack: {s}", .{input.name}) catch input.name;
    try writeHeader(w, title);
    try w.writeAll("<nav class=\"crumbs\"><a href=\"/\">home</a> / stacks / ");
    try escape(w, input.name);
    try w.writeAll("</nav>");
    try w.writeAll("<header><h1>");
    try escape(w, input.name);
    try w.writeAll("</h1></header>");

    // Mutation controls — pause/resume the stack. Rendered only when a
    // local mutation token is supplied (loopback-only path). Plain HTML
    // `<form method="POST">` so the page works without JS; the hidden
    // `_token` field carries the local mutation token end-to-end.
    if (input.local_token) |tok| {
        try writeStackControls(w, input.name, input.config.paused, tok);
    }

    // Config summary.
    try w.writeAll("<h2>Config</h2><dl class=\"kv\">");
    if (input.config.description) |d| {
        try w.writeAll("<dt>description</dt><dd>");
        try escape(w, d);
        try w.writeAll("</dd>");
    }
    try w.writeAll("<dt>paused</dt><dd>");
    try w.writeAll(if (input.config.paused) "<span class=\"badge status-paused\">paused</span>" else "no");
    try w.writeAll("</dd>");
    try w.writeAll("<dt>continuity</dt><dd>");
    try escape(w, input.config.continuity.toString());
    try w.writeAll("</dd>");
    try w.print("<dt>max_concurrent_per_stack</dt><dd>{d}</dd>", .{input.config.max_concurrent_per_stack});
    try w.print("<dt>running</dt><dd>{d}</dd>", .{input.running_count});
    if (input.config.default_workdir) |d| {
        try w.writeAll("<dt>default_workdir</dt><dd>");
        try escape(w, d);
        try w.writeAll("</dd>");
    }
    if (input.config.allowed_harnesses) |arr| {
        try w.writeAll("<dt>allowed_harnesses</dt><dd>");
        for (arr, 0..) |h, i| {
            if (i != 0) try w.writeAll(", ");
            try escape(w, h);
        }
        try w.writeAll("</dd>");
    }
    try w.writeAll("</dl>");

    // Item table.
    try w.writeAll("<h2>Items</h2>");
    if (input.items.len == 0) {
        try w.writeAll("<p><em>No items yet.</em></p>");
    } else {
        try w.writeAll("<table><thead><tr><th>id</th><th>slug</th><th>kind</th><th>status</th></tr></thead><tbody>");
        for (input.items) |it| {
            try w.writeAll("<tr><td><a href=\"/stacks/");
            try escape(w, input.name);
            try w.writeAll("/items/");
            try escape(w, it.id);
            try w.writeAll("\">");
            try escape(w, it.id);
            try w.writeAll("</a></td><td>");
            try escape(w, it.slug);
            try w.writeAll("</td><td>");
            try escape(w, it.kind);
            try w.writeAll("</td><td>");
            try writeStatusBadge(w, it.status);
            try w.writeAll("</td></tr>");
        }
        try w.writeAll("</tbody></table>");
    }
    try writeFooter(w);
}

/// Emit pause/resume controls for a stack. Exactly one button surfaces per
/// page: resume when the stack is paused, pause otherwise. The form posts
/// `application/x-www-form-urlencoded` with a hidden `_token` field — the
/// daemon accepts that as an alternative to `Authorization: Bearer` so
/// vanilla HTML forms work (no JS required).
fn writeStackControls(w: anytype, name: []const u8, paused: bool, token: []const u8) !void {
    try w.writeAll("<section class=\"controls\"><h2>Controls</h2>");
    const action_path: []const u8 = if (paused) "resume" else "pause";
    const button_label: []const u8 = if (paused) "Resume stack" else "Pause stack";
    try w.writeAll("<form method=\"POST\" action=\"/stacks/");
    try escape(w, name);
    try w.writeAll("/");
    try w.writeAll(action_path);
    try w.writeAll("\"><input type=\"hidden\" name=\"_token\" value=\"");
    try escape(w, token);
    try w.writeAll("\"><button type=\"submit\">");
    try w.writeAll(button_label);
    try w.writeAll("</button></form></section>");
}

/// Emit cancel/retry controls for an item. Buttons surface only for
/// statuses where the mutation layer accepts the transition: cancel for
/// queued/paused/blocked, retry for blocked. Statuses outside those sets
/// show no form. See `mutations.applyTransition` for the truth table.
fn writeItemControls(w: anytype, stack: []const u8, id: []const u8, status: []const u8, token: []const u8) !void {
    const show_cancel = std.mem.eql(u8, status, "queued") or
        std.mem.eql(u8, status, "paused") or
        std.mem.eql(u8, status, "blocked");
    const show_retry = std.mem.eql(u8, status, "blocked");
    if (!show_cancel and !show_retry) return;

    try w.writeAll("<section class=\"controls\"><h2>Controls</h2>");
    if (show_cancel) {
        try w.writeAll("<form method=\"POST\" action=\"/stacks/");
        try escape(w, stack);
        try w.writeAll("/items/");
        try escape(w, id);
        try w.writeAll("/cancel\"><input type=\"hidden\" name=\"_token\" value=\"");
        try escape(w, token);
        try w.writeAll("\"><button type=\"submit\">Cancel item</button></form>");
    }
    if (show_retry) {
        try w.writeAll("<form method=\"POST\" action=\"/stacks/");
        try escape(w, stack);
        try w.writeAll("/items/");
        try escape(w, id);
        try w.writeAll("/retry\"><input type=\"hidden\" name=\"_token\" value=\"");
        try escape(w, token);
        try w.writeAll("\"><button type=\"submit\">Retry item</button></form>");
    }
    try w.writeAll("</section>");
}

fn writeStatusBadge(w: anytype, status: []const u8) !void {
    try w.writeAll("<span class=\"badge status-");
    try escape(w, status);
    try w.writeAll("\" data-status>");
    try escape(w, status);
    try w.writeAll("</span>");
}

// ---------- page: item detail ----------

pub const ItemPageInput = struct {
    stack: []const u8,
    item: *const item_mod.Item,
    /// Optional prompt body (already loaded). Null when prompt.md is absent.
    prompt_body: ?[]const u8 = null,
    /// Raw transcript.jsonl bytes; the renderer parses line-by-line. Null
    /// when no transcript exists yet.
    transcript_jsonl: ?[]const u8 = null,
    /// When true, append an inline `<script>` that subscribes to SSE so the
    /// transcript and status badge update live. The script is opt-in so
    /// snapshot tests can render a JS-free page.
    enable_sse: bool = false,
    /// When non-null, render cancel/retry controls embedding this local
    /// mutation token as a hidden `_token` field. Same loopback-only
    /// invariant as `StackPageInput.local_token`.
    local_token: ?[]const u8 = null,
};

pub fn renderItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: ItemPageInput,
) !void {
    const w = out.writer(allocator);
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(
        &title_buf,
        "item: {s} / {s}",
        .{ input.stack, input.item.id },
    ) catch input.item.id;
    try writeHeader(w, title);
    try w.writeAll("<nav class=\"crumbs\"><a href=\"/\">home</a> / stacks / <a href=\"/stacks/");
    try escape(w, input.stack);
    try w.writeAll("\">");
    try escape(w, input.stack);
    try w.writeAll("</a> / items / ");
    try escape(w, input.item.id);
    try w.writeAll("</nav>");
    try w.writeAll("<header><h1>");
    try escape(w, input.item.id);
    try w.writeAll(" — ");
    try escape(w, input.item.slug);
    try w.writeAll("</h1></header>");

    // Meta KV.
    try w.writeAll("<dl class=\"kv\">");
    try w.writeAll("<dt>kind</dt><dd>");
    try escape(w, input.item.kind.toString());
    try w.writeAll("</dd>");
    try w.writeAll("<dt>status</dt><dd>");
    try writeStatusBadge(w, input.item.status.toString());
    try w.writeAll("</dd>");
    try w.writeAll("<dt>created_at</dt><dd>");
    try escape(w, input.item.created_at);
    try w.writeAll("</dd>");
    try w.writeAll("<dt>updated_at</dt><dd>");
    try escape(w, input.item.updated_at);
    try w.writeAll("</dd>");
    if (input.item.parents) |ps| {
        try w.writeAll("<dt>parents</dt><dd>");
        for (ps, 0..) |p, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll("<a href=\"/stacks/");
            try escape(w, input.stack);
            try w.writeAll("/items/");
            try escape(w, p);
            try w.writeAll("\">");
            try escape(w, p);
            try w.writeAll("</a>");
        }
        try w.writeAll("</dd>");
    }
    if (input.item.target) |t| {
        try w.writeAll("<dt>target</dt><dd>");
        var first = true;
        if (t.provider) |p| {
            try w.writeAll("provider=");
            try escape(w, p);
            first = false;
        }
        if (t.model) |m| {
            if (!first) try w.writeAll(", ");
            try w.writeAll("model=");
            try escape(w, m);
            first = false;
        }
        if (t.match) |mm| {
            if (!first) try w.writeAll(", ");
            try w.writeAll("match=");
            try escape(w, mm.toString());
            first = false;
        }
        if (t.workdir) |wd| {
            if (!first) try w.writeAll(", ");
            try w.writeAll("workdir=");
            try escape(w, wd);
        }
        try w.writeAll("</dd>");
    }
    if (input.item.blocked_reason) |r| {
        try w.writeAll("<dt>blocked_reason</dt><dd>");
        try escape(w, r);
        try w.writeAll("</dd>");
    }
    if (input.item.failed_reason) |r| {
        try w.writeAll("<dt>failed_reason</dt><dd>");
        try escape(w, r);
        try w.writeAll("</dd>");
    }
    try w.writeAll("</dl>");

    // Mutation controls — cancel/retry. Rendered only when a local token is
    // supplied (loopback-only path). Plain HTML forms; the hidden `_token`
    // field carries the local mutation token. See `writeItemControls` for
    // the per-status truth table.
    if (input.local_token) |tok| {
        try writeItemControls(w, input.stack, input.item.id, input.item.status.toString(), tok);
    }

    // Prompt body.
    if (input.prompt_body) |body| {
        try w.writeAll("<h2>Prompt</h2><pre class=\"prompt\">");
        try escape(w, body);
        try w.writeAll("</pre>");
    }

    // Transcript snapshot.
    try w.writeAll("<h2>Transcript</h2>");
    if (input.transcript_jsonl) |raw| {
        try renderTranscript(w, raw);
    } else {
        try w.writeAll("<p><em>No transcript yet.</em></p>");
    }

    // Optional SSE wiring. Pages remain useful without this; it just adds
    // live status + transcript updates. The script subscribes to the same
    // stack-level event stream the daemon already exposes (see
    // `design_web_view.md` SSE protocol).
    if (input.enable_sse) {
        try w.writeAll("<script>");
        try w.writeAll(
            \\(function(){
            \\  var es = new EventSource("/stacks/
        );
        try escape(w, input.stack);
        try w.writeAll("/events\");");
        try w.writeAll(
            \\  var transcriptUl = document.querySelector("ul.transcript") || (function(){var u=document.createElement("ul");u.className="transcript";var h=document.querySelectorAll("h2");(h[h.length-1]||document.body).insertAdjacentElement("afterend",u);return u;})();
            \\  var statusEl = document.querySelector("[data-status]");
            \\  var itemId =
        );
        try writeJsStringLiteral(w, input.item.id);
        try w.writeAll(";");
        try w.writeAll(
            \\  es.onmessage = function(ev){
            \\    try {
            \\      var d = JSON.parse(ev.data);
            \\      if (d.item && d.item !== itemId) return;
            \\      if (d.kind === "item_status" && statusEl && d.data && d.data.to) {
            \\        statusEl.textContent = d.data.to;
            \\        statusEl.className = "badge status-" + d.data.to;
            \\      } else {
            \\        var li = document.createElement("li");
            \\        var ks = document.createElement("span"); ks.className = "transcript-kind"; ks.textContent = d.kind;
            \\        var ts = document.createElement("span"); ts.className = "transcript-ts"; ts.textContent = " " + (d.ts||"");
            \\        li.appendChild(ks); li.appendChild(ts);
            \\        transcriptUl.appendChild(li);
            \\      }
            \\    } catch (e) {}
            \\  };
            \\})();
        );
        try w.writeAll("</script>");
    }

    try writeFooter(w);
}

/// Walk transcript.jsonl line by line, render each parseable event as a
/// `<li>` row. Lines that don't parse are skipped (the file may be being
/// appended to while we read), but we surface the skipped count in a
/// trailing `<li>` so a transcript full of malformed lines doesn't render
/// identically to an empty transcript — otherwise a real diagnostic surface
/// would silently disappear behind "No events recorded."
fn renderTranscript(w: anytype, raw: []const u8) !void {
    const events = @import("events.zig");
    try w.writeAll("<ul class=\"transcript\">");
    var count: usize = 0;
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const p = events.parseEvent(line) orelse {
            skipped += 1;
            continue;
        };
        try w.writeAll("<li><span class=\"transcript-kind\">");
        try escape(w, p.kind.toString());
        try w.writeAll("</span> <span class=\"transcript-ts\">");
        try escape(w, p.ts);
        try w.writeAll("</span>");
        // For human-friendly browsing, emit the raw `data` JSON inside a
        // <pre> so users can inspect it. Treat as untrusted: escape it.
        if (p.data_json.len > 0 and !std.mem.eql(u8, p.data_json, "{}")) {
            try w.writeAll("<pre class=\"transcript-evt\">");
            try escape(w, p.data_json);
            try w.writeAll("</pre>");
        }
        try w.writeAll("</li>");
        count += 1;
    }
    if (count == 0 and skipped == 0) {
        try w.writeAll("<li><em>No events recorded.</em></li>");
    } else if (skipped > 0) {
        try w.print(
            "<li class=\"transcript-skipped\"><em>({d} unparseable line{s} skipped)</em></li>",
            .{ skipped, if (skipped == 1) "" else "s" },
        );
    }
    try w.writeAll("</ul>");
}

fn writeJsStringLiteral(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '<' => try w.writeAll("\\u003c"),
        '>' => try w.writeAll("\\u003e"),
        '&' => try w.writeAll("\\u0026"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

/// Return true if the request's `Accept` header prefers HTML over JSON.
/// Missing headers default to JSON for programmatic clients. Media types
/// are matched case-insensitively and basic `q=` weights are honored.
pub fn acceptHeaderWantsHtml(accept_value: ?[]const u8) bool {
    const v = accept_value orelse return false; // default to JSON for programmatic clients with no Accept

    const html = mediaPreference(v, "text/html");
    const json = mediaPreference(v, "application/json");
    if (html) |h| {
        if (json) |j| {
            if (h.q != j.q) return h.q > j.q;
            return h.index < j.index;
        }
        return h.q > 0;
    }
    if (json != null) return false;
    if (mediaPreference(v, "*/*")) |wild| return wild.q > 0;
    return false;
}

const MediaPreference = struct {
    q: u16,
    index: usize,
};

fn mediaPreference(accept_value: []const u8, media_type: []const u8) ?MediaPreference {
    var best: ?MediaPreference = null;
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, accept_value, ',');
    while (it.next()) |raw_part| {
        const part_start = offset;
        offset += raw_part.len + 1;

        const part = std.mem.trim(u8, raw_part, " \t");
        const semi = std.mem.indexOfScalar(u8, part, ';') orelse part.len;
        const media = std.mem.trim(u8, part[0..semi], " \t");
        if (!asciiEqlIgnoreCase(media, media_type)) continue;

        const q = parseAcceptQ(part[semi..]);
        if (best == null or q > best.?.q) {
            best = .{ .q = q, .index = part_start };
        }
    }
    return best;
}

fn parseAcceptQ(params: []const u8) u16 {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (param.len < 2) continue;
        if (param[0] != 'q' and param[0] != 'Q') continue;
        var i: usize = 1;
        while (i < param.len and (param[i] == ' ' or param[i] == '\t')) i += 1;
        if (i >= param.len or param[i] != '=') continue;
        i += 1;
        while (i < param.len and (param[i] == ' ' or param[i] == '\t')) i += 1;
        return parseQThousand(param[i..]);
    }
    return 1000;
}

fn parseQThousand(raw: []const u8) u16 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len == 0) return 0;
    if (s[0] == '0') {
        if (s.len == 1) return 0;
        if (s[1] != '.') return 0;
        var value: u16 = 0;
        var scale: u16 = 100;
        var i: usize = 2;
        while (i < s.len and scale > 0) : (i += 1) {
            if (!std.ascii.isDigit(s[i])) break;
            value += @as(u16, @intCast(s[i] - '0')) * scale;
            scale /= 10;
        }
        return value;
    }
    if (s[0] == '1') return 1000;
    return 0;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// ---------- tests ----------

test "escape: covers <, >, &, \", '" {
    const a = std.testing.allocator;
    const got = try escapeAlloc(a, "<a href=\"x\">'&y'</a>");
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "&lt;a href=&quot;x&quot;&gt;&#39;&amp;y&#39;&lt;/a&gt;",
        got,
    );
}

test "escape: passes through plain ASCII" {
    const a = std.testing.allocator;
    const got = try escapeAlloc(a, "Hello, world. 0001-foo");
    defer a.free(got);
    try std.testing.expectEqualStrings("Hello, world. 0001-foo", got);
}

test "acceptHeaderWantsHtml: explicit json prefers json" {
    try std.testing.expect(!acceptHeaderWantsHtml("application/json"));
    try std.testing.expect(!acceptHeaderWantsHtml("application/json, */*"));
}

test "acceptHeaderWantsHtml: text/html only prefers html" {
    try std.testing.expect(acceptHeaderWantsHtml("text/html"));
    try std.testing.expect(acceptHeaderWantsHtml("text/html, */*"));
}

test "acceptHeaderWantsHtml: missing header defaults to json" {
    try std.testing.expect(!acceptHeaderWantsHtml(null));
}

test "acceptHeaderWantsHtml: browser-shape header prefers html" {
    // Firefox-style header.
    try std.testing.expect(acceptHeaderWantsHtml(
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ));
}

test "acceptHeaderWantsHtml: media types are case-insensitive" {
    try std.testing.expect(acceptHeaderWantsHtml("Text/Html"));
    try std.testing.expect(!acceptHeaderWantsHtml("Application/Json"));
}

test "acceptHeaderWantsHtml: q weights beat ordering" {
    try std.testing.expect(acceptHeaderWantsHtml("application/json;q=0.1, text/html;q=0.9"));
    try std.testing.expect(!acceptHeaderWantsHtml("text/html;q=0.2, application/json;q=0.8"));
    try std.testing.expect(!acceptHeaderWantsHtml("text/html;q=0, application/json"));
}

test "renderIndex: empty stack list" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try renderIndex(a, &out, &.{});
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<title>organo</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "No stacks yet") != null);
}

test "renderIndex: links to each stack" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    const stacks = [_][]const u8{ "smoke", "default" };
    try renderIndex(a, &out, &stacks);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "href=\"/stacks/smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "href=\"/stacks/default\"") != null);
}

test "escape: hostile item slug never breaks out" {
    // A malicious slug that tries to inject markup: the escaper must neuter it.
    const a = std.testing.allocator;
    const evil = "</title><script>alert(1)</script>";
    const got = try escapeAlloc(a, evil);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "&lt;script&gt;") != null);
}

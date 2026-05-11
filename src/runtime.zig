//! Runtime supervisor + per-stack worker loops (milestone 6).
//!
//! Per `todos/design_runtime_loop.md`. The supervisor owns stack discovery,
//! the session manager, the global concurrency limit, and wake-fan-out.
//! Each stack has one event-driven worker loop that owns its order, pause
//! state, sleep-timer wheel, and lowest-id-first dequeue.

const std = @import("std");
const storage = @import("storage.zig");
const item_mod = @import("item.zig");
const stack_config = @import("stack_config.zig");
const state = @import("state.zig");
const session_manager = @import("session_manager.zig");
const mutation_queue = @import("mutation_queue.zig");
const audit = @import("audit.zig");
const sse_mod = @import("sse.zig");
const adapter_mod = @import("adapter.zig");
const fake_adapter = @import("fake_adapter.zig");
const harness_dispatch = @import("harness_dispatch.zig");
const runtime_file = @import("runtime_file.zig");
const provider_status = @import("provider_status.zig");

pub const AdapterFactory = *const fn (allocator: std.mem.Allocator, harness: []const u8) anyerror!?adapter_mod.Adapter;

pub const Dispatch = struct {
    /// Resolve harness name → argv to run. The argv slices are owned by the
    /// caller and freed after spawn. The factory may also choose to not
    /// support a harness, in which case it returns `null` and the routing
    /// preflight blocks the item.
    factory: AdapterFactory,
    /// Build argv for a harness invocation. Caller-allocated; returned
    /// slices are owned and freed by the runtime after spawn.
    build_argv: *const fn (allocator: std.mem.Allocator, harness: []const u8, item: *const item_mod.Item, item_dir_abs: []const u8) anyerror![][]u8,
    /// Optional workdir resolver. When null, falls back to default_workdir
    /// from stack config, then to the notes root.
    resolve_workdir: ?*const fn (allocator: std.mem.Allocator, item: *const item_mod.Item, stack: *const stack_config.StackConfig, notes_root_abs: []const u8) anyerror!?[]u8 = null,
};

pub const Options = struct {
    notes_root_abs: []const u8,
    queue: *mutation_queue.Queue,
    audit_writer: *audit.Writer,
    hub: ?*sse_mod.Hub = null,
    /// Global concurrency cap. Default 8 (matches design default).
    max_concurrent_total: usize = 8,
    /// Pluggable harness dispatch. The fake adapter is the default for
    /// tests; the daemon wires a real Claude/Codex factory in milestone 7.
    dispatch: Dispatch,
    /// Workdir allowlist (`config.toml#workdir.allowlist`). Empty = allow
    /// any path (v1: when not configured, we don't enforce).
    workdir_allowlist: []const []const u8 = &.{},
    /// When true, runtime-loop ticks log to the audit log. Disable in tests
    /// that pin audit-line counts.
    audit_routing: bool = false,
    /// When true (default in production), routing preflight calls
    /// `provider_status.probe` and rejects items routed to a provider
    /// whose binary is missing (`harness_unavailable`) or whose auth
    /// detection comes up empty (`auth_missing`). Tests that wire a
    /// scripted/no-binary dispatch (M6 fake, M7 cat_jsonl) leave this
    /// off so the scripted subprocess actually runs.
    enable_provider_preflight: bool = false,
    /// Optional capability check applied at routing preflight (M10).
    /// Called with the resolved provider slug (e.g. "anthropic"); returns
    /// true to allow dispatch, false to block with `capability_denied`.
    /// When null, the routing layer behaves exactly as in M6–M8 (no
    /// capability check). The daemon installs a closure here that
    /// evaluates `policy.evaluate(local-identity, dispatch_harness, ...)`.
    policy_check_provider: ?*const fn (ctx: ?*anyopaque, provider_slug: []const u8) bool = null,
    policy_check_ctx: ?*anyopaque = null,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    sm: session_manager.Manager,

    mutex: std.Thread.Mutex = .{},
    /// Indexed by stack name.
    workers: std.StringHashMapUnmanaged(*Worker) = .{},

    /// Cache of provider binary-presence + auth-state probes. Populated
    /// lazily on first use and never invalidated for the supervisor's
    /// lifetime. The probe itself is cheap (PATH scan + a couple of
    /// stat()s) but doing it on every tick still adds avoidable syscalls
    /// when a stack has many queued items, so we cache once per process.
    /// Daemon restarts re-probe — that's the documented mechanism for
    /// picking up newly installed provider CLIs (see
    /// `todos/design_execution_harness.md`, "Gemini capability probe").
    status_cache_mu: std.Thread.Mutex = .{},
    status_cache: std.AutoHashMapUnmanaged(provider_status.Provider, provider_status.Status) = .{},

    pub fn init(allocator: std.mem.Allocator, opts: Options) Supervisor {
        var sm = session_manager.Manager.init(allocator, opts.notes_root_abs, opts.hub, opts.audit_writer, opts.queue);
        sm.max_concurrent = opts.max_concurrent_total;
        return .{ .allocator = allocator, .opts = opts, .sm = sm };
    }

    /// Look up the cached provider status, populating the cache if needed.
    pub fn providerStatus(self: *Supervisor, p: provider_status.Provider) provider_status.Status {
        self.status_cache_mu.lock();
        defer self.status_cache_mu.unlock();
        if (self.status_cache.get(p)) |s| return s;
        const s = provider_status.probe(self.allocator, p);
        // Best-effort cache insert; fall through to the un-cached result on
        // OOM (the next tick will retry).
        self.status_cache.put(self.allocator, p, s) catch {};
        return s;
    }

    pub fn deinit(self: *Supervisor) void {
        // Signal all workers to stop, then wait.
        self.requestShutdown();
        self.sm.deinit();
        var it = self.workers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.workers.deinit(self.allocator);
        self.status_cache.deinit(self.allocator);
    }

    pub fn requestShutdown(self: *Supervisor) void {
        self.mutex.lock();
        var it = self.workers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.requestShutdown();
        }
        self.mutex.unlock();
        self.sm.requestShutdown();
    }

    /// Restart-orphan recovery (per design_state_machine.md).
    pub fn reconcileOrphans(self: *Supervisor) !void {
        const orphans = try runtime_file.listAll(self.allocator, self.opts.notes_root_abs);
        defer runtime_file.freeOrphans(self.allocator, orphans);
        for (orphans) |o| {
            // Try to apply the running→failed transition; ignore errors.
            var req = mutation_queue.Request{
                .kind = .{ .runtime_transition = .{
                    .stack = o.stack,
                    .id = o.id,
                    .to = .failed,
                    .failed_reason = "daemon_restart_orphan",
                } },
                .ident = .{ .identity = "system", .api_path = "runtime/restart-sweep" },
            };
            self.opts.queue.submitAndWait(&req);
            if (req.output) |*out| out.deinit();
            // Delete the runtime file regardless of transition success.
            runtime_file.deleteFor(self.allocator, self.opts.notes_root_abs, o.stack, o.id) catch {};
        }
    }

    /// Ensure a worker exists for `stack` and is running.
    pub fn ensureWorker(self: *Supervisor, stack_name: []const u8) !*Worker {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.workers.get(stack_name)) |w| return w;
        const w = try self.allocator.create(Worker);
        errdefer self.allocator.destroy(w);
        w.* = .{
            .allocator = self.allocator,
            .stack = try self.allocator.dupe(u8, stack_name),
            .supervisor = self,
        };
        try self.workers.put(self.allocator, w.stack, w);
        return w;
    }

    /// Discover every stack under `<notes_root>/stacks/` and start a
    /// worker thread for each. Idempotent. Used by the daemon at startup
    /// to bring the runtime online after the audit writer + mutation
    /// queue have stable addresses.
    pub fn startAllWorkers(self: *Supervisor) !void {
        var reader = try storage.Reader.init(self.allocator, self.opts.notes_root_abs);
        defer reader.deinit();
        const names = try reader.listStacks();
        defer reader.freeStackList(names);
        for (names) |n| {
            const w = try self.ensureWorker(n);
            try w.start();
        }
    }

    /// Wake every worker so the next iteration picks up newly mutated
    /// state. Cheap; the daemon calls this after each accepted mutation
    /// so users don't have to wait for the poll interval to elapse.
    pub fn wakeAllWorkers(self: *Supervisor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.workers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.wake();
        }
    }

    /// Run one tick on `stack_name`. Walks the items list in id order,
    /// applies routing preflight, and dispatches eligible items through
    /// the session manager.
    pub fn tickStack(self: *Supervisor, stack_name: []const u8) !void {
        var reader = try storage.Reader.init(self.allocator, self.opts.notes_root_abs);
        defer reader.deinit();

        var cfg = reader.readStackConfig(stack_name) catch return;
        defer cfg.deinit();

        if (cfg.paused) return;

        const items = reader.listItems(stack_name) catch return;
        defer reader.freeItemList(items);

        var running_in_stack: usize = 0;
        for (items) |it| {
            if (std.mem.eql(u8, it.status, "running")) running_in_stack += 1;
        }
        const per_stack_limit: usize = if (cfg.max_concurrent_per_stack < 1) 1 else @intCast(cfg.max_concurrent_per_stack);

        for (items) |it| {
            if (running_in_stack >= per_stack_limit) break;
            if (!std.mem.eql(u8, it.status, "queued")) continue;
            // Fetch full item.
            var item = reader.readItem(stack_name, it.id) catch continue;
            defer item.deinit();

            // Sleep semantics first.
            if (item.kind == .sleep) {
                try self.handleSleepItem(stack_name, &item);
                continue;
            }

            // Routing preflight.
            const decision = try self.routingPreflight(&cfg, &item);
            switch (decision) {
                .blocked => |reason| {
                    var req = mutation_queue.Request{
                        .kind = .{ .runtime_transition = .{
                            .stack = stack_name,
                            .id = it.id,
                            .to = .blocked,
                            .blocked_reason = reason,
                        } },
                        .ident = .{ .identity = "system", .api_path = "runtime/preflight" },
                    };
                    self.opts.queue.submitAndWait(&req);
                    if (req.output) |*o| o.deinit();
                },
                .proceed => |proceed| {
                    try self.dispatchItem(stack_name, &cfg, &item, proceed);
                    running_in_stack += 1;
                },
            }
        }
    }

    fn handleSleepItem(self: *Supervisor, stack_name: []const u8, item: *const item_mod.Item) !void {
        const until = if (item.sleep) |s| s.until else return;
        const now_unix = std.time.timestamp();
        const until_unix = parseRfc3339ToUnix(until) orelse now_unix; // Bad → treat as now.
        // To keep this milestone simple: if elapsed, transition directly to
        // completed; otherwise leave queued (a real timer wheel lands in M9
        // backlog work).
        if (until_unix <= now_unix) {
            var req = mutation_queue.Request{
                .kind = .{ .runtime_transition = .{
                    .stack = stack_name,
                    .id = item.id,
                    .to = .running,
                } },
                .ident = .{ .identity = "system", .api_path = "runtime/sleep" },
            };
            self.opts.queue.submitAndWait(&req);
            if (req.output) |*o| o.deinit();

            var req2 = mutation_queue.Request{
                .kind = .{ .runtime_transition = .{
                    .stack = stack_name,
                    .id = item.id,
                    .to = .completed,
                } },
                .ident = .{ .identity = "system", .api_path = "runtime/sleep" },
            };
            self.opts.queue.submitAndWait(&req2);
            if (req2.output) |*o| o.deinit();
        }
        // Future-dated sleep items remain queued; the loop will re-evaluate
        // on the next tick. (Per design, paused-with-timer is the eventual
        // implementation; v1 uses the simpler "leave queued" path.)
    }

    pub const PreflightDecision = union(enum) {
        proceed: ProceedInfo,
        blocked: []const u8, // canonical reason slug
    };

    pub const ProceedInfo = struct {
        harness: []const u8,
        cwd: ?[]const u8 = null,
    };

    fn routingPreflight(self: *Supervisor, cfg: *const stack_config.StackConfig, item: *const item_mod.Item) !PreflightDecision {
        // Resolve harness.
        //
        // v1 routing precedence:
        //   1. `item.target.provider` is mapped to a harness name (e.g.
        //      "anthropic" → "claude", "openai" → "codex"). If that name
        //      is in `allowed_harnesses` (or no allowlist is set), it
        //      wins.
        //   2. Otherwise, the first allowed harness on the stack is used.
        //   3. Otherwise (no allowlist), default to "fake" (test-friendly).
        //
        // An empty allowlist (`[]`) always blocks with `harness_denied`,
        // matching the M6 contract.
        var harness_name: []const u8 = "fake";
        if (cfg.allowed_harnesses) |list| {
            if (list.len == 0) return .{ .blocked = "harness_denied" };
            harness_name = list[0];
        }
        // Item-level provider preference.
        if (item.target) |t| {
            if (t.provider) |p| {
                if (harness_dispatch.providerToHarness(p)) |mapped| {
                    if (cfg.allowed_harnesses) |list| {
                        var ok = false;
                        for (list) |h| if (std.mem.eql(u8, h, mapped)) {
                            ok = true;
                            break;
                        };
                        if (ok) harness_name = mapped else {
                            // Item asked for a specific provider but the
                            // stack denies it. Block, don't silently fall
                            // back to a different harness.
                            return .{ .blocked = "harness_denied" };
                        }
                    } else {
                        harness_name = mapped;
                    }
                }
            }
        }
        // Stack-level allowed_harnesses check (redundant with the above for
        // v1; explicit so future per-item harness override has a hook).
        if (cfg.allowed_harnesses) |list| {
            var ok = false;
            for (list) |h| if (std.mem.eql(u8, h, harness_name)) {
                ok = true;
                break;
            };
            if (!ok) return .{ .blocked = "harness_denied" };
        }

        // Workdir allowlist.
        var workdir_opt: ?[]const u8 = null;
        if (item.target) |t| workdir_opt = t.workdir;
        if (workdir_opt == null) workdir_opt = cfg.default_workdir;
        if (workdir_opt) |wd| {
            if (self.opts.workdir_allowlist.len > 0) {
                var ok = false;
                for (self.opts.workdir_allowlist) |allowed| {
                    if (std.mem.startsWith(u8, wd, allowed)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) return .{ .blocked = "workdir_denied" };
            }
        }

        // Harness availability (the adapter factory must accept it).
        const probe = self.opts.dispatch.factory(self.allocator, harness_name) catch null;
        if (probe == null) return .{ .blocked = "harness_unavailable" };
        if (probe) |p| p.deinit(self.allocator);

        // Per-provider preflight: binary-presence + auth-state checks.
        // Only runs when (a) the supervisor is configured to enforce it
        // and (b) the harness maps to a known provider. Tests that use
        // the "fake" harness or scripted cat_jsonl dispatch leave this
        // disabled so the scripted subprocess actually runs without the
        // host needing the real provider binary installed.
        if (self.opts.enable_provider_preflight) {
            if (harness_dispatch.harnessToProvider(harness_name)) |provider| {
                const status = self.providerStatus(provider);
                // Binary-presence is mandatory — even a signed-in but
                // CLI-less host can't spawn the subprocess.
                if (!status.binary_present) return .{ .blocked = "harness_unavailable" };
                // Adapter-disabled providers (Gemini in v1) advertise this
                // via `available=false`. Same canonical slug for clarity.
                if (!status.available) return .{ .blocked = "harness_unavailable" };
                // Auth state is best-effort: when we can detect "no
                // credentials anywhere", surface `auth_missing` so the UI
                // can prompt the user instead of failing inside a
                // subprocess. `unknown` is treated as "go ahead and try".
                if (status.auth == .signed_out) return .{ .blocked = "auth_missing" };
            }
        }

        // Capability policy on the routed provider (M10). The check
        // applies whether or not provider_preflight is enabled so test
        // suites that use the "fake" harness still exercise the policy
        // path — `harnessToProvider("fake")` is None, so the check is a
        // no-op for that harness.
        if (self.opts.policy_check_provider) |check| {
            if (harness_dispatch.harnessToProvider(harness_name)) |provider| {
                const slug = switch (provider) {
                    .anthropic => "anthropic",
                    .openai => "openai",
                    .google => "google",
                };
                if (!check(self.opts.policy_check_ctx, slug)) {
                    return .{ .blocked = "capability_denied" };
                }
            }
        }

        return .{ .proceed = .{ .harness = harness_name, .cwd = workdir_opt } };
    }

    fn dispatchItem(
        self: *Supervisor,
        stack_name: []const u8,
        cfg: *const stack_config.StackConfig,
        item: *const item_mod.Item,
        proceed: ProceedInfo,
    ) !void {
        _ = cfg;
        // Build the adapter instance for this run.
        const adapter = (try self.opts.dispatch.factory(self.allocator, proceed.harness)) orelse return;
        errdefer adapter.deinit(self.allocator);

        // Resolve item directory.
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ item.id, item.slug });
        defer self.allocator.free(dir_name);
        const item_dir_abs = try std.fs.path.join(self.allocator, &.{ self.opts.notes_root_abs, "stacks", stack_name, dir_name });
        defer self.allocator.free(item_dir_abs);

        // Build argv.
        const argv_owned = try self.opts.dispatch.build_argv(self.allocator, proceed.harness, item, item_dir_abs);
        defer {
            for (argv_owned) |a| self.allocator.free(a);
            self.allocator.free(argv_owned);
        }
        const argv_const: [][]const u8 = @ptrCast(argv_owned);

        _ = self.sm.spawn(.{
            .stack = stack_name,
            .item_id = item.id,
            .item_dir_abs = item_dir_abs,
            .harness = proceed.harness,
            .argv = argv_const,
            .cwd = proceed.cwd,
            .adapter = adapter,
        }) catch |e| {
            // Spawn failed → record as failed.
            var req = mutation_queue.Request{
                .kind = .{ .runtime_transition = .{
                    .stack = stack_name,
                    .id = item.id,
                    .to = .failed,
                    .failed_reason = "spawn_failed",
                } },
                .ident = .{ .identity = "system", .api_path = "runtime/spawn" },
            };
            self.opts.queue.submitAndWait(&req);
            if (req.output) |*o| o.deinit();
            return e;
        };
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    stack: []u8,
    supervisor: *Supervisor,
    mutex: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    wake_pending: bool = false,
    shutdown: bool = false,
    thread: ?std.Thread = null,
    /// Poll interval when idle. The worker re-ticks at this cadence so
    /// items appended via the mutation queue (which doesn't yet wake
    /// workers explicitly) make forward progress. Tests can override by
    /// calling `wake()` to drive a tick immediately.
    poll_interval_ns: u64 = 100 * std.time.ns_per_ms,

    pub fn deinit(self: *Worker) void {
        self.requestShutdown();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.allocator.free(self.stack);
    }

    pub fn requestShutdown(self: *Worker) void {
        self.mutex.lock();
        self.shutdown = true;
        self.cv.broadcast();
        self.mutex.unlock();
    }

    pub fn wake(self: *Worker) void {
        self.mutex.lock();
        self.wake_pending = true;
        self.cv.signal();
        self.mutex.unlock();
    }

    pub fn start(self: *Worker) !void {
        if (self.thread != null) return;
        // Prime an initial tick so a stack that already has work picks it
        // up without waiting for the first poll interval.
        self.wake_pending = true;
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    fn workerMain(self: *Worker) void {
        while (true) {
            self.mutex.lock();
            // Wait until either: shutdown, a wake, or the poll interval
            // elapses. The timed wait keeps the worker live for items
            // added via the mutation queue (which doesn't yet wake us
            // directly).
            while (!self.wake_pending and !self.shutdown) {
                self.cv.timedWait(&self.mutex, self.poll_interval_ns) catch break;
            }
            if (self.shutdown) {
                self.mutex.unlock();
                return;
            }
            self.wake_pending = false;
            self.mutex.unlock();
            self.supervisor.tickStack(self.stack) catch {};
        }
    }
};

/// Default `Dispatch` implementation that always returns the fake adapter
/// for any harness name. Used by tests; production wires a real factory.
pub fn fakeDispatch() Dispatch {
    return .{
        .factory = fakeFactory,
        .build_argv = fakeBuildArgv,
    };
}

fn fakeFactory(allocator: std.mem.Allocator, harness: []const u8) anyerror!?adapter_mod.Adapter {
    _ = harness;
    return try fake_adapter.create(allocator);
}

fn fakeBuildArgv(allocator: std.mem.Allocator, harness: []const u8, item: *const item_mod.Item, item_dir_abs: []const u8) anyerror![][]u8 {
    _ = harness;
    _ = item;
    _ = item_dir_abs;
    // Default: a no-op argv. Tests override.
    var out = try allocator.alloc([]u8, 1);
    out[0] = try allocator.dupe(u8, "/usr/bin/true");
    return out;
}

/// Crude RFC3339 → Unix seconds. Supports YYYY-MM-DDTHH:MM:SS(.fff)?(Z|±HH:MM).
fn parseRfc3339ToUnix(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    if (s[13] != ':') return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    if (s[16] != ':') return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;

    var tz_off: i64 = 0;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i >= s.len) return null;
    if (s[i] == 'Z' or s[i] == 'z') {
        // ok
    } else if (s[i] == '+' or s[i] == '-') {
        if (i + 6 > s.len) return null;
        const sign: i64 = if (s[i] == '+') 1 else -1;
        const oh = std.fmt.parseInt(i64, s[i + 1 .. i + 3], 10) catch return null;
        const om = std.fmt.parseInt(i64, s[i + 4 .. i + 6], 10) catch return null;
        tz_off = sign * (oh * 3600 + om * 60);
    } else return null;

    // Days since civil epoch (Hinnant).
    var y_adj = y;
    var mo_adj = mo;
    if (mo_adj <= 2) {
        y_adj -= 1;
        mo_adj += 12;
    }
    const era = @divFloor(y_adj, 400);
    const yoe = y_adj - era * 400;
    const doy = @divFloor(153 * (mo_adj - 3) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const z = era * 146097 + doe - 719468;
    const unix = z * 86400 + hh * 3600 + mm * 60 + ss - tz_off;
    return unix;
}

// ---------- tests ----------

test "parseRfc3339ToUnix: epoch and known date" {
    try std.testing.expectEqual(@as(?i64, 0), parseRfc3339ToUnix("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1746878400), parseRfc3339ToUnix("2025-05-10T12:00:00Z"));
}

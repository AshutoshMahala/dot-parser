//! Optional post-expansion stage sharing the original operation's work and
//! memory accounts. No new work/state is instantiated by ordinary materialization.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const choices = @import("materialization_options.zig");
const rows = @import("adjacency_rows.zig");
const views = @import("adjacency.zig");
const storage = @import("materialization_storage.zig");
const q = @import("query_storage.zig");
const engine = @import("materialization_session.zig");

pub fn FixedResult(comptime Graph: type, comptime selection: choices.Selection) type {
    return struct {
        materialized: ?views.Result(Graph, selection) = null,
        outcome: engine.Outcome,
        shortfall: ?@import("fixed_storage.zig").StorageShortfall = null,
        scratch_peak: storage.ScratchCapacities = .{},
    };
}
fn baseResult(comptime Graph: type, comptime attributes: bool) type {
    return if (attributes) Graph.Materialized else if (@hasField(Graph, "_coverage")) Graph.MaterializedTopology else t.MaterializedTopology;
}
fn wrapBase(comptime Graph: type, comptime attributes: bool, graph: *const Graph, data: anytype) baseResult(Graph, attributes) {
    return if (@hasField(Graph, "_coverage")) .{ .graph = graph, ._data = data, .edges = data.edges, .peak_bytes = data.peak_bytes } else data;
}

pub fn direct(comptime Graph: type, comptime selection: choices.Selection, graph: *const Graph, options: r.Options) r.Error!views.Result(Graph, selection) {
    const result = if (selection.attributes and q.data(graph).has_ports)
        run(Graph, selection, true, false, graph, {}, options)
    else
        run(Graph, selection, false, false, graph, {}, options);
    if (result.outcome == .failure) return result.outcome.failure;
    return result.materialized.?;
}
pub fn directIn(comptime Graph: type, comptime selection: choices.Selection, graph: *const Graph, memory: storage.MemoryFor(selection), options: r.Options) FixedResult(Graph, selection) {
    return if (selection.attributes and q.data(graph).has_ports)
        run(Graph, selection, true, true, graph, memory, options)
    else
        run(Graph, selection, false, true, graph, memory, options);
}
fn run(comptime Graph: type, comptime selection: choices.Selection, comptime ports: bool, comptime fixed: bool, graph: *const Graph, memory: if (fixed) storage.MemoryFor(selection) else void, options: r.Options) FixedResult(Graph, selection) {
    const g = q.data(graph);
    const Core = @TypeOf(g.*);
    const Operation = if (fixed) @import("edges.zig").FixedMaterializer(Core, selection.attributes, ports) else if (selection.attributes) @import("edges.zig").AttributeMaterializer(Core, ports) else @import("edges.zig").Iterator(Core, true);
    var result: FixedResult(Graph, selection) = .{ .outcome = .success };
    if (fixed) if (options.cancellation) |c| if (c.requested()) return .{ .outcome = .{ .failure = error.Cancelled } };
    const prepared = if (fixed) storage.prepare(selection, memory, graph, options.limits orelse g.limits) catch |err| return .{ .outcome = .{ .failure = err } } else {};
    var operation = (if (fixed) Operation.initInOwner(g, prepared.core, .{ .limits = options.limits }, graph) else Operation.init(g, options)) catch |err| return .{ .outcome = .{ .failure = err } };
    defer operation.deinit();
    if (fixed) {
        operation.memory.peak = prepared.reserved;
        operation.work.cancellation = options.cancellation;
    }
    var builder: rows.Builder = .{};
    defer if (!fixed) builder.rows.deinit(operation.memory.allocator());
    finish(selection, ports, fixed, &operation, &builder, if (fixed) prepared.pools else null) catch |err| {
        result.outcome = .{ .failure = operation.memory.failure(err) };
    };
    if (fixed) {
        result.shortfall = builder.shortfall orelse operation.shortfall();
        result.scratch_peak = operation.scratchPeak();
    }
    if (result.outcome == .failure) return result;
    const Base = if (selection.attributes) Core.Materialized else t.MaterializedTopology;
    const data: Base = if (selection.attributes) .{
        .graph = g,
        .folded = operation.folded.transfer(),
        .edges = operation.stored.items,
        ._ownership = if (fixed) .{ .borrowed = operation.memory.output } else .{ .allocated = .{ .allocator = g.allocator, .capacity = operation.stored.capacity } },
        .peak_bytes = operation.peakBytes(),
    } else .{
        .edges = operation.stored.items,
        ._ownership = if (fixed) .{ .borrowed = operation.memory.output } else .{ .allocated = .{ .allocator = g.allocator, .capacity = operation.stored.capacity } },
        .peak_bytes = operation.peakBytes(),
    };
    operation.stored = .empty;
    if (selection.attributes) operation.folded = .{ .limit = 0 };
    result.materialized = .{ .graph = graph, .base = wrapBase(Graph, selection.attributes, graph, data), .edges = data.edges, .peak_bytes = data.peak_bytes, .index = builder.take(), .borrowed = if (fixed) prepared.output else null };
    return result;
}
fn finish(comptime selection: choices.Selection, comptime ports: bool, comptime fixed: bool, operation: anytype, builder: *rows.Builder, pools: ?rows.Pools) r.Error!void {
    _ = try operation.next();
    if (selection.attributes) try @import("materialized_attributes.zig").finishCatalog(ports, operation);
    while (builder.phase != .done) {
        if (operation.work.cancellation == null and operation.work.remaining > 1) {
            const consumed = builder.consume(selection.adjacency, operation.stored.items, @intCast(operation.graph.nodes.len), @intCast(@min(operation.work.remaining, std.math.maxInt(u32))));
            operation.work.remaining -= consumed.used;
            if (consumed.failure) |err| return err;
            if (consumed.used != 0) continue;
        }
        try operation.work.spend(1);
        try builder.step(selection.adjacency, operation.stored.items, @intCast(operation.graph.nodes.len), if (fixed) undefined else operation.memory.allocator(), pools);
    }
}

pub fn Session(comptime Graph: type, comptime selection: choices.Selection, comptime fixed: bool) type {
    const Core = if (@hasField(Graph, "_coverage")) @FieldType(Graph, "_data") else Graph;
    const Base = if (fixed) Core.FixedMaterializationSession(.{ .attributes = selection.attributes }) else Core.MaterializationSession(.{ .attributes = selection.attributes });
    return struct {
        const Self = @This();
        pub const Result = views.Result(Graph, selection);
        pub const SessionProgress = engine.Progress;
        graph: *const Graph,
        base: Base,
        rows: rows.Builder = .{},
        prepared: if (fixed) storage.Prepared(selection) else void,
        outcome: ?engine.Outcome = null,
        taken: bool = false,

        pub fn init(graph: *const Graph, options: r.Options) r.Error!Self {
            return .{ .graph = graph, .base = try Base.init(q.data(graph), options), .prepared = {} };
        }
        pub fn initIn(graph: *const Graph, memory: storage.MemoryFor(selection), options: r.Options) r.Error!Self {
            if (options.cancellation) |c| if (c.requested()) return error.Cancelled;
            const prepared = try storage.prepare(selection, memory, graph, options.limits orelse q.data(graph).limits);
            var base = try Base.initInOwner(q.data(graph), prepared.core, .{ .limits = options.limits }, graph);
            base.cancellation = options.cancellation;
            base.memory.peak = prepared.reserved;
            return .{ .graph = graph, .base = base, .prepared = prepared };
        }
        pub fn deinit(self: *Self) void {
            if (!fixed) self.rows.rows.deinit(self.base.memory.allocator());
            self.base.deinit();
            self.* = undefined;
        }
        pub fn cancel(self: *Self) void {
            if (self.outcome == null) {
                self.outcome = .{ .failure = error.Cancelled };
                self.base.cancel();
            }
        }
        pub fn peakBytes(self: *const Self) usize {
            return self.base.peakBytes();
        }
        pub fn shortfall(self: *const Self) ?@import("fixed_storage.zig").StorageShortfall {
            if (!fixed) @compileError("shortfall requires fixed materialization");
            return self.rows.shortfall orelse self.base.shortfall();
        }
        pub fn scratchPeak(self: *const Self) storage.ScratchCapacities {
            if (!fixed) @compileError("scratchPeak requires fixed materialization");
            return self.base.scratchPeak();
        }
        fn progress(self: *const Self, used: u32) engine.Progress {
            return .{ .work_used = used, .total_work = self.base.total_work, .pairs_visited = self.base.visited, .edges_created = if (self.taken) self.base.target else @intCast(self.base.stored.items.len), .outcome = self.outcome };
        }
        fn poll(self: *Self) bool {
            if (self.base.cancellation) |c| if (c.requested()) {
                self.outcome = .{ .failure = error.Cancelled };
                return false;
            };
            // A predicate may call cancel() and return false. Explicit stops
            // still latch before another transition or successful publication.
            return self.outcome == null;
        }
        pub fn advance(self: *Self, budget: u32) engine.Progress {
            if (self.outcome != null) return self.progress(0);
            const before = self.base.total_work;
            var used: u32 = 0;
            if (self.base.outcome == null) {
                const p = self.base.advance(budget);
                used = p.work_used;
                if (p.outcome) |outcome| {
                    if (outcome == .failure) self.outcome = outcome;
                } else return self.progress(used);
                if (self.outcome != null) return self.progress(used);
            } else if (budget == 0) {
                _ = self.poll();
                return self.progress(0);
            }
            while (used < budget) {
                if (self.base.cancellation == null) {
                    const grant: u32 = @intCast(@min(budget - used, self.base.limits.max_work - self.base.total_work));
                    if (grant > 1) {
                        const consumed = self.rows.consume(selection.adjacency, self.base.stored.items, @intCast(q.data(self.graph).nodes.len), grant);
                        self.base.total_work += consumed.used;
                        used += consumed.used;
                        if (consumed.failure) |err| {
                            self.outcome = .{ .failure = err };
                            break;
                        }
                        if (consumed.used != 0) continue;
                    }
                }
                if (!self.poll()) break;
                if (self.base.total_work == self.base.limits.max_work) {
                    self.outcome = .{ .failure = error.WorkLimit };
                    break;
                }
                self.base.total_work += 1;
                used += 1;
                self.rows.step(selection.adjacency, self.base.stored.items, @intCast(q.data(self.graph).nodes.len), if (fixed) undefined else self.base.memory.allocator(), if (fixed) self.prepared.pools else null) catch |err| {
                    self.outcome = .{ .failure = self.base.memory.failure(err) };
                    break;
                };
                if (self.rows.phase == .done) {
                    self.outcome = .success;
                    break;
                }
            }
            return self.progress(@intCast(self.base.total_work - before));
        }
        pub fn run(self: *Self) engine.Progress {
            while (true) {
                const p = self.advance(std.math.maxInt(u32));
                if (p.outcome != null) return p;
            }
        }
        pub fn takeResult(self: *Self) engine.TakeError!Result {
            if (self.taken) return error.AlreadyTaken;
            const outcome = self.outcome orelse return error.NotReady;
            if (outcome == .failure) return outcome.failure;
            const data = try self.base.takeResult();
            self.taken = true;
            return .{ .graph = self.graph, .base = wrapBase(Graph, selection.attributes, self.graph, data), .edges = data.edges, .peak_bytes = self.peakBytes(), .index = self.rows.take(), .borrowed = if (fixed) self.prepared.output else null };
        }
    };
}

//! Fixed materialization boundary. Expansion/folding remain in the existing
//! specialized direct engine; sessions use the existing bounded machine.
const storage = @import("materialization_storage.zig");
const query = @import("query_storage.zig");
const r = @import("resources.zig");
const fixed = @import("fixed_storage.zig");
const session = @import("materialization_session.zig");

pub fn Result(comptime Graph: type, comptime attributes: bool) type {
    if (attributes) @import("representation.zig").requireAttributes(Graph.capabilities.attributes);
    return struct {
        materialized: ?(if (attributes) Graph.Materialized else if (@hasField(Graph, "_data")) Graph.MaterializedTopology else @import("topology.zig").MaterializedTopology) = null,
        outcome: session.Outcome,
        shortfall: ?fixed.StorageShortfall = null,
        scratch_peak: storage.ScratchCapacities = .{},
    };
}
pub fn direct(comptime Graph: type, comptime attributes: bool, graph: *const Graph, memory: storage.Memory(attributes), options: r.Options) Result(Graph, attributes) {
    const g = query.data(graph);
    if (!attributes) return run(Graph, false, false, graph, memory, options);
    return if (g.has_ports) run(Graph, true, true, graph, memory, options) else run(Graph, true, false, graph, memory, options);
}
fn run(comptime Graph: type, comptime attributes: bool, comptime with_ports: bool, graph: *const Graph, memory: storage.Memory(attributes), options: r.Options) Result(Graph, attributes) {
    const g = query.data(graph);
    const Core = @TypeOf(g.*);
    var result: Result(Graph, attributes) = .{ .outcome = .success };
    var operation = @import("edges.zig").FixedMaterializer(Core, attributes, with_ports).initInOwner(g, memory, options, graph) catch |err| {
        result.outcome = .{ .failure = err };
        return result;
    };
    defer operation.deinit();
    finish(attributes, with_ports, &operation) catch |err| {
        result.outcome = .{ .failure = err };
    };
    result.shortfall = operation.shortfall();
    result.scratch_peak = operation.scratchPeak();
    if (result.outcome == .failure) return result;
    const Materialized = if (attributes) Core.Materialized else @import("topology.zig").MaterializedTopology;
    const data: Materialized = if (attributes) .{
        .graph = g,
        .folded = operation.folded.transfer(),
        .edges = operation.stored.items,
        ._ownership = .{ .borrowed = operation.memory.output },
        .peak_bytes = operation.peakBytes(),
    } else .{
        .edges = operation.stored.items,
        ._ownership = .{ .borrowed = operation.memory.output },
        .peak_bytes = operation.peakBytes(),
    };
    result.materialized = if (@hasField(Graph, "_data")) .{ .graph = graph, ._data = data, .edges = data.edges, .peak_bytes = data.peak_bytes } else data;
    return result;
}
fn finish(comptime attributes: bool, comptime with_ports: bool, operation: anytype) r.Error!void {
    _ = try operation.next();
    if (attributes) try @import("materialized_attributes.zig").finishCatalog(with_ports, operation);
}

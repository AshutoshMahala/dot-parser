//! Policy-bound, pull-style projection of bounded expansion. No retained output
//! array, attribute folding or callback queue. Views borrow the original IR.
const std = @import("std");
const execution = @import("execution_policy.zig");
const expansion = @import("materialization_session.zig");
const r = @import("resources.zig");
const encoding = @import("parser_support").encoding;

pub fn Bound(comptime Graph: type, comptime caps: encoding.Capabilities, comptime config: anytype) type {
    const partial = @hasField(Graph, "_data");
    const Data = if (partial) @FieldType(Graph, "_data") else Graph;
    const baseline = comptime execution.resolve(.{}, config.policy);
    const Core = expansion.Streaming(Data, caps, if (config.runtime_policy) null else baseline);
    const Hook = if (config.runtime_policy or baseline.cancellation) ?r.Cancellation else void;
    return struct {
        const Self = @This();
        pub const Progress = struct {
            work_used: u32,
            total_work: u64,
            pairs_visited: u64,
            edges_emitted: u32,
            /// At most one edge, delivered once. Null is NOT exhaustion: only
            /// outcome.success proves enumeration of the retained IR finished.
            edge: ?Graph.EdgeView,
            outcome: ?expansion.Outcome,
        };
        pub const Options = struct {
            limits: ?r.Limits = null,
            cancellation: Hook = if (Hook == void) {} else null,
            policy: if (config.runtime_policy) execution.Policy else void = if (config.runtime_policy) .{} else {},
        };
        graph: *const Graph,
        core: Core,
        effective: if (config.runtime_policy) execution.Effective else void,

        pub fn init(graph: *const Graph, options: anytype) !Self {
            comptime for (std.meta.fieldNames(@TypeOf(options))) |field| {
                if (!std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation") and !(config.runtime_policy and std.mem.eql(u8, field, "policy")))
                    @compileError("unknown IR edge session option: " ++ field);
            };
            const normalized = execution.option(Options, options);
            const effective = if (config.runtime_policy) execution.resolve(baseline, normalized.policy) else baseline;
            if (config.runtime_policy) try execution.validate(effective);
            const hook = if (Hook == void) null else if (effective.cancellation) normalized.cancellation else null;
            const data = if (partial) &graph._data else graph;
            var core = try Core.init(data, .{ .limits = normalized.limits, .cancellation = hook });
            if (config.runtime_policy or baseline.cancellation) core.taken.interval = effective.cancellation_interval;
            return .{ .graph = graph, .core = core, .effective = if (config.runtime_policy) effective else {} };
        }
        inline fn project(self: *const Self, p: expansion.StreamProgress) Progress {
            return .{
                .work_used = p.work_used,
                .total_work = p.total_work,
                .pairs_visited = p.pairs_visited,
                .edges_emitted = p.edges_emitted,
                .edge = if (p.edge) |edge| .{ .graph = self.graph, .edge = edge } else null,
                .outcome = p.outcome,
            };
        }
        pub inline fn advance(self: *Self, budget: u32) (if (config.runtime_policy) execution.Error!Progress else Progress) {
            if (config.runtime_policy) {
                if (!self.effective.metering) return error.MeteringDisabled;
            } else if (!baseline.metering) @compileError("metering is disabled; use run()");
            return self.project(self.core.advance(budget));
        }
        /// Run until the next edge or terminal outcome, never discard edges.
        /// Attribute access on that edge is a separate operation/budget.
        pub fn run(self: *Self) Progress {
            return self.project(self.core.run());
        }
        pub fn cancel(self: *Self) void {
            self.core.cancel();
        }
        pub fn peakBytes(self: *const Self) usize {
            return self.core.peakBytes();
        }
        pub fn deinit(self: *Self) void {
            self.core.deinit();
            self.* = undefined;
        }
    };
}

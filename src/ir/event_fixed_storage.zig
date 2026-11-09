//! Caller-owned event construction pools. No source walk, allocation or clearing
//! is hidden in layout/binding. Retained storage is the ordinary IR layout.
const std = @import("std");
const r = @import("resources.zig");
const fixed = @import("fixed_storage.zig");
const records = @import("event_records.zig");
const syntax = @import("../dot/syntax.zig");
const e = @import("../dot/events.zig");
const nesting = @import("../dot/scratch.zig");
const t = @import("topology.zig");

pub const Capacities = struct {
    nesting: u32 = 0,
    stage_statements: u32 = 0,
    stage_scopes: u32 = 0,
    stage_attributes: u32 = 0,
    stage_links: u32 = 0,
    stage_ports: u32 = 0,
    replay_frames: u32 = 0,
    pending_endpoints: u32 = 0,
    validation_keys: u32 = 0,
    partial_bookkeeping: bool = false,
};
pub const Bounds = struct { graph: fixed.GraphCapacities, scratch: Capacities };

pub fn For(comptime rep: @import("representation.zig").Identity, comptime Observer: ?type) type {
    const Base = fixed.For(rep);
    const C = if (Observer) |O| e.Context(O) else void;
    const PC = if (Observer) |O| if (@hasDecl(O, "ScopeContext") and @hasDecl(O, "recover_statements") and !O.recover_statements) ?C else C else C;
    const frame_size = @max(@sizeOf(nesting.For(C).Frame), @sizeOf(nesting.For(PC).Frame));
    const frame_alignment = @max(@alignOf(nesting.For(C).Frame), @alignOf(nesting.For(PC).Frame));
    return struct {
        const Family = @This();
        const Pools = struct {
            statements: []records.Statement,
            stage_scopes: []records.Scope,
            stage_attributes: []syntax.Attribute,
            stage_links: []records.Link,
            stage_ports: []syntax.NodeReferenceView,
            replay: []records.Replay,
            partial_statements: []records.PartialStatement,
            partial_scopes: []records.PartialScope,
            validation_keys: []@import("../dot/validation_checks.zig").AttributeKeyScratch,
            grouped: []t.Body,
        };
        const fields = @typeInfo(Pools).@"struct".field_names;
        pub const alignment = blk: {
            var n = @max(Base.alignment, frame_alignment);
            for (fields) |field| n = @max(n, @alignOf(std.meta.Elem(@FieldType(Pools, field))));
            break :blk n;
        };
        pub const Scratch = struct { bytes: []u8, graph_capacities: fixed.GraphCapacities, capacities: Capacities };
        pub const Memory = struct { graph: Base.GraphStorage, scratch: Scratch };
        fn index(comptime name: []const u8) usize {
            inline for (fields, 0..) |field, i| if (comptime std.mem.eql(u8, name, field)) return i;
            @compileError("unknown event pool");
        }
        fn count(comptime field: []const u8, g: fixed.GraphCapacities, s: Capacities) usize {
            if (comptime std.mem.eql(u8, field, "statements")) return s.stage_statements;
            if (comptime std.mem.eql(u8, field, "replay")) return s.replay_frames;
            if (comptime std.mem.eql(u8, field, "partial_statements")) return if (s.partial_bookkeeping) s.stage_statements else 0;
            if (comptime std.mem.eql(u8, field, "partial_scopes")) return if (s.partial_bookkeeping) s.stage_scopes else 0;
            if (comptime std.mem.eql(u8, field, "grouped")) return g.occurrences;
            return @field(s, field);
        }
        fn aligned(n: usize, by: usize) r.Error!usize {
            return (std.math.add(usize, n, by - 1) catch return error.IndexLimit) & ~(by - 1);
        }
        pub const Layout = struct {
            graph_bytes: usize,
            scratch_bytes: usize,
            alignment: usize = Family.alignment,
            graph_capacities: fixed.GraphCapacities,
            scratch_capacities: Capacities,
            base: Base.Layout,
            offsets: [fields.len]usize,
            frames_offset: usize,

            pub fn bind(self: Layout, graph: []u8, scratch: []u8) r.Error!Memory {
                const checked = try layout(self.graph_capacities, self.scratch_capacities);
                if (!std.meta.eql(self, checked)) return error.InvalidStorage;
                if (graph.len < self.graph_bytes or scratch.len < self.scratch_bytes) return error.BufferTooSmall;
                const g = graph[0..self.graph_bytes];
                const s = scratch[0..self.scratch_bytes];
                try region(g, Base.alignment);
                try region(s, alignment);
                if (overlaps(g, s)) return error.InvalidStorage;
                return .{ .graph = .{ .bytes = g, .capacities = self.graph_capacities }, .scratch = .{ .bytes = s, .graph_capacities = self.graph_capacities, .capacities = self.scratch_capacities } };
            }
        };
        pub fn layout(g: fixed.GraphCapacities, s: Capacities) r.Error!Layout {
            @setEvalBranchQuota(30_000);
            inline for (@typeInfo(Capacities).@"struct".field_names) |field| {
                if (@FieldType(Capacities, field) != bool) {
                    _ = try r.index(@field(s, field));
                }
            }
            const base = try Base.loweringLayout(g, .{ .pending_endpoints = s.pending_endpoints });
            var result: Layout = .{ .graph_bytes = base.graph_bytes, .scratch_bytes = 0, .graph_capacities = g, .scratch_capacities = s, .base = base, .offsets = undefined, .frames_offset = 0 };
            var at = base.scratch_bytes;
            inline for (fields, 0..) |field, i| {
                const T = std.meta.Elem(@FieldType(Pools, field));
                at = try aligned(at, @alignOf(T));
                result.offsets[i] = at;
                at = std.math.add(usize, at, std.math.mul(usize, count(field, g, s), @sizeOf(T)) catch return error.IndexLimit) catch return error.IndexLimit;
            }
            result.frames_offset = try aligned(at, frame_alignment);
            result.scratch_bytes = try aligned(std.math.add(usize, result.frames_offset, std.math.mul(usize, s.nesting, frame_size) catch return error.IndexLimit) catch return error.IndexLimit, alignment);
            _ = std.math.add(usize, result.graph_bytes, result.scratch_bytes) catch return error.IndexLimit;
            return result;
        }
        pub fn FixedScratch(comptime Retained: type, comptime capacities: Capacities) type {
            if (!std.meta.eql(Retained.representation, rep)) @compileError("event scratch and graph storage require the same representation");
            const info = comptime layout(Retained.graph_capacities, capacities) catch @compileError("invalid event scratch capacities");
            return struct {
                pub const byte_size = info.scratch_bytes;
                bytes: [byte_size]u8 align(alignment) = undefined,
                pub fn storage(self: *@This()) Scratch {
                    return .{ .bytes = &self.bytes, .graph_capacities = Retained.graph_capacities, .capacities = capacities };
                }
            };
        }
        pub const Context = struct {
            base: Base.Context,
            layout: Layout,
            memory: Memory,
            query_allocator: ?std.mem.Allocator,
            own_shortfall: ?fixed.StorageShortfall = null,
            peak: Capacities,
            nesting_depth: ?*const u32 = null,

            pub fn init(memory: Memory, source: []const u8, limits: r.Limits, query_allocator: ?std.mem.Allocator, comptime partial: bool) r.Error!Context {
                if (!std.meta.eql(memory.graph.capacities, memory.scratch.graph_capacities)) return error.InvalidStorage;
                if (partial and !memory.scratch.capacities.partial_bookkeeping) return error.InvalidStorage;
                const info = try Family.layout(memory.graph.capacities, memory.scratch.capacities);
                const bound = try info.bind(memory.graph.bytes, memory.scratch.bytes);
                if (info.graph_bytes + info.scratch_bytes > limits.max_bytes) return error.MemoryLimit;
                if (overlaps(bound.graph.bytes, source) or overlaps(bound.scratch.bytes, source)) return error.InvalidStorage;
                const base_memory = try info.base.bind(bound.graph.bytes, bound.scratch.bytes[0..info.base.scratch_bytes]);
                return .{ .base = try Base.Context.initSource(base_memory, source, limits, query_allocator), .layout = info, .memory = bound, .query_allocator = query_allocator, .peak = .{ .partial_bookkeeping = memory.scratch.capacities.partial_bookkeeping } };
            }
            // Keep the event/base storage bridge inline: these small accessors
            // run per record, and Small otherwise outlines both layers. The
            // descriptor is validated by init; capacity checks remain below.
            pub inline fn slice(self: *const Context, comptime field: []const u8) (if (@hasField(Pools, field)) @FieldType(Pools, field) else @TypeOf(@as(*const Base.Context, undefined).slice(field))) {
                if (!@hasField(Pools, field)) return @call(.always_inline, Base.Context.slice, .{ &self.base, field });
                const T = std.meta.Elem(@FieldType(Pools, field));
                const n = count(field, self.memory.graph.capacities, self.memory.scratch.capacities);
                if (n == 0) return &.{};
                const ptr: [*]T = @ptrCast(@alignCast(self.memory.scratch.bytes.ptr + self.layout.offsets[index(field)]));
                return ptr[0..n];
            }
            pub fn list(self: *const Context, comptime field: []const u8) std.ArrayList(std.meta.Elem(@TypeOf(self.slice(field)))) {
                const buffer = self.slice(field);
                var value: std.ArrayList(std.meta.Elem(@TypeOf(buffer))) = .empty;
                value.items = buffer[0..0];
                value.capacity = buffer.len;
                return value;
            }
            pub fn frames(self: *const Context, comptime ScopeContext: type) []nesting.For(ScopeContext).Frame {
                const Frame = nesting.For(ScopeContext).Frame;
                comptime std.debug.assert(@sizeOf(Frame) <= frame_size and @alignOf(Frame) <= frame_alignment);
                const n = self.memory.scratch.capacities.nesting;
                if (n == 0) return &.{};
                const ptr: [*]Frame = @ptrCast(@alignCast(self.memory.scratch.bytes.ptr + self.layout.frames_offset));
                return ptr[0..n];
            }
            fn capacityField(comptime field: []const u8) []const u8 {
                if (comptime std.mem.eql(u8, field, "statements") or std.mem.eql(u8, field, "partial_statements")) return "stage_statements";
                if (comptime std.mem.eql(u8, field, "partial_scopes")) return "stage_scopes";
                if (comptime std.mem.eql(u8, field, "replay")) return "replay_frames";
                return field;
            }
            pub inline fn ensure(self: *Context, comptime field: []const u8, needed: usize) r.Error!void {
                if (!@hasField(Pools, field)) return @call(.always_inline, Base.Context.ensure, .{ &self.base, field, needed });
                const n = count(field, self.memory.graph.capacities, self.memory.scratch.capacities);
                if (needed > n) {
                    const resource = if (comptime std.mem.eql(u8, field, "grouped")) .occurrence_pool else @field(fixed.Resource, capacityField(field));
                    return self.fail(resource, n, needed);
                }
            }
            pub fn fail(self: *Context, resource: fixed.Resource, capacity: usize, needed: usize) r.Error {
                const n = r.index(needed) catch return error.IndexLimit;
                if (self.shortfall() == null) self.own_shortfall = .{ .resource = resource, .limit = @intCast(capacity), .required_at_least = n };
                return error.PoolExhausted;
            }
            pub inline fn ensureTable(self: *Context, comptime field: []const u8, needed: usize) r.Error!void {
                return @call(.always_inline, Base.Context.ensureTable, .{ &self.base, field, needed });
            }
            pub inline fn observe(self: *Context, comptime field: []const u8, used: usize) void {
                const key = comptime capacityField(field);
                if (@hasField(Capacities, key)) {
                    @field(self.peak, key) = @max(@field(self.peak, key), @as(u32, @intCast(used)));
                } else @call(.always_inline, Base.Context.observe, .{ &self.base, field, used });
            }
            pub fn shortfall(self: *const Context) ?fixed.StorageShortfall {
                return self.own_shortfall orelse self.base.shortfall;
            }
            pub fn scratchPeak(self: *const Context) Capacities {
                var value = self.peak;
                value.pending_endpoints = @max(value.pending_endpoints, self.base.peak.pending_endpoints);
                return value;
            }
        };
        fn index64(value: u64) r.Error!u32 {
            if (value >= std.math.maxInt(u32)) return error.IndexLimit;
            return @intCast(value);
        }
        pub fn bounds(counts: syntax.Capacities, limits: r.Limits, duplicate_check: bool) r.Error!Bounds {
            inline for (@typeInfo(syntax.Capacities).@"struct".field_names) |field| _ = try index64(@field(counts, field));
            const base = try Base.loweringBounds(false, counts, limits);
            const scopes: u64 = counts.subgraphs;
            const owners: u64 = @as(u64, counts.edges) + counts.edge_chains + counts.scoped_edges;
            const links: u64 = @as(u64, counts.edge_links) + counts.scoped_edge_links;
            const statements: u64 = @as(u64, counts.statements) + scopes;
            return .{ .graph = base.graph, .scratch = .{
                .nesting = try index64(scopes),
                .stage_statements = try index64(statements),
                .stage_scopes = try index64(scopes + 1),
                .stage_attributes = try index64(counts.attributes),
                .stage_links = try index64(links + scopes),
                .stage_ports = try index64(counts.ported_references),
                .replay_frames = try index64(2 * (statements + scopes + owners) + 1),
                .pending_endpoints = try index64(2 * owners + links),
                .validation_keys = if (duplicate_check) try index64(counts.attributes) else 0,
            } };
        }
    };
}

fn region(bytes: []const u8, alignment: usize) r.Error!void {
    if (bytes.len == 0) return;
    if (@intFromPtr(bytes.ptr) % alignment != 0) return error.InvalidStorage;
    _ = std.math.add(usize, @intFromPtr(bytes.ptr), bytes.len) catch return error.InvalidStorage;
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    return if (x <= y) y - x < a.len else x - y < b.len;
}

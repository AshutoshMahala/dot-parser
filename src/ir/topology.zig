const std = @import("std");
const syntax = @import("../dot/syntax.zig");
const policy = @import("../dot/policy.zig");
const support = @import("parser_support");
const encoding = support.encoding;
const names = @import("names.zig");
const r = @import("resources.zig");
pub const Range = support.location.Range;
pub const NodeId = enum(u32) { _ };
pub const ScopeId = enum(u32) { root, _ };
pub const OccurrenceId = enum(u32) { root, _ };
pub const ConnectionId = enum(u32) { _ };
/// An IR-local handle, not a mutable set. Singletons carry their node inline;
/// sets refer to an immutable prefix of one semantic scope's body intervals.
pub const Membership = enum(u32) { _ };
pub const node_bit: u32 = 1 << 31;
pub const Body = struct { start: u32, end: u32, first: u32 };
pub const Node = struct { name: Range, first_mention: u32, hash: u64 };
pub const Scope = struct { parent: ?ScopeId, name: ?Range, first_occurrence: OccurrenceId, hash: u64 };
pub const Occurrence = struct { scope: ScopeId, parent: ?OccurrenceId, source: Range, membership: Membership };
pub const Mention = struct { node: NodeId, occurrence: OccurrenceId, source: Range };
pub const Endpoint = struct { members: Membership, port: ?syntax.PortSyntax = null };
pub const Connection = struct {
    left: Endpoint,
    right: Endpoint,
    written_operator: syntax.EdgeOperator,
    effective_operator: syntax.EdgeOperator,
    operator_source: Range,
    occurrence: OccurrenceId,
    attributes: syntax.AttributeRange,
};
/// Raw declarations, NOT resolved/defaulted attributes. Array order is semantic
/// execution order (children precede the containing edge's contribution).
pub const Declaration = struct {
    target: union(enum) { node: NodeId, defaults: syntax.AttributeTarget, graph_assignment },
    occurrence: OccurrenceId,
    attributes: syntax.AttributeRange,
};
pub const Edge = struct { from: NodeId, to: NodeId, operator: syntax.EdgeOperator, first_connection: ConnectionId };
pub const Materialized = struct {
    edges: []const Edge,
    peak_bytes: usize,
    allocator: std.mem.Allocator,
    storage: []Edge,
    pub fn deinit(self: *Materialized) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub fn Graph(comptime caps: encoding.Capabilities) type {
    return struct {
        const Self = @This();
        source: []const u8,
        source_info: encoding.Info,
        declared_kind: syntax.GraphKind,
        kind: policy.GraphKind,
        strict: bool,
        name: ?Range,
        nodes: []const Node,
        scopes: []const Scope,
        occurrences: []const Occurrence,
        mentions: []const Mention,
        connections: []const Connection,
        attributes: []const syntax.Attribute,
        declarations: []const Declaration,
        /// Peak live requested bytes during lowering, including scratch/growth.
        peak_bytes: usize,
        limits: r.Limits,
        allocator: std.mem.Allocator,
        node_storage: []Node,
        scope_storage: []Scope,
        declaration_storage: []Declaration,
        bodies: []const Body,
        node_slots: []const u32,
        posting_offsets: []const u32,
        posting_positions: []const u32,

        pub fn deinit(self: *Self) void {
            const a = self.allocator;
            a.free(self.node_storage);
            a.free(self.scope_storage);
            a.free(self.occurrences);
            a.free(self.mentions);
            a.free(self.connections);
            a.free(self.attributes);
            a.free(self.declaration_storage);
            a.free(self.bodies);
            a.free(self.node_slots);
            a.free(self.posting_offsets);
            a.free(self.posting_positions);
            self.* = undefined;
        }

        /// Retained allocation payload (including spare capacity), not source,
        /// allocator metadata, arena slack, or temporary operation scratch.
        pub fn retainedBytes(self: *const Self) usize {
            var bytes: usize = 0;
            inline for (.{ "node_storage", "scope_storage", "declaration_storage", "occurrences", "mentions", "connections", "attributes", "bodies", "node_slots", "posting_offsets", "posting_positions" }) |field| {
                const slice = @field(self, field);
                bytes += slice.len * @sizeOf(std.meta.Elem(@TypeOf(slice)));
            }
            return bytes;
        }

        /// Logical UTF-8 bytes, not a DOT spelling. No case folding, entity
        /// expansion, number normalization, or Unicode normalization.
        pub fn findNode(self: *const Self, value: []const u8) r.Error!?NodeId {
            return self.findNodeWith(value, .{});
        }
        pub fn findNodeWith(self: *const Self, value: []const u8, options: r.Options) r.Error!?NodeId {
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            try work.spend(value.len);
            const hash = std.hash.Wyhash.hash(0, value);
            if (self.node_slots.len == 0) return null;
            var at: usize = @intCast(hash & (self.node_slots.len - 1));
            while (true) : (at = (at + 1) & (self.node_slots.len - 1)) {
                try work.spend(1);
                const id = self.node_slots[at];
                if (id == names.empty) return null;
                const node = self.nodes[id];
                if (node.hash != hash) continue;
                const raw = self.text(node.name);
                const reader = if (self.source_info.encoding == .ascii and caps.utf8) .utf8 else self.source_info.encoding;
                const equal = switch (reader) {
                    inline else => |actual| if (comptime caps.allows(actual)) try names.matches(actual, raw, value, &work) else return error.UnsupportedEncoding,
                };
                if (equal) return @fromBackingInt(id);
            }
        }

        pub const NodeIterator = struct {
            index: u32 = 0,
            end: u32,

            pub fn next(self: *NodeIterator) ?NodeId {
                if (self.index >= self.end) return null;
                const id: NodeId = @fromBackingInt(self.index);
                self.index += 1;
                return id;
            }
        };

        /// Unique node IDs in first-introduction order; no allocation or scan.
        pub fn nodeIterator(self: *const Self) NodeIterator {
            return .{ .end = @intCast(self.nodes.len) };
        }

        /// A borrowed logical name for `{f}`. O(1) access; decoding happens on
        /// formatting, without allocation or repeated syntax validation.
        /// Formatting has ordinary writer semantics, not IR work accounting;
        /// use writeNodeNameWith for explicitly limited/cancellable writes.
        pub fn nodeName(self: *const Self, id: NodeId) r.Error!names.Formatted(caps) {
            return .{
                .raw = try self.nodeSpelling(id),
                .actual = if (self.source_info.encoding == .ascii and caps.utf8) .utf8 else self.source_info.encoding,
            };
        }

        /// Borrow the first source spelling, including quotes/concatenation,
        /// in the original source encoding. This is not the logical name.
        pub fn nodeSpelling(self: *const Self, id: NodeId) r.Error![]const u8 {
            const index = @backingInt(id);
            if (index >= self.nodes.len) return error.InvalidHandle;
            return self.text(self.nodes[index].name);
        }

        /// Stream the logical name, with the same byte semantics as findNode.
        /// No allocation or repeat syntax validation. Writer failures propagate;
        /// output can be partial if writing or cancellation stops the operation.
        pub fn writeNodeName(self: *const Self, id: NodeId, writer: anytype) !void {
            return self.writeNodeNameWith(id, writer, .{});
        }
        pub fn writeNodeNameWith(self: *const Self, id: NodeId, writer: anytype, options: r.Options) !void {
            const raw = try self.nodeSpelling(id);
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            const reader = if (self.source_info.encoding == .ascii and caps.utf8) .utf8 else self.source_info.encoding;
            switch (reader) {
                inline else => |actual| if (comptime caps.allows(actual)) try names.write(actual, raw, writer, &work) else return error.UnsupportedEncoding,
            }
        }

        pub fn text(self: *const Self, range: Range) []const u8 {
            return self.source[range.start..][0..range.len];
        }
        pub fn attributeSlice(self: *const Self, range: syntax.AttributeRange) ?[]const syntax.Attribute {
            if (range.start > self.attributes.len or range.len > self.attributes.len - range.start) return null;
            return self.attributes[range.start..][0..range.len];
        }
        pub fn scopeMembership(self: *const Self, id: ScopeId) r.Error!Membership {
            const raw = @backingInt(id);
            if (raw >= self.scopes.len) return error.InvalidHandle;
            // Occurrences are in opening order, so the last is the full version.
            // Direct callers normally use an occurrence/connection snapshot.
            var work = try r.Work.init(self.limits, null);
            var index = self.occurrences.len;
            while (index != 0) {
                index -= 1;
                try work.spend(1);
                if (self.occurrences[index].scope == id) return self.occurrences[index].membership;
            }
            return error.InvalidHandle;
        }
        pub fn contains(self: *const Self, members: Membership, node: NodeId) r.Error!bool {
            var work = try r.Work.init(self.limits, null);
            return self.containsWork(members, node, &work);
        }
        fn containsWork(self: *const Self, members: Membership, node: NodeId, work: *r.Work) r.Error!bool {
            const id = @backingInt(node);
            if (id >= self.nodes.len) return error.InvalidHandle;
            const handle = @backingInt(members);
            if (handle & node_bit != 0) {
                if (handle & ~node_bit >= self.nodes.len) return error.InvalidHandle;
                try work.spend(1);
                return handle & ~node_bit == id;
            }
            if (handle >= self.bodies.len) return error.InvalidHandle;
            const first = self.bodies[handle].first;
            const positions = self.posting_positions[self.posting_offsets[id]..self.posting_offsets[id + 1]];
            for (self.bodies[first .. handle + 1]) |body| {
                try work.spend(1);
                var lo: usize = 0;
                var hi = positions.len;
                while (lo < hi) {
                    try work.spend(1);
                    const mid = lo + (hi - lo) / 2;
                    if (positions[mid] < body.start) lo = mid + 1 else hi = mid;
                }
                if (lo < positions.len and positions[lo] < body.end) return true;
            }
            return false;
        }
        pub fn hasEdge(self: *const Self, from: NodeId, to: NodeId) r.Error!bool {
            return self.hasEdgeWith(from, to, .{});
        }
        pub fn hasEdgeWith(self: *const Self, from: NodeId, to: NodeId, options: r.Options) r.Error!bool {
            if (@backingInt(from) >= self.nodes.len or @backingInt(to) >= self.nodes.len) return error.InvalidHandle;
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            for (self.connections) |connection| {
                try work.spend(1);
                if (try self.containsWork(connection.left.members, from, &work) and try self.containsWork(connection.right.members, to, &work)) return true;
                if (connection.effective_operator == .undirected and try self.containsWork(connection.left.members, to, &work) and try self.containsWork(connection.right.members, from, &work)) return true;
            }
            return false;
        }

        pub const EdgeIterator = @import("edges.zig").Iterator(Self, false);

        /// Pull individual edges without retaining the output array. Scratch
        /// is allocated lazily and must be released with iterator.deinit().
        pub fn edgeIterator(self: *const Self, options: r.Options) r.Error!EdgeIterator {
            return EdgeIterator.init(self, options);
        }

        /// Explicit owning expansion, using the same traversal as edgeIterator.
        /// Strict graphs merge pairs; non-strict graphs preserve occurrences.
        /// Attributes remain raw in the IR.
        pub fn materialize(self: *const Self, options: r.Options) r.Error!Materialized {
            return @import("edges.zig").materialize(Self, self, options);
        }
    };
}

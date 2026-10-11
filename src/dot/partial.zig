//! Opt-in prefix tracking around failure-atomic builders. A failed event leaves
//! live syntax unchanged; freezing never snapshots pools or walks nesting.
const std = @import("std");
const syntax = @import("syntax.zig");
const event = @import("syntax_event.zig");

pub const pools = .{ "comments", "order", "nodes", "edges", "edge_chains", "scoped_edges", "scoped_edge_links", "edge_links", "ported_references", "subgraphs", "attributes", "assignments", "attribute_statements" };
pub const AllocationLengths = [pools.len]usize;
comptime {
    if (std.meta.fields(syntax.DocumentStorage).len != pools.len)
        @compileError("update partial-result allocation ownership for every syntax pool");
}
pub fn documentField(comptime field: []const u8) []const u8 {
    return if (std.mem.eql(u8, field, "subgraphs")) "subgraph_records" else field;
}

pub fn Builder(comptime Base: type) type {
    const owned = Base == syntax.Builder;
    return struct {
        const Self = @This();
        pub const Error = Base.Error;
        base: Base,
        enabled: bool,
        frozen: bool = false,
        retained_end: u32 = 0,
        // Allocated before parsing, only for owned partial-capable operations.
        // A terminal failure never needs to allocate to preserve buffer ownership.
        allocation_lengths: if (owned) ?*AllocationLengths else void = if (owned) null else {},
        failure_info: ?syntax.StorageFailureInfo = null,

        pub fn initCapacity(allocator: std.mem.Allocator, source: []const u8, capacities: syntax.Capacities, enabled: bool) Error!Self {
            const lengths = if (enabled) try allocator.create(AllocationLengths) else null;
            errdefer if (lengths) |ptr| allocator.destroy(ptr);
            return .{ .base = try Base.initCapacity(allocator, source, capacities), .enabled = enabled, .allocation_lengths = lengths };
        }
        pub fn init(source: []const u8, storage: syntax.DocumentStorage, enabled: bool) Self {
            return .{ .base = Base.init(source, storage), .enabled = enabled };
        }
        pub fn deinit(self: *Self) void {
            if (owned) {
                if (self.allocation_lengths) |ptr| self.base.allocator.destroy(ptr);
                self.base.deinit();
            }
        }
        fn call(self: *Self, comptime name: []const u8, args: anytype) @typeInfo(@TypeOf(@field(Base, name))).@"fn".return_type.? {
            const value = @call(.auto, @field(Base, name), .{&self.base} ++ args) catch |err| {
                self.failure_info = self.base.failure_info;
                return err;
            };
            return value;
        }
        pub fn retainThrough(self: *Self, end: u32) void {
            if (self.enabled and !self.frozen) self.retained_end = @max(self.retained_end, end);
        }
        pub fn comment(self: *Self, value: syntax.Comment) Error!void {
            return self.call("comment", .{value});
        }
        pub fn beginDocument(self: *Self, value: event.BeginDocument) Error!void {
            return self.call("beginDocument", .{value});
        }
        pub fn beginSubgraph(self: *Self, value: event.BeginSubgraph) Error!event.ScopeEntry {
            return self.call("beginSubgraph", .{value});
        }
        pub fn endSubgraph(self: *Self, value: event.EndSubgraph) Error!void {
            return self.call("endSubgraph", .{value});
        }
        pub fn subgraphStatement(self: *Self, value: u32) Error!void {
            return self.call("subgraphStatement", .{value});
        }
        pub fn nodeStatement(self: *Self, value: event.NodeStatement) Error!void {
            return self.call("nodeStatement", .{value});
        }
        pub fn edgeStatement(self: *Self, value: event.EdgeStatement) Error!void {
            return self.call("edgeStatement", .{value});
        }
        pub fn edgeChainStatement(self: *Self, value: event.EdgeStatement) Error!void {
            return self.call("edgeChainStatement", .{value});
        }
        pub fn edgeLink(self: *Self, value: event.EdgeLink) Error!void {
            return self.call("edgeLink", .{value});
        }
        pub fn portedReference(self: *Self, value: event.PortedReference) Error!u32 {
            return self.call("portedReference", .{value});
        }
        pub fn attribute(self: *Self, value: event.Attribute) Error!void {
            return self.call("attribute", .{value});
        }
        pub fn assignment(self: *Self, value: event.Attribute) Error!void {
            return self.call("assignment", .{value});
        }
        pub fn attributeStatement(self: *Self, value: event.AttributeStatement) Error!void {
            return self.call("attributeStatement", .{value});
        }
        pub fn endDocument(self: *Self) Error!void {
            return self.call("endDocument", .{});
        }
        pub fn abortDocument(self: *Self, reason: event.AbortReason) void {
            if (!self.enabled or self.base.phase != .building) return self.base.abortDocument(reason);
            self.frozen = true;
            // The view resolves unfinished subgraph intervals lazily. No stack
            // unwind, guessed delimiter, pool copy or allocator call is needed.
            self.base.phase = .committed;
        }
        pub fn toDocument(self: *Self) (if (owned) Error!syntax.Document else syntax.Document) {
            if (!self.enabled) return self.base.toDocument();
            if (!owned) {
                var document = self.base.toDocument();
                if (self.frozen) {
                    document.state = .partial;
                    document.retained_end = self.retained_end;
                }
                return document;
            }
            // Transfer capacity, including on success. Shrinking here could
            // allocate/fail after a fully parsed document has been retained.
            var document: syntax.Document = .{
                .source = self.base.source,
                .kind = self.base.kind,
                .strict = self.base.strict,
                .keyword = self.base.keyword,
                .name = self.base.name,
                .order = &.{},
                .nodes = &.{},
                .edges = &.{},
                .state = if (self.frozen) .partial else .complete,
                .retained_end = if (self.frozen) self.retained_end else 0,
            };
            if (!self.base.retain_comments) self.base.comments.clearAndFree(self.base.allocator);
            inline for (pools, 0..) |field, i| {
                const list = &@field(self.base, field);
                self.allocation_lengths.?[i] = list.capacity;
                @field(document, documentField(field)) = if (comptime std.mem.eql(u8, field, "comments"))
                    (if (self.base.retain_comments) list.items else null)
                else
                    list.items;
                list.* = .empty;
            }
            self.base.phase = .terminal;
            return document;
        }
    };
}

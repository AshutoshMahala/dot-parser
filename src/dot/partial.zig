//! Opt-in transactional adapter around the ordinary builders. A failed event
//! restores its touched records in constant work; freezing never walks nesting.
const std = @import("std");
const syntax = @import("syntax.zig");
const event = @import("syntax_event.zig");
const Span = @import("parser_support").location.Span;
const no_link = std.math.maxInt(u32);

pub const pools = .{ "comments", "order", "nodes", "edges", "edge_chains", "scoped_edges", "scoped_edge_links", "edge_links", "ported_references", "subgraphs", "attributes", "assignments", "attribute_statements" };
pub const AllocationLengths = [pools.len]usize;
comptime {
    if (std.meta.fields(syntax.DocumentStorage).len != pools.len)
        @compileError("update partial-result allocation ownership for every syntax pool");
}
pub fn documentField(comptime field: []const u8) []const u8 {
    return if (std.mem.eql(u8, field, "subgraphs")) "subgraph_records" else field;
}
fn storageField(comptime field: []const u8) []const u8 {
    return if (std.mem.eql(u8, field, "order")) "statement_ids" else field;
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
        fn items(self: *Self, comptime field: []const u8) []Element(field) {
            if (owned) return @field(self.base, field).items;
            return @field(self.base.storage, storageField(field))[0..@field(self.base, field ++ "_len")];
        }
        fn Element(comptime field: []const u8) type {
            return @typeInfo(@FieldType(syntax.DocumentStorage, storageField(field))).pointer.child;
        }
        fn length(self: *Self, comptime field: []const u8, len: usize) void {
            if (owned) @field(self.base, field).items.len = len else @field(self.base, field ++ "_len") = @intCast(len);
        }
        const Snapshot = struct {
            lengths: [transactional_pools.len]u32,
            scope: event.ScopeState,
            current: syntax.ScopeId,
            pending_links: usize,
            pending_attributes: usize,
            order: ?syntax.StatementId,
            owner: ?syntax.ScopedEdgeStatement,
            next: u32,
        };
        // Ordinary appends reserve/check all their storage before mutation.
        // Only scope entry and edge promotion can fail after changing live
        // records; journal exactly their pools, not every event/pool.
        const transactional_pools = .{ "order", "subgraphs", "scoped_edges", "scoped_edge_links" };
        fn snapshot(self: *Self) Snapshot {
            var result: Snapshot = .{
                .lengths = undefined,
                .scope = self.base.scope_state,
                .current = self.base.current_scope,
                .pending_links = self.base.pending_links,
                .pending_attributes = self.base.pending_attributes,
                .order = if (self.base.scope_state.reserved_order) |id| self.items("order")[id] else null,
                .owner = if (self.base.scope_state.scoped_owner) |id| self.items("scoped_edges")[id] else null,
                .next = no_link,
            };
            inline for (transactional_pools, 0..) |field, i| result.lengths[i] = @intCast(self.items(field).len);
            if (result.owner) |owner| if (owner.last_link != no_link) {
                result.next = self.items("scoped_edge_links")[owner.last_link].next;
            };
            return result;
        }
        fn restore(self: *Self, saved: Snapshot) void {
            inline for (transactional_pools, 0..) |field, i| self.length(field, saved.lengths[i]);
            if (saved.order) |value| self.items("order")[saved.scope.reserved_order.?] = value;
            if (saved.owner) |value| {
                self.items("scoped_edges")[saved.scope.scoped_owner.?] = value;
                if (value.last_link != no_link) self.items("scoped_edge_links")[value.last_link].next = saved.next;
            }
            self.base.scope_state = saved.scope;
            self.base.current_scope = saved.current;
            self.base.pending_links = saved.pending_links;
            self.base.pending_attributes = saved.pending_attributes;
        }
        fn call(self: *Self, comptime name: []const u8, args: anytype) @typeInfo(@TypeOf(@field(Base, name))).@"fn".return_type.? {
            const rollback = self.enabled and if (comptime std.mem.eql(u8, name, "beginSubgraph"))
                true
            else if (comptime std.mem.eql(u8, name, "edgeStatement") or std.mem.eql(u8, name, "edgeChainStatement"))
                self.base.scope_state.scoped_owner == null and (args[0].left_scope != null or args[0].right_scope != null)
            else
                false;
            const saved = if (rollback) self.snapshot() else undefined;
            const value = @call(.auto, @field(Base, name), .{&self.base} ++ args) catch |err| {
                if (rollback) self.restore(saved);
                self.failure_info = self.base.failure_info;
                return err;
            };
            if (self.enabled) self.retained_end = @max(self.retained_end, endOf(args));
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

// Events contain spans, not arbitrary graph walks. This recursion is entirely
// over their compile-time schema and has constant depth/work.
fn endOf(value: anytype) u32 {
    if (@TypeOf(value) == Span) return @intCast(value.endOffset());
    var end: u32 = 0;
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |s| inline for (s.fields) |f| {
            end = @max(end, endOf(@field(value, f.name)));
        },
        .optional => if (value) |v| {
            end = endOf(v);
        },
        else => {},
    }
    return end;
}

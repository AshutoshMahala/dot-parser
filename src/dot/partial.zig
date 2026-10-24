//! Opt-in retained regions around failure-atomic builders. Statement abort
//! abandons staging, not completed nested scopes. Terminal retention never
//! snapshots pools or walks nesting.
const std = @import("std");
const syntax = @import("syntax.zig");
const event = @import("events.zig");

pub const pools = .{ "comments", "order", "nodes", "edges", "edge_chains", "scoped_edges", "scoped_edge_links", "edge_links", "ported_references", "subgraphs", "attributes", "assignments", "attribute_statements" };
pub const AllocationLengths = [pools.len]usize;
comptime {
    if (std.meta.fieldNames(syntax.DocumentStorage).len != pools.len)
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
        pub const ScopeContext = Base.ScopeContext;
        pub const wants_begin_statement = false;
        pub const recover_statements = true;
        // Explicit internal capability: ordinary consumer methods with these
        // names never alter parser recovery or coverage.
        pub const parser_retention = struct {
            pub const continuesAfterError = Self.continuesAfterError;
            pub const retainThrough = Self.retainThrough;
            pub const closeRoot = Self.closeRoot;
        };
        base: Base,
        enabled: bool,
        frozen: bool = false,
        retained_end: u32 = 0,
        root_closed: bool = false,
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
        pub fn retainThrough(self: *Self, end: u32) void {
            if (self.enabled and !self.frozen) self.retained_end = @max(self.retained_end, end);
        }
        pub fn continuesAfterError(self: *const Self) bool {
            return self.enabled;
        }
        pub fn closeRoot(self: *Self) void {
            if (self.enabled and !self.frozen) self.root_closed = true;
        }
        fn abortStatement(self: *Self) void {
            if (!self.enabled) return;
            // Pending pairs/links must never attach to the next statement.
            // Promoted edge owners and reserved scope slots remain explicitly
            // unfinished; completed nested statements keep their stable IDs.
            // Attributes cannot contain nested statements. Only this tail is
            // unattached; truncating it preserves every completed child owner.
            if (owned) self.base.attributes.items.len = self.base.pending_attributes else self.base.attributes_len = self.base.pending_attributes;
            if (self.base.scope_state.scoped_owner) |index| {
                const owners = if (owned) self.base.scoped_edges.items else self.base.storage.scoped_edges;
                owners[index].first.attributes.len = self.retained_end;
            }
            self.base.pending_links = if (owned) self.base.edge_links.items.len else self.base.edge_links_len;
            self.base.scope_state = .{};
        }
        pub inline fn onEvent(self: *Self, value: event.Event) Error!event.Action {
            const action = self.base.onEvent(value) catch |err| {
                self.failure_info = self.base.failure_info;
                return err;
            };
            if (value == .skipped) self.retainThrough(@intCast(value.skipped.span.endOffset()));
            return action;
        }
        pub fn suspendScope(self: *Self) ScopeContext {
            return self.base.suspendScope();
        }
        pub fn restoreScope(self: *Self, saved: ScopeContext) void {
            self.base.restoreScope(saved);
        }
        pub fn onAbort(self: *Self, value: event.Abort) void {
            switch (value) {
                .statement => self.abortStatement(),
                .document => |reason| self.abortDocument(reason),
            }
        }
        fn abortDocument(self: *Self, reason: event.AbortReason) void {
            if (!self.enabled or self.base.phase != .building) return self.base.onAbort(.{ .document = reason });
            self.abortStatement();
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
                    document.root_closed = self.root_closed;
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
                .root_closed = !self.frozen or self.root_closed,
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

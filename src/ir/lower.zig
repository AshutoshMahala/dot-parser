const std = @import("std");
const syntax = @import("../dot/syntax.zig");
const encoding = @import("parser_support").encoding;
const policy = @import("../dot/policy.zig");
const t = @import("topology.zig");
const names = @import("names.zig");
const r = @import("resources.zig");
const attrs = @import("attributes.zig");
const coverage = @import("coverage.zig");
const mem = @import("lowering_storage.zig");
const pools = @import("fixed_storage.zig");

pub const Interpretation = InterpretationFor(false);
pub fn InterpretationFor(comptime partial: bool) type {
    return struct {
        kind: if (partial) ?policy.GraphKind else policy.GraphKind,
        directed: syntax.EdgeOperator,
        undirected: syntax.EdgeOperator,
        pub fn operator(self: @This(), written: syntax.EdgeOperator) syntax.EdgeOperator {
            return if (written == .directed) self.directed else self.undirected;
        }
    };
}

pub fn run(comptime caps: encoding.Capabilities, a: std.mem.Allocator, document: *const syntax.Document, interpretation: Interpretation, limits: r.Limits, cancellation: ?r.Cancellation) r.Error!t.Graph(caps) {
    return runWith(caps, false, a, document, interpretation, limits, cancellation);
}

pub inline fn runWith(comptime caps: encoding.Capabilities, comptime partial: bool, a: std.mem.Allocator, document: *const syntax.Document, interpretation: InterpretationFor(partial), limits: r.Limits, cancellation: ?r.Cancellation) r.Error!Output(caps, partial) {
    if (!partial and !document.scopeComplete()) return error.IncompleteDocument;
    if (document.strict and (interpretation.kind == .generic or (partial and interpretation.kind == null))) return error.UnsupportedSemantics;
    // An ASCII-admitted Document is byte-compatible with the UTF-8 reader.
    const reader = names.reader(caps, document.source_info.encoding);
    return switch (reader) {
        inline else => |actual| if (comptime caps.allows(actual)) blk: {
            var builder: Builder(actual, caps, partial) = .{
                .a = a,
                .doc = document,
                .interpretation = interpretation,
                .limits = limits,
                .work = try r.Work.init(limits, cancellation),
            };
            defer builder.deinit();
            break :blk try builder.build();
        } else error.UnsupportedEncoding,
    };
}

pub fn Output(comptime caps: encoding.Capabilities, comptime partial: bool) type {
    return if (partial) @import("partial.zig").Graph(caps) else t.Graph(caps);
}

pub fn Builder(comptime actual: encoding.Actual, comptime caps: encoding.Capabilities, comptime partial: bool) type {
    return BuilderWith(actual, caps, partial, false);
}
pub fn BuilderWith(comptime actual: encoding.Actual, comptime caps: encoding.Capabilities, comptime partial: bool, comptime fixed_storage: bool) type {
    return struct {
        const Self = @This();
        const Records = @import("lowering_types.zig");
        const ScopeCursor = Records.ScopeCursor;
        const Frame = Records.Frame;
        const EdgeFrame = Records.EdgeFrame;
        const Pending = Records.Pending;
        a: if (fixed_storage) *pools.Context else std.mem.Allocator,
        doc: *const syntax.Document,
        interpretation: InterpretationFor(partial),
        limits: r.Limits,
        work: r.Work,
        nodes: std.ArrayList(t.Node) = .empty,
        scopes: std.ArrayList(t.Scope) = .empty,
        declarations: std.ArrayList(t.Declaration) = .empty,
        occurrences: []t.Occurrence = &.{},
        bodies: []t.Body = &.{},
        mentions: []t.Mention = &.{},
        connections: []t.Connection = &.{},
        attributes: []syntax.Attribute = &.{},
        attribute_data: attrs.Store = .{},
        offsets: []u32 = &.{},
        positions: []u32 = &.{},
        node_table: names.Table = .{},
        scope_table: names.Table = .{},
        cursors: []ScopeCursor = &.{},
        stack: std.ArrayList(Frame) = .empty,
        edge_stack: std.ArrayList(EdgeFrame) = .empty,
        pending: std.ArrayList(Pending) = .empty,
        mention_count: u32 = 0,
        connection_count: u32 = 0,
        attribute_count: u32 = 0,
        // Keep the complete builder's field count/types unchanged. Even void
        // fields can perturb Zig's automatic layout of equal-alignment fields.
        publication: if (partial) struct {
            transferred: bool = false,
            coverage_data: coverage.Data = .{},
            next_scope: u32 = 1,
        } else bool = if (partial) .{} else false,

        pub fn bindFixed(self: *Self, context: *pools.Context) void {
            if (!fixed_storage) @compileError("fixed storage only");
            inline for (.{ "nodes", "scopes", "declarations", "stack", "edge_stack", "pending" }) |field| @field(self, field) = context.list(field);
            self.attribute_data.keys = context.list("keys");
            self.attribute_data.cells = context.list("cells");
            if (partial) self.publication.coverage_data.entries = context.list("gaps");
        }
        pub fn deinit(self: *Self) void {
            if (fixed_storage) return;
            const a = self.a;
            self.scope_table.deinit(a);
            a.free(self.cursors);
            self.stack.deinit(a);
            self.edge_stack.deinit(a);
            self.pending.deinit(a);
            if (if (partial) self.publication.transferred else self.publication) return;
            if (partial) self.publication.coverage_data.deinit(a);
            self.node_table.deinit(a);
            self.nodes.deinit(a);
            self.scopes.deinit(a);
            self.declarations.deinit(a);
            self.attribute_data.deinit(a);
            inline for (.{ "occurrences", "bodies", "mentions", "connections", "attributes", "offsets", "positions" }) |field| a.free(@field(self, field));
        }
        pub fn raw(self: *Self, range: t.Range) r.Error![]const u8 {
            if (range.start > self.doc.source.len or range.len > self.doc.source.len - range.start) return error.InvalidDocument;
            return self.doc.source[range.start..][0..range.len];
        }
        pub fn hashFor(self: *Self, id: u32) u64 {
            return self.nodes.items[id].hash;
        }
        fn node(self: *Self, reference: syntax.NodeReference, occurrence: u32) r.Error!t.Endpoint {
            const view = self.doc.nodeReference(reference) orelse return error.InvalidDocument;
            if (comptime encoding.Reader(actual).width != 1) if (view.port) |port| {
                // Native derived formatting is infallible after admission.
                _ = try names.hash(actual, try self.raw(port.first), &self.work);
                if (port.second) |second| {
                    if (second.start < port.first.start + port.first.len) return error.InvalidDocument;
                    _ = try names.hash(actual, try self.raw(second), &self.work);
                }
            };
            const spelling = try self.raw(view.identifier);
            const hash = try names.hash(actual, spelling, &self.work);
            var found: ?u32 = null;
            if (self.node_table.slots.len != 0) {
                var at: usize = @intCast(hash & (self.node_table.slots.len - 1));
                while (self.node_table.slots[at] != names.empty) : (at = (at + 1) & (self.node_table.slots.len - 1)) {
                    try self.work.spend(1);
                    const id = self.node_table.slots[at];
                    const existing = self.nodes.items[id];
                    if (existing.hash == hash and try names.eql(actual, try self.raw(existing.name), spelling, &self.work)) {
                        found = id;
                        break;
                    }
                }
            }
            const id = found orelse blk: {
                if (self.nodes.items.len >= self.limits.max_nodes) return error.NodeLimit;
                const id = try r.index(self.nodes.items.len);
                if (id >= t.node_bit) return error.IndexLimit;
                try mem.prepareTable(&self.node_table, self.a, &self.work, self, "node_slots");
                const scope = @backingInt(self.occurrences[occurrence].scope);
                const state = if (self.attribute_data.scopes.len == 0) attrs.none else self.attribute_data.scopes[scope].node;
                try mem.append(self.a, &self.nodes, .{ .name = view.identifier, .first_mention = self.mention_count, .attribute_state = state, .hash = hash }, "nodes");
                try self.node_table.insert(hash, id, &self.work);
                break :blk id;
            };
            if (self.mention_count >= self.mentions.len) return error.InvalidDocument;
            self.mentions[self.mention_count] = .{ .node = @fromBackingInt(id), .source = view.identifier, .occurrence = @fromBackingInt(occurrence) };
            self.mention_count += 1;
            return .{ .members = @fromBackingInt(t.node_bit | id), .port = view.port };
        }
        fn prepareScopes(self: *Self) r.Error!void {
            const count = try r.index(self.doc.subgraph_records.len + 1);
            if (count >= t.node_bit) return error.IndexLimit;
            // Limit written scope occurrences as well as distinct semantic scopes.
            if (count > self.limits.max_scopes) return error.ScopeLimit;
            self.occurrences = try mem.allocate(t.Occurrence, self.a, count, "occurrences", false);
            self.bodies = try mem.allocate(t.Body, self.a, count, "bodies", false);
            if (comptime encoding.Reader(actual).width != 1) if (self.doc.name) |name| {
                // Root names are not interned, but their formatters have the
                // same native-decoding precondition as every interned name.
                _ = try names.hash(actual, try self.raw(name), &self.work);
            };
            try mem.append(self.a, &self.scopes, .{ .parent = null, .name = self.doc.name, .first_occurrence = .root, .hash = 0 }, "scopes");
            self.occurrences[0] = .{ .scope = .root, .parent = null, .source = .{ .start = 0, .len = try r.index(self.doc.source.len) }, .membership = undefined };
            for (self.doc.subgraph_records, 1..) |record, occurrence| {
                try self.work.spend(1);
                const parent_occurrence = @backingInt(record.parent);
                if (parent_occurrence >= occurrence) return error.InvalidDocument;
                const parent = self.occurrences[parent_occurrence].scope;
                var hash: u64 = 0;
                var found: ?u32 = null;
                if (record.name) |name| {
                    const name_hash = try names.hash(actual, try self.raw(name), &self.work);
                    const parent_raw = @backingInt(parent);
                    hash = std.hash.Wyhash.hash(name_hash, std.mem.asBytes(&parent_raw));
                    if (self.scope_table.slots.len != 0) {
                        var at: usize = @intCast(hash & (self.scope_table.slots.len - 1));
                        while (self.scope_table.slots[at] != names.empty) : (at = (at + 1) & (self.scope_table.slots.len - 1)) {
                            try self.work.spend(1);
                            const id = self.scope_table.slots[at];
                            const existing = self.scopes.items[id];
                            if (existing.hash == hash and existing.parent.? == parent and try names.eql(actual, try self.raw(existing.name.?), try self.raw(name), &self.work)) {
                                found = id;
                                break;
                            }
                        }
                    }
                }
                const id = found orelse blk: {
                    const id = try r.index(self.scopes.items.len);
                    if (record.name != null) {
                        const Owner = struct {
                            scopes: []const t.Scope,
                            pub fn hashFor(owner: @This(), scope_id: u32) u64 {
                                return owner.scopes[scope_id].hash;
                            }
                        };
                        try mem.prepareTable(&self.scope_table, self.a, &self.work, Owner{ .scopes = self.scopes.items }, "scope_slots");
                    }
                    try mem.append(self.a, &self.scopes, .{ .parent = parent, .name = record.name, .first_occurrence = @fromBackingInt(@as(u32, @intCast(occurrence))), .hash = hash }, "scopes");
                    if (record.name != null) try self.scope_table.insert(hash, id, &self.work);
                    break :blk id;
                };
                const source = if (partial) self.doc.scope(@fromBackingInt(@as(u32, @intCast(occurrence)))).?.sourceRange() orelse return error.InvalidDocument else record.source;
                self.occurrences[occurrence] = .{ .scope = @fromBackingInt(id), .parent = @fromBackingInt(parent_occurrence), .source = source, .membership = undefined };
            }
            self.cursors = try mem.allocate(ScopeCursor, self.a, self.scopes.items.len, "cursors", false);
            for (self.cursors) |*cursor| {
                try self.work.spend(1);
                cursor.* = .{};
            }
            for (self.occurrences) |occurrence| {
                try self.work.spend(1);
                self.cursors[@backingInt(occurrence.scope)].next += 1;
            }
            var base: u32 = 0;
            for (self.cursors) |*cursor| {
                try self.work.spend(1);
                const len = cursor.next;
                cursor.first = base;
                cursor.next = base;
                base += len;
            }
            for (self.occurrences) |*occurrence| {
                try self.work.spend(1);
                const cursor = &self.cursors[@backingInt(occurrence.scope)];
                occurrence.membership = @fromBackingInt(cursor.next);
                self.bodies[cursor.next] = .{ .start = 0, .end = 0, .first = cursor.first };
                cursor.next += 1;
            }
        }
        pub fn firstEdge(statement: syntax.Statement) syntax.EdgeView {
            return switch (statement) {
                .edge => |e| e,
                .edge_chain => |chain| chain.first,
                else => unreachable,
            };
        }
        pub fn links(self: *Self, statement: syntax.Statement) syntax.EdgeLinkIterator {
            return if (statement == .edge_chain) self.doc.edgeLinks(statement.edge_chain) else .{ .document = self.doc };
        }
        fn enter(self: *Self, occurrence: u32) r.Error!void {
            if (occurrence >= self.occurrences.len) return error.InvalidDocument;
            if (partial and occurrence != 0) {
                if (occurrence != self.publication.next_scope) return error.InvalidDocument;
                self.publication.next_scope += 1;
            }
            const body = try self.scopeBody(occurrence);
            if (body.start > self.doc.order.len or body.len > self.doc.order.len - body.start) return error.InvalidDocument;
            const scope = @backingInt(self.occurrences[occurrence].scope);
            const parent = if (self.scopes.items[scope].parent) |id| @backingInt(id) else 0;
            try self.attribute_data.enter(self.a, scope, parent, @backingInt(self.scopes.items[scope].first_occurrence) == occurrence, self.limits.max_attribute_states, &self.work);
            self.bodies[@backingInt(self.occurrences[occurrence].membership)].start = self.mention_count;
            try mem.append(self.a, &self.stack, .{ .scope = .{ .occurrence = occurrence, .cursor = body.start, .end = body.start + body.len } }, "stack");
        }
        pub inline fn scopeBody(self: *Self, occurrence: u32) r.Error!syntax.StatementRange {
            if (occurrence == 0) return .{ .start = 0, .len = try r.index(self.doc.order.len) };
            const record = self.doc.subgraph_records[occurrence - 1];
            if (partial and record.subtree_end == 0) {
                if (record.body.start > self.doc.order.len) return error.InvalidDocument;
                return .{ .start = record.body.start, .len = try r.index(self.doc.order.len - record.body.start) };
            }
            return record.body;
        }
        inline fn copyAttributes(self: *Self, range: syntax.AttributeRange) r.Error!syntax.AttributeRange {
            if (!partial) return range;
            if (range.start > self.doc.attributes.len or range.len > self.doc.attributes.len - range.start or range.len > self.attributes.len - self.attribute_count) return error.InvalidDocument;
            const copied: syntax.AttributeRange = .{ .start = self.attribute_count, .len = range.len };
            for (self.doc.attributes[range.start..][0..range.len]) |attr| {
                try self.work.spend(1);
                self.attributes[self.attribute_count] = attr;
                self.attribute_count += 1;
            }
            return copied;
        }
        fn endpoint(self: *Self, endpoint_value: syntax.Endpoint, occurrence: u32) r.Error!void {
            switch (endpoint_value) {
                .node => |reference| try mem.append(self.a, &self.pending, .{ .node = try self.node(reference, occurrence) }, "pending"),
                .subgraph => |scope| {
                    const id = @backingInt(scope);
                    if (id == 0 or id >= self.occurrences.len) return error.InvalidDocument;
                    try mem.append(self.a, &self.pending, .{ .scope = self.occurrences[id].scope }, "pending");
                    try self.enter(id);
                },
            }
        }
        pub fn resolved(self: *Self, pending: Pending) r.Error!t.Endpoint {
            return switch (pending) {
                .node => |node_value| node_value,
                .scope => |scope| blk: {
                    const head = self.cursors[@backingInt(scope)].head;
                    if (head == names.empty) return error.InvalidDocument;
                    break :blk .{ .members = @fromBackingInt(head) };
                },
            };
        }
        fn connection(self: *Self, edge: syntax.EdgeView, occurrence: u32, left: Pending, right: Pending) r.Error!void {
            try self.work.spend(1);
            if (self.connection_count >= self.connections.len) return error.InvalidDocument;
            const effective = self.interpretation.operator(edge.operator);
            if (self.doc.strict and ((self.interpretation.kind == .digraph and effective != .directed) or (self.interpretation.kind == .undigraph and effective != .undirected))) return error.UnsupportedSemantics;
            self.connections[self.connection_count] = .{
                .left = try self.resolved(left),
                .right = try self.resolved(right),
                .written_operator = edge.operator,
                .effective_operator = effective,
                .operator_source = edge.operator_range,
                .occurrence = @fromBackingInt(occurrence),
                .attributes = edge.attributes,
            };
            const connection_id: t.ConnectionId = @fromBackingInt(self.connection_count);
            if (partial) self.publication.coverage_data.observeConnection(self.connection_count, self.connections[self.connection_count]);
            if (self.attribute_data.scopes.len != 0) {
                const scope = @backingInt(self.occurrences[occurrence].scope);
                self.attribute_data.connection_defaults[self.connection_count] = self.attribute_data.scopes[scope].edge;
                try self.attribute_data.bind(actual, self.a, self.doc.source, self.attributes, edge.attributes, .edge, .{ .connection = connection_id }, &self.work);
            }
            self.connection_count += 1;
        }
        fn declaration(self: *Self, target: @FieldType(t.Declaration, "target"), occurrence: u32, range: syntax.AttributeRange) r.Error!void {
            const id = try r.index(self.declarations.items.len);
            try mem.append(self.a, &self.declarations, .{ .target = target, .occurrence = @fromBackingInt(occurrence), .attributes = range }, "declarations");
            if (range.len == 0) return;
            const kind: attrs.Kind = switch (target) {
                .node => .node,
                .graph_assignment => .graph,
                .defaults => |value| switch (value) {
                    .graph => .graph,
                    .node => .node,
                    .edge => .edge,
                },
            };
            try self.attribute_data.bind(actual, self.a, self.doc.source, self.attributes, range, kind, .{ .declaration = id }, &self.work);
            const store = &self.attribute_data;
            const scope = &store.scopes[@backingInt(self.occurrences[occurrence].scope)];
            switch (target) {
                .node => |node_id| {
                    const node_value = &self.nodes.items[@backingInt(node_id)];
                    node_value.attribute_state = try store.apply(self.a, node_value.attribute_state, range, self.limits.max_attribute_states, &self.work);
                },
                .graph_assignment => scope.graph = try store.apply(self.a, scope.graph, range, self.limits.max_attribute_states, &self.work),
                .defaults => |value| switch (value) {
                    .graph => scope.graph = try store.apply(self.a, scope.graph, range, self.limits.max_attribute_states, &self.work),
                    .node => {
                        scope.node = try store.apply(self.a, scope.node, range, self.limits.max_attribute_states, &self.work);
                        if (self.occurrences[occurrence].scope != .root) scope.local_node = try store.apply(self.a, scope.local_node, range, self.limits.max_attribute_states, &self.work);
                    },
                    .edge => {
                        scope.edge = try store.apply(self.a, scope.edge, range, self.limits.max_attribute_states, &self.work);
                        if (self.occurrences[occurrence].scope != .root) scope.local_edge = try store.apply(self.a, scope.local_edge, range, self.limits.max_attribute_states, &self.work);
                    },
                },
            }
        }
        pub fn endpointEnd(self: *Self, endpoint_value: syntax.Endpoint) r.Error!u32 {
            if (endpoint_value == .node) return 0;
            const id = @backingInt(endpoint_value.subgraph);
            if (id == 0 or id > self.doc.subgraph_records.len) return error.InvalidDocument;
            const body = try self.scopeBody(id);
            return std.math.add(u32, body.start, body.len) catch error.InvalidDocument;
        }
        fn walk(self: *Self) r.Error!void {
            try self.enter(0);
            while (self.stack.items.len != 0) {
                try self.work.spend(1);
                const index = self.stack.items.len - 1;
                switch (self.stack.items[index]) {
                    .scope => |frame| {
                        // Reserved/abandoned owners have no Statement view,
                        // but their completed children remain real contributions.
                        if (partial and self.publication.next_scope < self.occurrences.len) {
                            const child = self.doc.subgraph_records[self.publication.next_scope - 1];
                            if (@backingInt(child.parent) == frame.occurrence and child.body.start <= frame.cursor) {
                                const body = try self.scopeBody(self.publication.next_scope);
                                self.stack.items[index].scope.cursor = @max(frame.cursor, body.start + body.len);
                                try self.enter(self.publication.next_scope);
                                continue;
                            }
                        }
                        if (frame.cursor == frame.end) {
                            const occurrence = self.occurrences[frame.occurrence];
                            const body = @backingInt(occurrence.membership);
                            self.bodies[body].end = self.mention_count;
                            self.cursors[@backingInt(occurrence.scope)].head = body;
                            _ = self.stack.pop();
                            continue;
                        }
                        if (frame.cursor > frame.end) return error.InvalidDocument;
                        const statement = self.doc.statementAt(frame.cursor) orelse {
                            if (!partial) return error.InvalidDocument;
                            self.stack.items[index].scope.cursor += 1;
                            const slot = self.doc.order[frame.cursor];
                            if (slot == .skipped_start) {
                                if (frame.cursor + 1 >= frame.end) return error.InvalidDocument;
                                const end = self.doc.order[frame.cursor + 1];
                                if (end != .skipped_end or end.skipped_end < slot.skipped_start or end.skipped_end > self.doc.source.len) return error.InvalidDocument;
                                self.stack.items[index].scope.cursor += 1;
                                try self.publication.coverage_data.add(self.a, .{ .reason = .skipped_input, .range = .{ .start = slot.skipped_start, .len = end.skipped_end - slot.skipped_start }, .occurrence = @fromBackingInt(frame.occurrence) }, self.declarations.items.len, self.connection_count, &self.work);
                            }
                            continue;
                        };
                        self.stack.items[index].scope.cursor += 1;
                        switch (statement) {
                            .node => |node_value| {
                                const value = try self.node(node_value.reference, frame.occurrence);
                                try self.declaration(.{ .node = @fromBackingInt(@backingInt(value.members) & ~t.node_bit) }, frame.occurrence, try self.copyAttributes(node_value.attributes));
                            },
                            .subgraph => |scope| {
                                self.stack.items[index].scope.cursor = @max(frame.cursor + 1, try self.endpointEnd(.{ .subgraph = scope }));
                                try self.enter(@backingInt(scope));
                            },
                            .edge, .edge_chain => {
                                const first = firstEdge(statement);
                                var end = @max(frame.cursor + 1, @max(try self.endpointEnd(first.left), try self.endpointEnd(first.right)));
                                var it = self.links(statement);
                                while (it.next()) |edge| {
                                    try self.work.spend(1);
                                    end = @max(end, try self.endpointEnd(edge.right));
                                }
                                self.stack.items[index].scope.cursor = end;
                                const edge_index = try r.index(self.edge_stack.items.len);
                                try mem.append(self.a, &self.edge_stack, .{ .occurrence = frame.occurrence, .first = first, .links = self.links(statement), .pending_start = try r.index(self.pending.items.len), .statement_index = frame.cursor }, "edge_stack");
                                try mem.append(self.a, &self.stack, .{ .edge = edge_index }, "stack");
                            },
                            .attribute_statement => |statement_attrs| try self.declaration(.{ .defaults = statement_attrs.target }, frame.occurrence, try self.copyAttributes(statement_attrs.attributes)),
                            .assignment => |attr| {
                                if (self.attribute_count >= self.attributes.len) return error.InvalidDocument;
                                self.attributes[self.attribute_count] = attr;
                                try self.declaration(.graph_assignment, frame.occurrence, .{ .start = self.attribute_count, .len = 1 });
                                self.attribute_count += 1;
                            },
                        }
                    },
                    .edge => |edge_index| {
                        const frame = self.edge_stack.items[edge_index];
                        if (frame.phase == 0) {
                            self.edge_stack.items[edge_index].phase = 1;
                            try self.endpoint(frame.first.left, frame.occurrence);
                        } else if (frame.phase == 1) {
                            self.edge_stack.items[edge_index].phase = 2;
                            try self.endpoint(frame.first.right, frame.occurrence);
                        } else if (self.edge_stack.items[edge_index].links.next()) |edge| {
                            try self.endpoint(edge.right, frame.occurrence);
                        } else {
                            // Freeze every endpoint only after all bodies in this
                            // statement have executed. Reopens can change BOTH ends.
                            var at = frame.pending_start;
                            var first = frame.first;
                            if (partial) first.attributes = try self.copyAttributes(first.attributes);
                            try self.connection(first, frame.occurrence, self.pending.items[at], self.pending.items[at + 1]);
                            at += 1;
                            var rest = self.links(self.doc.statementAt(frame.statement_index) orelse return error.InvalidDocument);
                            while (rest.next()) |original| {
                                var edge = original;
                                if (partial) edge.attributes = first.attributes;
                                try self.connection(edge, frame.occurrence, self.pending.items[at], self.pending.items[at + 1]);
                                at += 1;
                            }
                            self.pending.shrinkRetainingCapacity(frame.pending_start);
                            _ = self.edge_stack.pop();
                            _ = self.stack.pop();
                        }
                    },
                }
            }
        }
        pub fn build(self: *Self) r.Error!Output(caps, partial) {
            // Count written payload only; never multiply endpoint cardinalities.
            var mention_count: u64 = 0;
            var connection_count: u64 = 0;
            var retained_attributes: u64 = 0;
            var statements = self.doc.statements();
            while (statements.next()) |statement| {
                try self.work.spend(1);
                if (partial) retained_attributes += switch (statement) {
                    .node => |n| n.attributes.len,
                    .edge, .edge_chain => firstEdge(statement).attributes.len,
                    .attribute_statement => |s| s.attributes.len,
                    .assignment => 1,
                    else => 0,
                };
                switch (statement) {
                    .node => mention_count += 1,
                    .edge, .edge_chain => {
                        const first = firstEdge(statement);
                        mention_count += @intFromBool(first.left == .node) + @as(u64, @intFromBool(first.right == .node));
                        connection_count += 1;
                        var it = self.links(statement);
                        while (it.next()) |edge| {
                            try self.work.spend(1);
                            mention_count += @intFromBool(edge.right == .node);
                            connection_count += 1;
                        }
                    },
                    else => {},
                }
            }
            if (mention_count > self.limits.max_mentions) return error.MentionLimit;
            if (connection_count > self.limits.max_connections) return error.ConnectionLimit;
            const attribute_count = if (partial) retained_attributes else @as(u64, self.doc.attributes.len) + self.doc.assignments.len;
            if (attribute_count > self.limits.max_attributes) return error.AttributeLimit;
            if (attribute_count >= @import("ports.zig").right) return error.IndexLimit;
            try self.prepareScopes();
            self.mentions = try mem.allocate(t.Mention, self.a, @intCast(mention_count), "mentions", false);
            self.connections = try mem.allocate(t.Connection, self.a, @intCast(connection_count), "connections", false);
            self.attributes = try mem.allocate(syntax.Attribute, self.a, @intCast(attribute_count), "attributes", false);
            if (!partial) for (self.doc.attributes, self.attributes[0..self.doc.attributes.len]) |attr, *dest| {
                try self.work.spend(1);
                dest.* = attr;
            };
            if (!partial) self.attribute_count = try r.index(self.doc.attributes.len);
            try self.attribute_data.init(self.a, self.attributes.len, self.scopes.items.len, self.connections.len, &self.work);
            try self.walk();
            if (partial) {
                if (self.publication.next_scope != self.occurrences.len) return error.InvalidDocument;
                var unfinished: ?t.OccurrenceId = if (!self.doc.root_closed) .root else null;
                for (self.doc.subgraph_records, 1..) |scope, id| {
                    try self.work.spend(1);
                    if (scope.subtree_end == 0) unfinished = @fromBackingInt(@as(u32, @intCast(id)));
                }
                if (self.doc.unrepresented() != null or unfinished != null or (!self.doc.scopeComplete() and self.publication.coverage_data.entries.items.len == 0)) {
                    try self.publication.coverage_data.add(self.a, .{ .reason = .unfinished_input, .range = self.doc.unrepresented() orelse .{ .start = try r.index(self.doc.source.len), .len = 0 }, .occurrence = unfinished }, self.declarations.items.len, self.connection_count, &self.work);
                }
                try self.publication.coverage_data.finish(&self.work);
            }
            if (self.mention_count != self.mentions.len or self.connection_count != self.connections.len or self.attribute_count != self.attributes.len) return error.InvalidDocument;
            self.offsets = try mem.allocate(u32, self.a, self.nodes.items.len + 1, "offsets", false);
            self.positions = try mem.allocate(u32, self.a, self.mentions.len, "positions", false);
            for (self.offsets) |*offset| {
                try self.work.spend(1);
                offset.* = 0;
            }
            for (self.mentions) |mention| {
                try self.work.spend(1);
                self.offsets[@backingInt(mention.node) + 1] += 1;
            }
            for (1..self.offsets.len) |i| {
                try self.work.spend(1);
                self.offsets[i] += self.offsets[i - 1];
            }
            // Fill with the offsets themselves as cursors, then restore starts.
            for (self.mentions, 0..) |mention, position| {
                try self.work.spend(1);
                const cursor = &self.offsets[@backingInt(mention.node)];
                self.positions[cursor.*] = @intCast(position);
                cursor.* += 1;
            }
            var i = self.offsets.len - 1;
            while (i != 0) : (i -= 1) {
                try self.work.spend(1);
                self.offsets[i] = self.offsets[i - 1];
            }
            self.offsets[0] = 0;
            return self.publish();
        }
        /// Shared ownership transfer; callers finish every pool/index first.
        pub fn publish(self: *Self) Output(caps, partial) {
            const memory = if (fixed_storage) self.a else @as(*r.Memory, @ptrCast(@alignCast(self.a.ptr)));
            if (partial) self.publication.transferred = true else self.publication = true;
            const graph: t.GraphWith(caps, partial) = .{
                .source = self.doc.source,
                .source_info = self.doc.source_info,
                .declared_kind = self.doc.kind,
                .kind = self.interpretation.kind,
                .strict = self.doc.strict,
                .has_ports = self.doc.ported_references.len != 0,
                .name = self.doc.name,
                .nodes = self.nodes.items,
                .node_storage = self.nodes.allocatedSlice(),
                .scopes = self.scopes.items,
                .scope_storage = self.scopes.allocatedSlice(),
                .declarations = self.declarations.items,
                .declaration_storage = self.declarations.allocatedSlice(),
                .occurrences = self.occurrences,
                .bodies = self.bodies,
                .mentions = self.mentions,
                .connections = self.connections,
                .attributes = self.attributes,
                .attribute_data = self.attribute_data,
                .node_slots = self.node_table.slots,
                .posting_offsets = self.offsets,
                .posting_positions = self.positions,
                .peak_bytes = if (fixed_storage) memory.layout.graph_bytes + memory.layout.scratch_bytes else memory.peak,
                .limits = self.limits,
                .allocator = if (fixed_storage) memory.query_allocator orelse r.unavailableAllocator() else memory.backing,
                .borrowed_bytes = if (fixed_storage) memory.layout.graph_bytes else 0,
            };
            return if (partial) .{ ._data = graph, ._coverage = self.publication.coverage_data } else graph;
        }
    };
}

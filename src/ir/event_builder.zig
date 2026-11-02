//! Incremental construction using the same semantic primitives as Document
//! lowering. Only the active root statement (and its children) is staged.
const std = @import("std");
const enc = @import("parser_support").encoding;
const e = @import("../dot/events.zig");
const syntax = @import("../dot/syntax.zig");
const policy = @import("../dot/policy.zig");
const lower = @import("lower.zig");
const t = @import("topology.zig");
const r = @import("resources.zig");
const names = @import("names.zig");
const attrs = @import("attributes.zig");
const v = @import("event_validation.zig");
const indexes = @import("query_indexes.zig");
const none = std.math.maxInt(u32);
const Span = @import("parser_support").location.Span;
const Endpoint = union(enum) { node: syntax.NodeReferenceView, scope: u32 };
const Link = struct { right: Endpoint, operator: syntax.EdgeOperator, span: Span, next: u32 = none };
const Statement = struct {
    occurrence: u32,
    next: u32 = none,
    attributes: syntax.AttributeRange = .{},
    first_link: u32 = none,
    last_link: u32 = none,
    value: union(enum) { pending, node: e.Node, edge: e.Edge, scope: u32, assignment: syntax.Attribute, defaults: syntax.AttributeTarget } = .pending,
};
const Scope = struct { occurrence: u32, first: u32 = none, last: u32 = none, active: u32 = none, parent: u32 = 0 };
const Replay = union(enum) {
    scope: struct { scope: u32, statement: u32 },
    statement: u32,
    edge: struct { statement: u32, phase: u32 = 0, link: u32, pending: u32 },
};

pub fn Builder(comptime actual: enc.Actual, comptime rep: @import("representation.zig").Identity, comptime fixed: ?policy.ValidationSettings) type {
    return struct {
        const Self = @This();
        pub const wants_begin_statement = true;
        pub const recover_statements = true;
        pub const coverage = true;
        pub const Error = r.Error || v.Stop;
        header: lower.Header,
        b: lower.EventBuilder(actual, rep),
        checker: v.Checker(actual, fixed),
        keyword: Span = .{ .start = 0, .len = 0 },
        statements: std.ArrayList(Statement) = .empty,
        stage_scopes: std.ArrayList(Scope) = .empty,
        stage_attributes: std.ArrayList(syntax.Attribute) = .empty,
        stage_links: std.ArrayList(Link) = .empty,
        stage_ports: std.ArrayList(syntax.NodeReferenceView) = .empty,
        replay: std.ArrayList(Replay) = .empty,
        current: u32 = 0,
        scope_base: u32 = 1,
        reference_base: u32 = 0,
        next_reference: u32 = 0,
        occurrence_count: u32 = 0,
        aborted: bool = false,
        failure: ?Error = null,
        semantic_failure: ?r.Error = null,

        pub fn init(a: std.mem.Allocator, source: []const u8, info: enc.Info, limits: r.Limits, hook: ?r.Cancellation, settings: policy.ValidationSettings, sink: @import("../dot/diagnostic.zig").Sink) r.Error!Self {
            return .{ .header = .{ .source = source, .source_info = info, .kind = .digraph, .strict = false, .name = null }, .b = .{ .a = a, .doc = undefined, .limits = limits, .interpretation = undefined, .work = try r.Work.init(limits, hook) }, .checker = .{ .source = source, .runtime_settings = if (fixed == null) settings else {}, .sink = sink } };
        }
        pub fn deinit(self: *Self) void {
            self.checker.deinit(self.b.a);
            inline for (.{ "statements", "stage_scopes", "stage_attributes", "stage_links", "stage_ports", "replay" }) |field| @field(self, field).deinit(self.b.a);
            self.b.deinit();
        }
        fn append(self: *Self, list: anytype, value: std.meta.Elem(@TypeOf(list.items))) r.Error!u32 {
            try self.b.work.spend(1);
            const id = try r.index(list.items.len);
            if (list.items.len == list.capacity) try self.b.work.spend(list.items.len);
            try list.append(self.b.a, value);
            return id;
        }
        /// Slices store their allocation lengths during construction. Counters
        /// bound initialized records; publication compacts them to exact slices.
        fn reserve(self: *Self, comptime T: type, slice: *[]T, need: usize, maximum: usize) r.Error!void {
            if (need <= slice.len) return;
            if (need > maximum) return error.IndexLimit;
            const old = slice.len;
            const capacity = @min(maximum, std.ArrayList(T).growCapacity(need));
            try self.b.work.spend(old);
            slice.* = try self.b.a.realloc(slice.*, capacity);
        }
        fn compact(self: *Self, comptime T: type, slice: *[]T, count: usize) r.Error!void {
            if (slice.len == count) return;
            try self.b.work.spend(count);
            slice.* = try self.b.a.realloc(slice.*, count);
        }
        fn resetStage(self: *Self) void {
            inline for (.{ "statements", "stage_scopes", "stage_attributes", "stage_links", "stage_ports", "replay" }) |field| @field(self, field).clearRetainingCapacity();
            self.current = 0;
            self.scope_base = self.occurrence_count;
            self.reference_base = self.next_reference;
        }
        pub fn onEvent(self: *Self, event: e.Event) Error!e.Action {
            self.b.doc = &self.header;
            return self.consume(event) catch |err| {
                self.failure = err;
                return err;
            };
        }
        pub fn onAbort(self: *Self, _: e.Abort) void {
            // Complete-only construction never publishes recovered syntax as a
            // complete graph. The parser may continue delivering diagnostics.
            self.aborted = true;
        }
        fn consume(self: *Self, event: e.Event) Error!e.Action {
            if (self.aborted) return .proceed;
            try self.b.work.spend(1);
            switch (event) {
                .begin_document => |d| {
                    self.header = .{ .source = self.header.source, .source_info = d.source_info, .kind = if (d.kind == .digraph) .digraph else .undigraph, .strict = d.strict, .name = if (d.name_span) |name| name.span() else null };
                    self.keyword = d.keyword_span;
                    self.b.interpretation = interpretation(self.header.kind, self.checker.settings(), false);
                    if (enc.Reader(actual).width != 1) if (self.header.name) |name| {
                        _ = try self.scopeHash(name);
                    };
                    _ = try self.addScope(null, null, self.header.name, .{ .start = 0, .len = try r.index(self.header.source.len) });
                    self.b.bodies[0] = .{ .start = 0, .end = 0, .first = 0 };
                },
                .begin_statement => |d| {
                    if (self.stage_scopes.items.len == 0) _ = try self.append(&self.stage_scopes, .{ .occurrence = 0 });
                    const id = try self.append(&self.statements, .{ .occurrence = @backingInt(d.owner.scope) });
                    const scope = &self.stage_scopes.items[self.current];
                    if (scope.last != none) self.statements.items[scope.last].next = id else scope.first = id;
                    scope.last = id;
                    scope.active = id;
                },
                .begin_scope => |d| {
                    const occurrence = try self.addScope(@backingInt(d.parent), d.id, if (d.name) |name| name.span() else null, d.start);
                    if (d.role == .link) try self.link(.{ .scope = occurrence }, convertOperator(d.link_operator.?), d.link_operator_span.?);
                    self.current = try self.append(&self.stage_scopes, .{ .occurrence = occurrence, .parent = self.current });
                    try self.checker.restriction(self.checker.settings().restrictions.subgraphs, d.start, .subgraph);
                },
                .end_scope => |d| {
                    const id = @backingInt(d.id);
                    self.b.occurrences[id].source.len = d.close.start + d.close.len - self.b.occurrences[id].source.start;
                    self.current = self.stage_scopes.items[self.current].parent;
                },
                .attribute => |d| {
                    const index = try self.append(&self.stage_attributes, attr(d.pair));
                    const s = &self.statements.items[self.active()];
                    if (s.attributes.len == 0) s.attributes.start = index;
                    s.attributes.len += 1;
                },
                .ported_reference => |d| {
                    if (@backingInt(d.id) != self.next_reference) return error.InvalidDocument;
                    _ = try self.append(&self.stage_ports, .{ .identifier = d.reference.identifier.span(), .port = .{ .first = d.reference.first.span(), .second = if (d.reference.second) |n| n.span() else null } });
                    self.next_reference += 1;
                },
                .edge_link => |d| try self.link(.{ .node = try self.reference(d.link.right.span(), d.link.right_port) }, convertOperator(d.link.operator), d.link.operator_span),
                .commit_node => |d| {
                    self.statements.items[self.active()].value = .{ .node = d.value };
                    try self.commit();
                },
                .commit_edge, .commit_edge_chain => |d| {
                    self.statements.items[self.active()].value = .{ .edge = d.value };
                    try self.commit();
                },
                .commit_subgraph => |d| {
                    self.statements.items[self.active()].value = .{ .scope = @backingInt(d.value) };
                    try self.commit();
                },
                .commit_assignment => |d| {
                    self.statements.items[self.active()].value = .{ .assignment = attr(d.value) };
                    try self.commit();
                },
                .commit_attribute_statement => |d| {
                    self.statements.items[self.active()].value = .{ .defaults = switch (d.value.target) {
                        .graph => .graph,
                        .node => .node,
                        .edge => .edge,
                    } };
                    try self.commit();
                },
                .end_document => {
                    self.b.bodies[0].end = self.b.mention_count;
                    self.b.cursors[0].head = 0;
                },
                .skipped => self.aborted = true,
                else => {},
            }
            return .proceed;
        }
        fn active(self: *Self) u32 {
            return self.stage_scopes.items[self.current].active;
        }
        fn link(self: *Self, right: Endpoint, op: syntax.EdgeOperator, span: Span) r.Error!void {
            const id = try self.append(&self.stage_links, .{ .right = right, .operator = op, .span = span });
            const statement = &self.statements.items[self.active()];
            if (statement.last_link != none) self.stage_links.items[statement.last_link].next = id else statement.first_link = id;
            statement.last_link = id;
        }
        fn reference(self: *Self, identifier: Span, port: ?u32) r.Error!syntax.NodeReferenceView {
            if (port) |id| {
                if (id < self.reference_base or id - self.reference_base >= self.stage_ports.items.len) return error.InvalidDocument;
                return self.stage_ports.items[id - self.reference_base];
            }
            return .{ .identifier = identifier };
        }
        fn endpoint(self: *Self, edge: e.Edge, comptime left: bool) r.Error!Endpoint {
            if (if (left) edge.left_scope else edge.right_scope) |scope| return .{ .scope = scope };
            return .{ .node = try self.reference(if (left) edge.left else edge.right, if (left) edge.left_port else edge.right_port) };
        }
        fn commit(self: *Self) Error!void {
            const statement = self.statements.items[self.active()];
            const group = self.stage_attributes.items[statement.attributes.start..][0..statement.attributes.len];
            try self.checker.attributes(self.b.a, group, &self.b.work);
            if (statement.value == .assignment) try self.checker.attributes(self.b.a, &.{statement.value.assignment}, &self.b.work);
            switch (statement.value) {
                .node => |n| try self.checkReference(try self.reference(n.identifier.span(), n.port)),
                .edge => |edge| {
                    const left = try self.endpoint(edge, true);
                    const right = try self.endpoint(edge, false);
                    if (left == .node) try self.checkReference(left.node);
                    if (right == .node) try self.checkReference(right.node);
                    try self.checkOperator(convertOperator(edge.operator), edge.operator_span);
                    var link_id = statement.first_link;
                    while (link_id != none) {
                        try self.b.work.spend(1);
                        const l = self.stage_links.items[link_id];
                        if (l.right == .node) try self.checkReference(l.right.node);
                        try self.checkOperator(l.operator, l.span);
                        link_id = l.next;
                    }
                },
                else => {},
            }
            // A root transaction is complete; replay its nested records once.
            if (self.current == 0) {
                if (self.semantic_failure == null) self.walk(self.active()) catch |err| switch (err) {
                    error.InvalidIdentifier => self.semantic_failure = error.InvalidIdentifier,
                    else => return err,
                };
                self.resetStage();
            }
        }
        fn checkReference(self: *Self, view: syntax.NodeReferenceView) v.Stop!void {
            if (view.port) |port| {
                const last = port.second orelse port.first;
                try self.checker.restriction(self.checker.settings().restrictions.ports, .{ .start = port.first.start, .len = last.start + last.len - port.first.start }, .port);
            }
        }
        fn checkOperator(self: *Self, op: syntax.EdgeOperator, span: Span) v.Stop!void {
            try self.checker.operator(self.header.kind, self.keyword, op, span);
            if (op == .directed and self.header.kind == .undigraph and self.checker.settings().graph.treated_as == .auto) self.b.interpretation.kind = .generic;
        }
        fn addScope(self: *Self, parent_occurrence: ?u32, expected: ?e.ScopeId, name: ?Span, source: Span) r.Error!u32 {
            const occurrence = self.occurrence_count;
            if (occurrence >= self.b.limits.max_scopes) return error.ScopeLimit;
            if (occurrence >= t.node_bit) return error.IndexLimit;
            if (expected) |id| if (@backingInt(id) != occurrence) return error.InvalidDocument;
            const parent: ?t.ScopeId = if (parent_occurrence) |p| self.b.occurrences[p].scope else null;
            var hash: u64 = 0;
            var found: ?u32 = null;
            if (parent != null and name != null) {
                const h = try self.scopeHash(name.?);
                const p = @backingInt(parent.?);
                hash = std.hash.Wyhash.hash(h, std.mem.asBytes(&p));
                if (self.b.scope_table.slots.len != 0) {
                    var at: usize = @intCast(hash & (self.b.scope_table.slots.len - 1));
                    while (self.b.scope_table.slots[at] != none) : (at = (at + 1) & (self.b.scope_table.slots.len - 1)) {
                        try self.b.work.spend(1);
                        const id = self.b.scope_table.slots[at];
                        const existing = self.b.scopes.items[id];
                        if (self.semantic_failure == null and existing.hash == hash and existing.parent == parent and try names.eql(actual, existing.name.?.slice(self.header.source), name.?.slice(self.header.source), &self.b.work)) {
                            found = id;
                            break;
                        }
                    }
                }
            }
            const id = found orelse blk: {
                const id = try r.index(self.b.scopes.items.len);
                if (parent != null and name != null) {
                    const Owner = struct {
                        scopes: []const t.Scope,
                        pub fn hashFor(owner: @This(), i: u32) u64 {
                            return owner.scopes[i].hash;
                        }
                    };
                    try @import("lowering_storage.zig").prepareTable(&self.b.scope_table, self.b.a, &self.b.work, Owner{ .scopes = self.b.scopes.items }, "scope_slots");
                }
                _ = try self.append(&self.b.scopes, .{ .parent = parent, .name = name, .first_occurrence = @fromBackingInt(occurrence), .hash = hash });
                if (parent != null and name != null) try self.b.scope_table.insert(hash, id, &self.b.work);
                try self.reserve(@import("lowering_types.zig").ScopeCursor, &self.b.cursors, id + 1, self.b.limits.max_scopes);
                self.b.cursors[id] = .{};
                if (rep.attributes and self.b.attribute_data.scopes.len != 0) {
                    try self.reserve(attrs.Scope, &self.b.attribute_data.scopes, id + 1, self.b.limits.max_scopes);
                    self.b.attribute_data.scopes[id] = .{};
                }
                break :blk id;
            };
            try self.reserve(t.Occurrence, &self.b.occurrences, occurrence + 1, self.b.limits.max_scopes);
            try self.reserve(t.Body, &self.b.bodies, occurrence + 1, self.b.limits.max_scopes);
            self.b.occurrences[occurrence] = .{ .scope = @fromBackingInt(id), .parent = if (parent_occurrence) |p| @fromBackingInt(p) else null, .source = source, .membership = @fromBackingInt(occurrence) };
            self.b.bodies[occurrence] = .{ .start = 0, .end = 0, .first = 0 };
            self.occurrence_count += 1;
            return occurrence;
        }
        fn scopeHash(self: *Self, name: Span) r.Error!u64 {
            return names.hash(actual, name.slice(self.header.source), &self.b.work) catch |err| switch (err) {
                // Finish configured input checks before returning a semantic
                // name failure; an encoding error must keep its diagnostic.
                error.InvalidIdentifier => blk: {
                    self.semantic_failure = error.InvalidIdentifier;
                    break :blk 0;
                },
                else => return err,
            };
        }
        fn enter(self: *Self, occurrence: u32) r.Error!void {
            const local = occurrence - self.scope_base + 1;
            const scope = @backingInt(self.b.occurrences[occurrence].scope);
            const parent = if (self.b.scopes.items[scope].parent) |p| @backingInt(p) else 0;
            if (rep.attributes) try self.b.attribute_data.enter(self.b.a, scope, parent, @backingInt(self.b.scopes.items[scope].first_occurrence) == occurrence, self.b.limits.max_attribute_states, &self.b.work);
            self.b.bodies[occurrence].start = self.b.mention_count;
            _ = try self.append(&self.replay, .{ .scope = .{ .scope = occurrence, .statement = self.stage_scopes.items[local].first } });
        }
        fn takeNode(self: *Self, view: syntax.NodeReferenceView, occurrence: u32, retain_port: bool) Error!t.Endpoint {
            if (self.b.mention_count >= self.b.limits.max_mentions) return error.MentionLimit;
            try self.reserve(t.Mention, &self.b.mentions, self.b.mention_count + 1, self.b.limits.max_mentions);
            if (view.port != null) {
                if (retain_port) try self.reserve(syntax.PortSyntax, &self.b.endpoint_ports, self.b.port_count + 1, self.b.limits.max_mentions);
            }
            return self.b.node(view, occurrence, retain_port);
        }
        fn takeEndpoint(self: *Self, value: Endpoint, occurrence: u32) Error!void {
            switch (value) {
                .node => |node| {
                    const result = try self.takeNode(node, occurrence, true);
                    _ = try self.append(&self.b.pending, .{ .node = result });
                },
                .scope => |id| {
                    _ = try self.append(&self.b.pending, .{ .scope = self.b.occurrences[id].scope });
                    try self.enter(id);
                },
            }
        }
        fn copyAttributes(self: *Self, group: []const syntax.Attribute) r.Error!syntax.AttributeRange {
            if (!rep.attributes or group.len == 0) return .{};
            const start = self.b.attribute_count;
            if (group.len > self.b.limits.max_attributes - start) return error.AttributeLimit;
            const end = start + @as(u32, @intCast(group.len));
            if (end >= @import("ports.zig").right) return error.IndexLimit;
            try self.reserve(syntax.Attribute, &self.b.attributes, end, self.b.limits.max_attributes);
            try self.reserve(attrs.Meta, &self.b.attribute_data.meta, end, self.b.limits.max_attributes);
            if (self.b.attribute_data.scopes.len == 0) {
                try self.reserve(attrs.Scope, &self.b.attribute_data.scopes, self.b.scopes.items.len, self.b.limits.max_scopes);
                for (self.b.attribute_data.scopes) |*scope| {
                    try self.b.work.spend(1);
                    scope.* = .{};
                }
                try self.reserve(u32, &self.b.attribute_data.connection_defaults, self.b.connection_count, self.b.limits.max_connections);
                for (self.b.attribute_data.connection_defaults) |*value| {
                    try self.b.work.spend(1);
                    value.* = attrs.none;
                }
            }
            for (group, start..) |value, i| {
                try self.b.work.spend(1);
                self.b.attributes[i] = value;
                self.b.attribute_data.meta[i] = .{};
            }
            self.b.attribute_count = end;
            return .{ .start = start, .len = @intCast(group.len) };
        }
        fn connect(self: *Self, op: syntax.EdgeOperator, span: Span, occurrence: u32, left: @import("lowering_types.zig").Pending, right: @import("lowering_types.zig").Pending, range: syntax.AttributeRange) Error!void {
            if (self.b.connection_count >= self.b.limits.max_connections) return error.ConnectionLimit;
            try self.reserve(t.ConnectionFor(rep.attributes), &self.b.connections, self.b.connection_count + 1, self.b.limits.max_connections);
            const with_attributes = rep.attributes and self.b.attribute_data.scopes.len != 0;
            if (with_attributes) try self.reserve(u32, &self.b.attribute_data.connection_defaults, self.b.connection_count + 1, self.b.limits.max_connections);
            // Validation errors reject the input through checking, not an IR
            // semantic error. Strict incompatibility is tested after validation.
            const strict = self.header.strict;
            self.header.strict = false;
            const id = self.b.storeConnection(op, span, occurrence, left, right, range, with_attributes) catch |err| {
                self.header.strict = strict;
                return err;
            };
            self.header.strict = strict;
            if (with_attributes) try self.b.attribute_data.bind(actual, self.b.a, self.header.source, self.b.attributes, range, .edge, .{ .connection = id }, &self.b.work);
            self.b.connection_count += 1;
        }
        fn walk(self: *Self, root: u32) Error!void {
            _ = try self.append(&self.replay, .{ .statement = root });
            while (self.replay.items.len != 0) {
                try self.b.work.spend(1);
                const top = self.replay.items.len - 1;
                switch (self.replay.items[top]) {
                    .scope => |frame| {
                        if (frame.statement == none) {
                            self.b.bodies[frame.scope].end = self.b.mention_count;
                            self.b.cursors[@backingInt(self.b.occurrences[frame.scope].scope)].head = frame.scope;
                            _ = self.replay.pop();
                        } else {
                            self.replay.items[top].scope.statement = self.statements.items[frame.statement].next;
                            _ = try self.append(&self.replay, .{ .statement = frame.statement });
                        }
                    },
                    .statement => |id| {
                        _ = self.replay.pop();
                        const s = self.statements.items[id];
                        const group = self.stage_attributes.items[s.attributes.start..][0..s.attributes.len];
                        switch (s.value) {
                            .pending => return error.InvalidDocument,
                            .node => |n| {
                                const node = try self.takeNode(try self.reference(n.identifier.span(), n.port), s.occurrence, false);
                                try self.b.declaration(.{ .node = @fromBackingInt(@backingInt(node.members) & ~t.node_bit) }, s.occurrence, try self.copyAttributes(group));
                            },
                            .defaults => |target| try self.b.declaration(.{ .defaults = target }, s.occurrence, try self.copyAttributes(group)),
                            .assignment => |value| try self.b.declaration(.graph_assignment, s.occurrence, try self.copyAttributes(&.{value})),
                            .scope => |scope| try self.enter(scope),
                            .edge => {
                                _ = try self.append(&self.replay, .{ .edge = .{ .statement = id, .link = s.first_link, .pending = try r.index(self.b.pending.items.len) } });
                            },
                        }
                    },
                    .edge => |frame| {
                        const s = self.statements.items[frame.statement];
                        const edge = s.value.edge;
                        if (frame.phase < 2) {
                            self.replay.items[top].edge.phase += 1;
                            try self.takeEndpoint(if (frame.phase == 0) try self.endpoint(edge, true) else try self.endpoint(edge, false), s.occurrence);
                        } else if (frame.link != none) {
                            const link_value = self.stage_links.items[frame.link];
                            self.replay.items[top].edge.link = link_value.next;
                            try self.takeEndpoint(link_value.right, s.occurrence);
                        } else {
                            const range = try self.copyAttributes(self.stage_attributes.items[s.attributes.start..][0..s.attributes.len]);
                            var p = frame.pending;
                            try self.connect(convertOperator(edge.operator), edge.operator_span, s.occurrence, self.b.pending.items[p], self.b.pending.items[p + 1], range);
                            var link_id = s.first_link;
                            while (link_id != none) {
                                const link_value = self.stage_links.items[link_id];
                                p += 1;
                                try self.connect(link_value.operator, link_value.span, s.occurrence, self.b.pending.items[p], self.b.pending.items[p + 1], range);
                                link_id = link_value.next;
                            }
                            self.b.pending.shrinkRetainingCapacity(frame.pending);
                            _ = self.replay.pop();
                        }
                    },
                }
            }
        }
        pub fn finishChecks(self: *Self) Error!void {
            try self.checker.graphKind(self.b.interpretation.kind, self.keyword);
            try self.checker.encoding(&self.b.work);
        }
        pub fn finish(self: *Self) r.Error!t.Graph(rep) {
            if (self.semantic_failure) |err| return err;
            const b = &self.b;
            inline for (.{ "nodes", "scopes", "declarations" }) |field| if (@FieldType(@TypeOf(b.*), field) != void) {
                const list = &@field(b, field);
                try b.work.spend(list.items.len);
                const items = try list.toOwnedSlice(b.a);
                list.items = items;
                list.capacity = items.len;
            };
            if (self.header.strict) {
                if (b.interpretation.kind == .generic) return error.UnsupportedSemantics;
                for (b.connections[0..b.connection_count]) |c| {
                    try b.work.spend(1);
                    if ((b.interpretation.kind == .digraph) != (c.effective_operator == .directed)) return error.UnsupportedSemantics;
                }
            }
            try self.compact(t.Occurrence, &b.occurrences, self.occurrence_count);
            try self.compact(t.Body, &b.bodies, self.occurrence_count);
            try self.compact(t.Mention, &b.mentions, b.mention_count);
            try self.compact(t.ConnectionFor(rep.attributes), &b.connections, b.connection_count);
            try self.compact(syntax.PortSyntax, &b.endpoint_ports, b.port_count);
            if (rep.attributes) {
                try self.compact(syntax.Attribute, &b.attributes, b.attribute_count);
                try self.compact(attrs.Meta, &b.attribute_data.meta, b.attribute_count);
                if (b.attribute_count != 0) {
                    try self.compact(attrs.Scope, &b.attribute_data.scopes, b.scopes.items.len);
                    try self.compact(u32, &b.attribute_data.connection_defaults, b.connection_count);
                }
            }
            // Group body versions by semantic scope, matching the compact range
            // membership representation. Connections refer to frozen versions.
            for (b.cursors[0..b.scopes.items.len]) |*cursor| {
                try b.work.spend(1);
                cursor.next = 0;
            }
            for (b.occurrences) |o| {
                try b.work.spend(1);
                b.cursors[@backingInt(o.scope)].next += 1;
            }
            var base: u32 = 0;
            for (b.cursors[0..b.scopes.items.len]) |*c| {
                try b.work.spend(1);
                const count = c.next;
                c.first = base;
                c.next = base;
                base += count;
            }
            var grouped = try b.a.alloc(t.Body, self.occurrence_count);
            errdefer b.a.free(grouped);
            for (b.occurrences) |*o| {
                try b.work.spend(1);
                const c = &b.cursors[@backingInt(o.scope)];
                grouped[c.next] = b.bodies[@backingInt(o.membership)];
                grouped[c.next].first = c.first;
                o.membership = @fromBackingInt(c.next);
                c.next += 1;
            }
            b.a.free(b.bodies);
            b.bodies = grouped;
            grouped = &.{};
            for (b.connections) |*c| {
                try b.work.spend(1);
                inline for (.{ "left", "right" }) |side| {
                    const id = @backingInt(@field(c, side).members);
                    if (id & t.node_bit == 0) @field(c, side).members = b.occurrences[id].membership;
                }
            }
            b.offsets = try b.a.alloc(u32, b.nodes.items.len + 1);
            b.positions = try b.a.alloc(u32, b.mention_count);
            for (b.offsets) |*offset| {
                try b.work.spend(1);
                offset.* = 0;
            }
            for (b.mentions) |mention| {
                try b.work.spend(1);
                b.offsets[@backingInt(mention.node) + 1] += 1;
            }
            for (1..b.offsets.len) |i| {
                try b.work.spend(1);
                b.offsets[i] += b.offsets[i - 1];
            }
            for (b.mentions, 0..) |mention, position| {
                try b.work.spend(1);
                const cursor = &b.offsets[@backingInt(mention.node)];
                b.positions[cursor.*] = @intCast(position);
                cursor.* += 1;
            }
            var i = b.offsets.len - 1;
            while (i > 0) : (i -= 1) {
                try b.work.spend(1);
                b.offsets[i] = b.offsets[i - 1];
            }
            b.offsets[0] = 0;
            if (comptime rep.indexes.any()) {
                var indexer: indexes.Builder(rep.indexes) = .{};
                while (true) {
                    try b.work.spend(1);
                    if (try indexer.step(b, false)) break;
                }
            }
            // Published graphs use the existing single-allocation topology
            // layout. Keep separate growable pools private to construction.
            if (b.port_count != 0) {
                const joined = try @import("topology_storage.zig").allocate(t.ConnectionFor(rep.attributes), b.a, b.connection_count, b.port_count, false);
                errdefer @import("topology_storage.zig").release(b.a, joined);
                for (b.connections, joined.connections) |source, *dest| {
                    try b.work.spend(1);
                    dest.* = source;
                }
                for (b.endpoint_ports, joined.endpoint_ports) |source, *dest| {
                    try b.work.spend(1);
                    dest.* = source;
                }
                b.a.free(b.connections);
                b.a.free(b.endpoint_ports);
                b.connections = joined.connections;
                b.endpoint_ports = joined.endpoint_ports;
            }
            return b.publish();
        }
    };
}
fn attr(value: e.Attribute) syntax.Attribute {
    return .{ .key = value.key.span(), .value = value.value.span() };
}
fn convertOperator(value: e.EdgeOperator) syntax.EdgeOperator {
    return if (value == .directed) .directed else .undirected;
}
pub fn interpretation(declared: syntax.GraphKind, settings: policy.ValidationSettings, directed: bool) lower.Interpretation {
    const treatment = if (declared == .digraph) policy.GraphTreatment.digraph else settings.graph.treated_as;
    const kind: policy.GraphKind = switch (treatment) {
        .digraph => .digraph,
        .undigraph => .undigraph,
        .generic => .generic,
        .auto => if (directed) .generic else .undigraph,
    };
    const reading = if (declared == .digraph) settings.digraph.operator_reading else if (treatment == .generic or treatment == .auto) .as_written else settings.graph.operators.operator_reading;
    return .{ .kind = kind, .directed = if (reading == .conform_to_kind and kind == .undigraph) .undirected else .directed, .undirected = if (reading == .conform_to_kind and kind == .digraph) .directed else .undirected };
}

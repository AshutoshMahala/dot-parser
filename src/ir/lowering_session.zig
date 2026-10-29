//! Document lowering with bounded, explicit continuations. Shares retained
//! storage and semantic primitives with the throughput-specialized direct path.
const std = @import("std");
const syntax = @import("../dot/syntax.zig");
const encoding = @import("parser_support").encoding;
const lower = @import("lower.zig");
const t = @import("topology.zig");
const attrs = @import("attributes.zig");
const names = @import("names.zig");
const r = @import("resources.zig");
const storage = @import("session_storage.zig");
const p = @import("lowering_primitives.zig");
const coverage = @import("coverage.zig");
const none = names.empty;
const pools = @import("fixed_storage.zig");
const mem = @import("lowering_storage.zig");

pub const Outcome = union(enum) { success, failure: r.Error };
pub const Progress = struct { work_used: u32, total_work: u64, nodes_created: u32, connections_created: u32, outcome: ?Outcome };
pub const TakeError = r.Error || error{ NotReady, AlreadyTaken };

pub fn Session(comptime caps: encoding.Capabilities, comptime partial: bool, comptime fixed: ?@import("execution_policy.zig").Effective) type {
    return SessionWith(caps, partial, fixed, false);
}
pub fn SessionWith(comptime caps: encoding.Capabilities, comptime partial: bool, comptime fixed: ?@import("execution_policy.zig").Effective, comptime fixed_storage: bool) type {
    // Builder's storage layout is encoding-independent. Only its bounded
    // structural helpers are called here; names use the selected native reader.
    const B = lower.BuilderWith(.utf8, caps, partial, fixed_storage);
    const cancellable = fixed == null or fixed.?.cancellation;
    const Hook = if (cancellable) ?r.Cancellation else void;
    const Polling = @import("parser_support").execution.CancellationPolling(cancellable, if (fixed) |value| value.cancellation_interval else null);
    return struct {
        const Self = @This();
        pub const Result = lower.Output(caps, partial);
        const Phase = enum {
            count,
            count_links,
            allocate,
            root_name,
            scope,
            scope_done,
            cursor_clear,
            cursor_count,
            cursor_prefix,
            cursor_assign,
            data_allocate,
            copy_attributes,
            meta_clear,
            scope_clear,
            enter,
            enter_overlay,
            enter_overlay_set,
            enter_push,
            walk,
            chain_scan,
            node_start,
            node_port,
            node_done,
            endpoint,
            pending_node,
            pending_scope,
            edge_finish,
            edge_emit,
            edge_bound,
            edge_next,
            copy_range,
            declaration,
            bind,
            bind_value,
            bind_done,
            apply,
            apply_set,
            apply_next,
            intern_hash,
            intern_probe,
            intern_equal,
            intern_prepare,
            table_clear,
            rehash_scan,
            rehash_probe,
            intern_append,
            intern_insert,
            gap,
            unfinished,
            gap_suffix,
            posting_allocate,
            posting_clear,
            posting_count,
            posting_prefix,
            posting_fill,
            posting_restore,
            finish,
        };
        const Family = enum { node, scope, key };
        b: B,
        actual: encoding.Actual,
        memory: if (fixed_storage) pools.Context else r.Memory,
        cancellation: Hook,
        interval: u32,
        polling: Polling = .{},
        total_work: u64 = 0,
        outcome: ?Outcome = null,
        taken: bool = false,
        phase: Phase = .count,
        index: u32 = 0,
        allocation: u8 = 0,
        counted_mentions: u64 = 0,
        counted_connections: u64 = 0,
        counted_attributes: u64 = 0,
        iterator: syntax.EdgeLinkIterator,
        occurrence: u32 = 0,
        enter_id: u32 = 0,
        enter_stage: u2 = 0,
        overlay_root: u32 = none,
        overlay_cursor: u32 = none,
        overlay_path: [48]u32 = undefined,
        overlay_depth: u8 = 0,
        overlay_next: u32 = none,
        setting: p.Set = undefined,
        mutable_from: u32 = 0,
        reference: syntax.NodeReference = undefined,
        node_view: syntax.NodeReferenceView = undefined,
        node_for_declaration: bool = false,
        port_index: u2 = 0,
        endpoint_value: syntax.Endpoint = undefined,
        node_value: t.Endpoint = undefined,
        edge: syntax.EdgeView = undefined,
        edge_pending: u32 = 0,
        range: syntax.AttributeRange = .{},
        original_range: syntax.AttributeRange = .{},
        copy_index: u32 = 0,
        copy_after: Phase = .declaration,
        target: @FieldType(t.Declaration, "target") = undefined,
        kind: attrs.Kind = .node,
        origin: attrs.Origin = undefined,
        attribute_index: u32 = 0,
        bind_after: Phase = .apply,
        apply_local: bool = false,
        family: Family = .node,
        name: t.Range = .{ .start = 0, .len = 0 },
        hash: u64 = 0,
        hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),
        reader: p.Name(caps) = .{},
        comparison: p.Name(caps) = .{},
        left_byte: ?u8 = null,
        left_end: bool = false,
        slot: u32 = 0,
        intern_id: u32 = 0,
        intern_after: Phase = .node_done,
        new_slots: []u32 = &.{},
        table_index: u32 = 0,
        rehash_id: u32 = 0,
        scope_parent: t.ScopeId = .root,
        gap_value: coverage.Gap = undefined,
        gap_after: Phase = .walk,
        unfinished_scope: ?t.OccurrenceId = null,
        suffix_first: u32 = 0,
        node_growth: p.ReserveFor(t.Node, fixed_storage, "nodes") = .{},
        scope_growth: p.ReserveFor(t.Scope, fixed_storage, "scopes") = .{},
        declaration_growth: p.ReserveFor(t.Declaration, fixed_storage, "declarations") = .{},
        frame_growth: p.ReserveFor(std.meta.Elem(@FieldType(@FieldType(B, "stack"), "items")), fixed_storage, "stack") = .{},
        // Field types below are derived from the shared arrays, not duplicate
        // frame definitions or a second public event vocabulary.
        edge_growth: p.ReserveFor(std.meta.Elem(@FieldType(@FieldType(B, "edge_stack"), "items")), fixed_storage, "edge_stack") = .{},
        pending_growth: p.ReserveFor(std.meta.Elem(@FieldType(@FieldType(B, "pending"), "items")), fixed_storage, "pending") = .{},
        key_growth: p.ReserveFor(attrs.Key, fixed_storage, "keys") = .{},
        cell_growth: p.ReserveFor(attrs.Cell, fixed_storage, "cells") = .{},
        gap_growth: p.ReserveFor(coverage.Entry, fixed_storage, "gaps") = .{},

        pub fn init(a: if (fixed_storage) pools.Context else std.mem.Allocator, doc: *const syntax.Document, interpretation: lower.InterpretationFor(partial), limits: r.Limits, cancellation: Hook, interval: u32) r.Error!Self {
            // The fixed boundary polls before validating caller regions. Do not
            // poll twice for that single constructor checkpoint.
            if (cancellable and !fixed_storage) if (cancellation) |c| if (c.requested()) return error.Cancelled;
            if (!partial and !doc.scopeComplete()) return error.IncompleteDocument;
            if (doc.strict and (interpretation.kind == .generic or (partial and interpretation.kind == null))) return error.UnsupportedSemantics;
            const actual = names.reader(caps, doc.source_info.encoding);
            if (!caps.allows(actual)) return error.UnsupportedEncoding;
            _ = try r.index(doc.source.len);
            _ = try r.index(doc.order.len);
            var result: Self = .{
                .b = .{ .a = if (fixed_storage) undefined else a, .doc = doc, .interpretation = interpretation, .limits = limits, .work = .{ .remaining = 0, .cancellation = null } },
                .actual = actual,
                .memory = if (fixed_storage) a else .{ .backing = a, .limit = limits.max_bytes },
                .cancellation = cancellation,
                .interval = interval,
                .iterator = .{ .document = doc },
            };
            if (fixed_storage) result.b.bindFixed(&result.memory);
            return result;
        }
        pub fn deinit(self: *Self) void {
            if (fixed_storage) {
                self.* = undefined;
                return;
            }
            const a = self.memory.allocator();
            self.b.a = a;
            inline for (.{ "node_growth", "scope_growth", "declaration_growth", "frame_growth", "edge_growth", "pending_growth", "key_growth", "cell_growth", "gap_growth" }) |field| @field(self, field).deinit(a);
            storage.release(u32, a, self.new_slots);
            self.b.deinit();
            self.* = undefined;
        }
        pub fn peakBytes(self: *const Self) usize {
            return if (fixed_storage) self.memory.layout.graph_bytes + self.memory.layout.scratch_bytes else self.memory.peak;
        }
        pub fn cancel(self: *Self) void {
            if (self.outcome == null) self.outcome = .{ .failure = error.Cancelled };
        }
        fn poll(self: *Self) bool {
            return @import("execution_policy.zig").pollSession(self, cancellable);
        }
        pub fn advance(self: *Self, budget: u32) Progress {
            var used: u32 = 0;
            if (self.outcome == null and self.poll()) {
                self.b.a = if (fixed_storage) &self.memory else self.memory.allocator();
                self.polling = .{};
                _ = self.polling.due(self.interval); // Entry poll covers the first credit.
                while (used < budget and self.outcome == null) {
                    if (self.total_work == self.b.limits.max_work) {
                        if (used == 0 or self.poll()) self.outcome = .{ .failure = error.WorkLimit };
                        break;
                    }
                    if (used != 0 and self.polling.due(self.interval) and !self.poll()) break;
                    used += 1;
                    self.total_work += 1;
                    self.polling.spend(1);
                    self.step() catch |err| {
                        self.outcome = .{ .failure = if (fixed_storage) err else self.memory.failure(err) };
                    };
                }
            }
            return .{ .work_used = used, .total_work = self.total_work, .nodes_created = @intCast(self.b.nodes.items.len), .connections_created = self.b.connection_count, .outcome = self.outcome };
        }
        pub fn run(self: *Self) Progress {
            while (true) {
                const result = self.advance(std.math.maxInt(u32));
                if (result.outcome != null) return result;
            }
        }
        pub fn takeResult(self: *Self) TakeError!Result {
            const outcome = self.outcome orelse return error.NotReady;
            if (outcome == .failure) return outcome.failure;
            if (self.taken) return error.AlreadyTaken;
            self.taken = true;
            self.b.a = if (fixed_storage) &self.memory else self.memory.allocator();
            return self.b.publish();
        }
        fn startName(self: *Self, family: Family, name: t.Range, after: Phase) r.Error!void {
            self.family = family;
            self.name = name;
            self.intern_after = after;
            self.reader = .{ .raw = try self.b.raw(name), .actual = self.actual };
            self.hasher = std.hash.Wyhash.init(0);
            self.phase = .intern_hash;
        }
        fn table(self: *Self) *names.Table {
            return switch (self.family) {
                .node => &self.b.node_table,
                .scope => &self.b.scope_table,
                .key => &self.b.attribute_data.table,
            };
        }
        fn storedHash(self: *Self, id: u32) u64 {
            return switch (self.family) {
                .node => self.b.nodes.items[id].hash,
                .scope => self.b.scopes.items[id].hash,
                .key => self.b.attribute_data.keys.items[id].hash,
            };
        }
        fn storedName(self: *Self, id: u32) t.Range {
            return switch (self.family) {
                .node => self.b.nodes.items[id].name,
                .scope => self.b.scopes.items[id].name.?,
                .key => self.b.attribute_data.keys.items[id].name,
            };
        }
        fn beginEnter(self: *Self, id: u32) void {
            self.enter_id = id;
            self.enter_stage = 0;
            self.phase = .enter;
        }
        fn copyRange(self: *Self, range: syntax.AttributeRange, after: Phase) r.Error!void {
            if (range.start > self.b.doc.attributes.len or range.len > self.b.doc.attributes.len - range.start) return error.InvalidDocument;
            self.range = range;
            if (!partial) {
                self.phase = after;
                return;
            }
            if (range.len > self.b.attributes.len - self.b.attribute_count) return error.InvalidDocument;
            self.original_range = range;
            self.range.start = self.b.attribute_count;
            self.copy_index = 0;
            self.copy_after = after;
            self.phase = .copy_range;
        }
        fn applyRoot(self: *Self) *u32 {
            const scope = &self.b.attribute_data.scopes[@backingInt(self.b.occurrences[self.occurrence].scope)];
            return switch (self.target) {
                .node => |id| &self.b.nodes.items[@backingInt(id)].attribute_state,
                .graph_assignment => &scope.graph,
                .defaults => |kind| switch (kind) {
                    .graph => &scope.graph,
                    .node => if (self.apply_local) &scope.local_node else &scope.node,
                    .edge => if (self.apply_local) &scope.local_edge else &scope.edge,
                },
            };
        }
        fn step(self: *Self) r.Error!void {
            const b = &self.b;
            const a = b.a;
            const doc = b.doc;
            switch (self.phase) {
                .count => {
                    if (self.index == doc.order.len) {
                        if (self.counted_mentions > b.limits.max_mentions) return error.MentionLimit;
                        if (self.counted_connections > b.limits.max_connections) return error.ConnectionLimit;
                        if (!partial) self.counted_attributes = @as(u64, doc.attributes.len) + doc.assignments.len;
                        if (self.counted_attributes > b.limits.max_attributes) return error.AttributeLimit;
                        if (self.counted_attributes >= @import("ports.zig").right) return error.IndexLimit;
                        const count = try r.index(doc.subgraph_records.len + 1);
                        if (count >= t.node_bit) return error.IndexLimit;
                        if (count > b.limits.max_scopes) return error.ScopeLimit;
                        self.phase = .allocate;
                        self.index = 0;
                        return;
                    }
                    const statement = doc.statementAt(self.index);
                    self.index += 1;
                    if (statement) |s| {
                        if (partial) self.counted_attributes += switch (s) {
                            .node => |n| n.attributes.len,
                            .edge, .edge_chain => B.firstEdge(s).attributes.len,
                            .attribute_statement => |v| v.attributes.len,
                            .assignment => 1,
                            else => 0,
                        };
                        switch (s) {
                            .node => self.counted_mentions += 1,
                            .edge, .edge_chain => {
                                const edge = B.firstEdge(s);
                                self.counted_mentions += @as(u64, @intFromBool(edge.left == .node)) + @intFromBool(edge.right == .node);
                                self.counted_connections += 1;
                                self.iterator = b.links(s);
                                self.phase = .count_links;
                            },
                            else => {},
                        }
                    }
                },
                .count_links => {
                    if (self.iterator.next()) |edge| {
                        self.counted_connections += 1;
                        self.counted_mentions += @intFromBool(edge.right == .node);
                    } else self.phase = .count;
                },
                .allocate => {
                    switch (self.allocation) {
                        0 => b.occurrences = try mem.allocate(t.Occurrence, a, doc.subgraph_records.len + 1, "occurrences", true),
                        1 => b.bodies = try mem.allocate(t.Body, a, b.occurrences.len, "bodies", true),
                        2 => b.mentions = try mem.allocate(t.Mention, a, @intCast(self.counted_mentions), "mentions", true),
                        3 => b.connections = try mem.allocate(t.Connection, a, @intCast(self.counted_connections), "connections", true),
                        4 => b.attributes = try mem.allocate(syntax.Attribute, a, @intCast(self.counted_attributes), "attributes", true),
                        else => {
                            if (!try self.scope_growth.step(&b.scopes, 1, a)) return;
                            b.scopes.appendAssumeCapacity(.{ .parent = null, .name = doc.name, .first_occurrence = .root, .hash = 0 });
                            b.occurrences[0] = .{ .scope = .root, .parent = null, .source = .{ .start = 0, .len = @intCast(doc.source.len) }, .membership = undefined };
                            self.index = 1;
                            self.phase = .scope;
                            if (comptime caps.utf16 or caps.utf32) if (self.actual != .ascii and self.actual != .utf8) if (doc.name) |name| {
                                self.reader = .{ .raw = try b.raw(name), .actual = self.actual };
                                self.phase = .root_name;
                            };
                            return;
                        },
                    }
                    self.allocation += 1;
                },
                .root_name => if (comptime caps.utf16 or caps.utf32) switch (try self.reader.step()) {
                    .end => self.phase = .scope,
                    .pending, .byte => {},
                } else unreachable,
                .scope => {
                    if (self.index == b.occurrences.len) {
                        b.cursors = try mem.allocate(std.meta.Elem(@FieldType(B, "cursors")), a, b.scopes.items.len, "cursors", true);
                        self.index = 0;
                        self.phase = .cursor_clear;
                        return;
                    }
                    const record = doc.subgraph_records[self.index - 1];
                    const parent = @backingInt(record.parent);
                    if (parent >= self.index) return error.InvalidDocument;
                    self.scope_parent = b.occurrences[parent].scope;
                    if (record.name) |name| try self.startName(.scope, name, .scope_done) else {
                        self.family = .scope;
                        self.hash = 0;
                        self.intern_after = .scope_done;
                        self.phase = .intern_append;
                    }
                },
                .scope_done => {
                    const record = doc.subgraph_records[self.index - 1];
                    const source = if (partial) doc.scope(@fromBackingInt(self.index)).?.sourceRange() orelse return error.InvalidDocument else record.source;
                    b.occurrences[self.index] = .{ .scope = @fromBackingInt(self.intern_id), .parent = @fromBackingInt(@backingInt(record.parent)), .source = source, .membership = undefined };
                    self.index += 1;
                    self.phase = .scope;
                },
                .cursor_clear => {
                    if (self.index == b.cursors.len) {
                        self.index = 0;
                        self.phase = .cursor_count;
                        return;
                    }
                    b.cursors[self.index] = .{};
                    self.index += 1;
                },
                .cursor_count => {
                    if (self.index == b.occurrences.len) {
                        self.index = 0;
                        self.slot = 0;
                        self.phase = .cursor_prefix;
                        return;
                    }
                    b.cursors[@backingInt(b.occurrences[self.index].scope)].next += 1;
                    self.index += 1;
                },
                .cursor_prefix => {
                    if (self.index == b.cursors.len) {
                        self.index = 0;
                        self.phase = .cursor_assign;
                        return;
                    }
                    const cursor = &b.cursors[self.index];
                    const count = cursor.next;
                    cursor.first = self.slot;
                    cursor.next = self.slot;
                    self.slot += count;
                    self.index += 1;
                },
                .cursor_assign => {
                    if (self.index == b.occurrences.len) {
                        self.index = 0;
                        self.allocation = 0;
                        self.phase = .data_allocate;
                        return;
                    }
                    const occurrence = &b.occurrences[self.index];
                    const cursor = &b.cursors[@backingInt(occurrence.scope)];
                    occurrence.membership = @fromBackingInt(cursor.next);
                    b.bodies[cursor.next] = .{ .start = 0, .end = 0, .first = cursor.first };
                    cursor.next += 1;
                    self.index += 1;
                },
                .data_allocate => {
                    if (b.attributes.len == 0) {
                        self.beginEnter(0);
                        return;
                    }
                    switch (self.allocation) {
                        0 => b.attribute_data.meta = try mem.allocate(attrs.Meta, a, b.attributes.len, "meta", true),
                        1 => b.attribute_data.scopes = try mem.allocate(attrs.Scope, a, b.scopes.items.len, "attribute_scopes", true),
                        2 => b.attribute_data.connection_defaults = try mem.allocate(u32, a, b.connections.len, "connection_defaults", true),
                        else => {
                            self.phase = if (partial) .meta_clear else .copy_attributes;
                            return;
                        },
                    }
                    self.allocation += 1;
                },
                .copy_attributes => {
                    if (self.index == doc.attributes.len) {
                        b.attribute_count = self.index;
                        self.index = 0;
                        self.phase = .meta_clear;
                        return;
                    }
                    b.attributes[self.index] = doc.attributes[self.index];
                    self.index += 1;
                },
                .meta_clear => {
                    if (self.index == b.attribute_data.meta.len) {
                        self.index = 0;
                        self.phase = .scope_clear;
                        return;
                    }
                    b.attribute_data.meta[self.index] = .{};
                    self.index += 1;
                },
                .scope_clear => {
                    if (self.index == b.attribute_data.scopes.len) {
                        self.beginEnter(0);
                        return;
                    }
                    b.attribute_data.scopes[self.index] = .{};
                    self.index += 1;
                },
                .enter => {
                    if (self.enter_id >= b.occurrences.len) return error.InvalidDocument;
                    const id = @backingInt(b.occurrences[self.enter_id].scope);
                    if (b.attribute_data.scopes.len == 0 or id == 0 or self.enter_stage == 2) {
                        self.phase = .enter_push;
                        return;
                    }
                    const parent = b.attribute_data.scopes[@backingInt(b.scopes.items[id].parent.?)];
                    const scope = &b.attribute_data.scopes[id];
                    if (self.enter_stage == 0 and @backingInt(b.scopes.items[id].first_occurrence) == self.enter_id) scope.graph = parent.graph;
                    const changed = if (self.enter_stage == 0) scope.parent_node != parent.node else scope.parent_edge != parent.edge;
                    if (!changed) {
                        self.enter_stage += 1;
                        return;
                    }
                    self.overlay_root = if (self.enter_stage == 0) parent.node else parent.edge;
                    self.overlay_cursor = if (self.enter_stage == 0) scope.local_node else scope.local_edge;
                    self.overlay_depth = 0;
                    self.mutable_from = try r.index(b.attribute_data.cells.items.len);
                    self.phase = .enter_overlay;
                },
                .enter_overlay => {
                    if (self.overlay_cursor != none) {
                        if (self.overlay_depth == self.overlay_path.len) return error.IndexLimit;
                        self.overlay_path[self.overlay_depth] = self.overlay_cursor;
                        self.overlay_depth += 1;
                        self.overlay_cursor = b.attribute_data.cells.items[self.overlay_cursor].left;
                    } else if (self.overlay_depth != 0) {
                        self.overlay_depth -= 1;
                        const cell = b.attribute_data.cells.items[self.overlay_path[self.overlay_depth]];
                        self.overlay_next = cell.right;
                        self.setting = p.Set.init(self.overlay_root, cell.key, cell.attribute);
                        self.phase = .enter_overlay_set;
                    } else {
                        const id = @backingInt(b.occurrences[self.enter_id].scope);
                        const parent = b.attribute_data.scopes[@backingInt(b.scopes.items[id].parent.?)];
                        const scope = &b.attribute_data.scopes[id];
                        if (self.enter_stage == 0) {
                            scope.node = self.overlay_root;
                            scope.parent_node = parent.node;
                        } else {
                            scope.edge = self.overlay_root;
                            scope.parent_edge = parent.edge;
                        }
                        self.enter_stage += 1;
                        self.phase = .enter;
                    }
                },
                .enter_overlay_set => if (try self.setting.step(&b.attribute_data, &self.cell_growth, a, b.limits.max_attribute_states, self.mutable_from)) |root| {
                    self.overlay_root = root;
                    self.overlay_cursor = self.overlay_next;
                    self.phase = .enter_overlay;
                },
                .enter_push => {
                    if (!try self.frame_growth.step(&b.stack, 1, a)) return;
                    const body = try b.scopeBody(self.enter_id);
                    if (body.start > doc.order.len or body.len > doc.order.len - body.start) return error.InvalidDocument;
                    if (partial and self.enter_id != 0) {
                        if (self.enter_id != b.publication.next_scope) return error.InvalidDocument;
                        b.publication.next_scope += 1;
                    }
                    b.bodies[@backingInt(b.occurrences[self.enter_id].membership)].start = b.mention_count;
                    b.stack.appendAssumeCapacity(.{ .scope = .{ .occurrence = self.enter_id, .cursor = body.start, .end = body.start + body.len } });
                    if (fixed_storage) a.observe("stack", b.stack.items.len);
                    self.phase = .walk;
                },
                .walk => {
                    if (b.stack.items.len == 0) {
                        self.index = 0;
                        if (partial) {
                            if (b.publication.next_scope != b.occurrences.len) return error.InvalidDocument;
                            self.unfinished_scope = if (!doc.root_closed) .root else null;
                            self.phase = .unfinished;
                        } else self.phase = .posting_allocate;
                        return;
                    }
                    const last = b.stack.items.len - 1;
                    switch (b.stack.items[last]) {
                        .scope => |frame| {
                            self.occurrence = frame.occurrence;
                            if (partial and b.publication.next_scope < b.occurrences.len) {
                                const child = doc.subgraph_records[b.publication.next_scope - 1];
                                if (@backingInt(child.parent) == frame.occurrence and child.body.start <= frame.cursor) {
                                    const body = try b.scopeBody(b.publication.next_scope);
                                    b.stack.items[last].scope.cursor = @max(frame.cursor, body.start + body.len);
                                    self.beginEnter(b.publication.next_scope);
                                    return;
                                }
                            }
                            if (frame.cursor == frame.end) {
                                const occurrence = b.occurrences[frame.occurrence];
                                const body = @backingInt(occurrence.membership);
                                b.bodies[body].end = b.mention_count;
                                b.cursors[@backingInt(occurrence.scope)].head = body;
                                _ = b.stack.pop();
                                return;
                            }
                            if (frame.cursor > frame.end) return error.InvalidDocument;
                            const statement = doc.statementAt(frame.cursor) orelse {
                                if (!partial) return error.InvalidDocument;
                                b.stack.items[last].scope.cursor += 1;
                                const slot = doc.order[frame.cursor];
                                if (slot == .skipped_start) {
                                    if (frame.cursor + 1 >= frame.end) return error.InvalidDocument;
                                    const end = doc.order[frame.cursor + 1];
                                    if (end != .skipped_end or end.skipped_end < slot.skipped_start or end.skipped_end > doc.source.len) return error.InvalidDocument;
                                    b.stack.items[last].scope.cursor += 1;
                                    self.gap_value = .{ .reason = .skipped_input, .range = .{ .start = slot.skipped_start, .len = end.skipped_end - slot.skipped_start }, .occurrence = @fromBackingInt(frame.occurrence) };
                                    self.gap_after = .walk;
                                    self.phase = .gap;
                                }
                                return;
                            };
                            // Reserve before advancing the enclosing cursor.
                            if (statement == .edge or statement == .edge_chain) {
                                if (!try self.edge_growth.step(&b.edge_stack, 1, a)) return;
                                if (!try self.frame_growth.step(&b.stack, 1, a)) return;
                            }
                            b.stack.items[last].scope.cursor += 1;
                            switch (statement) {
                                .node => |value| {
                                    self.reference = value.reference;
                                    self.range = value.attributes;
                                    self.node_for_declaration = true;
                                    self.phase = .node_start;
                                },
                                .subgraph => |id| {
                                    b.stack.items[last].scope.cursor = @max(frame.cursor + 1, try b.endpointEnd(.{ .subgraph = id }));
                                    self.beginEnter(@backingInt(id));
                                },
                                .edge, .edge_chain => {
                                    const first = B.firstEdge(statement);
                                    b.stack.items[last].scope.cursor = @max(frame.cursor + 1, @max(try b.endpointEnd(first.left), try b.endpointEnd(first.right)));
                                    const edge_index = try r.index(b.edge_stack.items.len);
                                    b.edge_stack.appendAssumeCapacity(.{ .occurrence = frame.occurrence, .first = first, .links = b.links(statement), .pending_start = try r.index(b.pending.items.len), .statement_index = frame.cursor });
                                    b.stack.appendAssumeCapacity(.{ .edge = edge_index });
                                    if (fixed_storage) {
                                        a.observe("edge_stack", b.edge_stack.items.len);
                                        a.observe("stack", b.stack.items.len);
                                    }
                                    self.iterator = b.links(statement);
                                    self.phase = .chain_scan;
                                },
                                .attribute_statement => |v| {
                                    self.target = .{ .defaults = v.target };
                                    try self.copyRange(v.attributes, .declaration);
                                },
                                .assignment => |attribute| {
                                    if (b.attribute_count >= b.attributes.len) return error.InvalidDocument;
                                    b.attributes[b.attribute_count] = attribute;
                                    self.range = .{ .start = b.attribute_count, .len = 1 };
                                    b.attribute_count += 1;
                                    self.target = .graph_assignment;
                                    self.phase = .declaration;
                                },
                            }
                        },
                        .edge => |id| {
                            const frame = &b.edge_stack.items[id];
                            self.occurrence = frame.occurrence;
                            if (frame.phase == 0) {
                                frame.phase = 1;
                                self.endpoint_value = frame.first.left;
                                self.phase = .endpoint;
                            } else if (frame.phase == 1) {
                                frame.phase = 2;
                                self.endpoint_value = frame.first.right;
                                self.phase = .endpoint;
                            } else if (frame.links.next()) |edge| {
                                self.endpoint_value = edge.right;
                                self.phase = .endpoint;
                            } else {
                                self.edge_pending = frame.pending_start;
                                self.edge = frame.first;
                                self.iterator = b.links(doc.statementAt(frame.statement_index).?);
                                try self.copyRange(frame.first.attributes, .edge_finish);
                            }
                        },
                    }
                },
                .chain_scan => {
                    if (self.iterator.next()) |edge| {
                        const frame = &b.stack.items[b.stack.items.len - 2].scope;
                        frame.cursor = @max(frame.cursor, try b.endpointEnd(edge.right));
                    } else self.phase = .walk;
                },
                .node_start => {
                    self.node_view = doc.nodeReference(self.reference) orelse return error.InvalidDocument;
                    self.port_index = 0;
                    self.phase = .node_port;
                },
                .node_port => {
                    if (self.actual != .utf8 and self.actual != .ascii) if (self.node_view.port) |port| {
                        const range = switch (self.port_index) {
                            0 => port.first,
                            1 => port.second,
                            else => null,
                        };
                        if (range) |value| {
                            if (self.port_index == 1 and value.start < port.first.start + port.first.len) return error.InvalidDocument;
                            self.reader = .{ .raw = try b.raw(value), .actual = self.actual };
                            self.port_index += 1;
                            self.phase = .bind_value;
                            self.bind_after = .node_port;
                            return;
                        }
                    };
                    try self.startName(.node, self.node_view.identifier, .node_done);
                },
                .node_done => {
                    if (b.mention_count >= b.mentions.len) return error.InvalidDocument;
                    b.mentions[b.mention_count] = .{ .node = @fromBackingInt(self.intern_id), .source = self.node_view.identifier, .occurrence = @fromBackingInt(self.occurrence) };
                    b.mention_count += 1;
                    self.node_value = .{ .members = @fromBackingInt(t.node_bit | self.intern_id), .port = self.node_view.port };
                    if (self.node_for_declaration) {
                        self.target = .{ .node = @fromBackingInt(self.intern_id) };
                        try self.copyRange(self.range, .declaration);
                    } else self.phase = .pending_node;
                },
                .endpoint => switch (self.endpoint_value) {
                    .node => |reference| {
                        self.reference = reference;
                        self.node_for_declaration = false;
                        self.phase = .node_start;
                    },
                    .subgraph => |scope| {
                        const id = @backingInt(scope);
                        if (id == 0 or id >= b.occurrences.len) return error.InvalidDocument;
                        self.enter_id = id;
                        self.phase = .pending_scope;
                    },
                },
                .pending_node => {
                    if (!try self.pending_growth.step(&b.pending, 1, a)) return;
                    b.pending.appendAssumeCapacity(.{ .node = self.node_value });
                    if (fixed_storage) a.observe("pending", b.pending.items.len);
                    self.phase = .walk;
                },
                .pending_scope => {
                    if (!try self.pending_growth.step(&b.pending, 1, a)) return;
                    b.pending.appendAssumeCapacity(.{ .scope = b.occurrences[self.enter_id].scope });
                    if (fixed_storage) a.observe("pending", b.pending.items.len);
                    self.beginEnter(self.enter_id);
                },
                .edge_finish => {
                    self.edge.attributes = self.range;
                    self.phase = .edge_emit;
                },
                .edge_emit => {
                    const with_attributes = b.attribute_data.scopes.len != 0;
                    const id = try b.storeConnection(self.edge.operator, self.edge.operator_range, self.occurrence, b.pending.items[self.edge_pending], b.pending.items[self.edge_pending + 1], self.range, with_attributes);
                    if (with_attributes) {
                        self.origin = .{ .connection = id };
                        self.kind = .edge;
                        self.attribute_index = self.range.start;
                        self.bind_after = .edge_bound;
                        self.phase = .bind;
                    } else self.phase = .edge_bound;
                },
                .edge_bound => {
                    b.connection_count += 1;
                    self.edge_pending += 1;
                    self.phase = .edge_next;
                },
                .edge_next => {
                    if (self.iterator.next()) |edge| {
                        self.edge = edge;
                        self.phase = .edge_emit;
                    } else {
                        const frame = b.edge_stack.pop().?;
                        // These are private, already-consumed records. Avoid
                        // shrinkRetainingCapacity's source-sized Debug poison.
                        b.pending.items.len = frame.pending_start;
                        _ = b.stack.pop();
                        self.phase = .walk;
                    }
                },
                .copy_range => {
                    if (self.copy_index == self.range.len) {
                        self.phase = self.copy_after;
                        return;
                    }
                    b.attributes[b.attribute_count] = doc.attributes[self.original_range.start + self.copy_index];
                    b.attribute_count += 1;
                    self.copy_index += 1;
                },
                .declaration => {
                    if (!try self.declaration_growth.step(&b.declarations, 1, a)) return;
                    self.origin = .{ .declaration = try r.index(b.declarations.items.len) };
                    b.declarations.appendAssumeCapacity(.{ .target = self.target, .occurrence = @fromBackingInt(self.occurrence), .attributes = self.range });
                    if (self.range.len == 0) {
                        self.phase = .walk;
                        return;
                    }
                    self.kind = switch (self.target) {
                        .node => .node,
                        .graph_assignment => .graph,
                        .defaults => |v| switch (v) {
                            .graph => .graph,
                            .node => .node,
                            .edge => .edge,
                        },
                    };
                    self.attribute_index = self.range.start;
                    self.bind_after = .apply;
                    self.apply_local = false;
                    self.phase = .bind;
                },
                .bind => {
                    if (self.attribute_index == self.range.start + self.range.len) {
                        self.attribute_index = self.range.start;
                        self.phase = self.bind_after;
                        return;
                    }
                    if (b.attribute_data.meta[self.attribute_index].key != none) {
                        self.attribute_index += 1;
                        return;
                    }
                    try self.startName(.key, b.attributes[self.attribute_index].key, .bind_done);
                },
                .bind_done => {
                    b.attribute_data.meta[self.attribute_index] = .{ .key = self.intern_id, .origin = self.origin };
                    if (self.actual != .utf8 and self.actual != .ascii) {
                        self.reader = .{ .raw = try b.raw(b.attributes[self.attribute_index].value), .actual = self.actual };
                        self.phase = .bind_value;
                    } else {
                        self.attribute_index += 1;
                        self.phase = .bind;
                    }
                },
                .bind_value => {
                    if (try self.reader.step() == .end) {
                        if (self.bind_after == .node_port) self.phase = .node_port else {
                            self.attribute_index += 1;
                            self.phase = .bind;
                        }
                    }
                },
                .apply => {
                    if (self.attribute_index == self.range.start) self.mutable_from = try r.index(b.attribute_data.cells.items.len);
                    if (self.attribute_index == self.range.start + self.range.len) {
                        self.phase = .apply_next;
                        return;
                    }
                    self.setting = p.Set.init(self.applyRoot().*, b.attribute_data.meta[self.attribute_index].key, self.attribute_index);
                    self.phase = .apply_set;
                },
                .apply_set => if (try self.setting.step(&b.attribute_data, &self.cell_growth, a, b.limits.max_attribute_states, self.mutable_from)) |root| {
                    self.applyRoot().* = root;
                    self.attribute_index += 1;
                    self.phase = .apply;
                },
                .apply_next => {
                    if (!self.apply_local and self.target == .defaults and self.target.defaults != .graph and b.occurrences[self.occurrence].scope != .root) {
                        self.apply_local = true;
                        self.attribute_index = self.range.start;
                        self.phase = .apply;
                    } else self.phase = .walk;
                },
                .intern_hash => switch (try self.reader.step()) {
                    .pending => {},
                    .byte => |byte| self.hasher.update(&.{byte}),
                    .end => {
                        self.hash = self.hasher.final();
                        if (self.family == .scope) {
                            const parent = @backingInt(self.scope_parent);
                            self.hash = std.hash.Wyhash.hash(self.hash, std.mem.asBytes(&parent));
                        }
                        if (self.family == .key) self.hash ^= @as(u64, @backingInt(self.kind));
                        const slots = self.table().slots;
                        self.slot = if (slots.len == 0) 0 else @intCast(self.hash & (slots.len - 1));
                        self.phase = .intern_probe;
                    },
                },
                .intern_probe => {
                    const slots = self.table().slots;
                    if (slots.len == 0 or slots[self.slot] == none) {
                        self.phase = .intern_prepare;
                        return;
                    }
                    const id = slots[self.slot];
                    const compatible = switch (self.family) {
                        .node => true,
                        .scope => b.scopes.items[id].parent.? == self.scope_parent,
                        .key => b.attribute_data.keys.items[id].kind == self.kind,
                    };
                    if (compatible and self.storedHash(id) == self.hash) {
                        self.intern_id = id;
                        self.reader = .{ .raw = try b.raw(self.name), .actual = self.actual };
                        self.comparison = .{ .raw = try b.raw(self.storedName(id)), .actual = self.actual };
                        self.left_byte = null;
                        self.left_end = false;
                        self.phase = .intern_equal;
                    } else self.slot = @intCast((self.slot + 1) & (slots.len - 1));
                },
                .intern_equal => {
                    if (self.left_byte == null and !self.left_end) {
                        switch (try self.reader.step()) {
                            .pending => {},
                            .byte => |v| self.left_byte = v,
                            .end => self.left_end = true,
                        }
                        return;
                    }
                    const next = try self.comparison.step();
                    if (next == .pending) return;
                    if (next == .end and self.left_end) {
                        self.phase = self.intern_after;
                        return;
                    }
                    if (next == .byte and !self.left_end and self.left_byte.? == next.byte) self.left_byte = null else {
                        self.slot = @intCast((self.slot + 1) & (self.table().slots.len - 1));
                        self.phase = .intern_probe;
                    }
                },
                .intern_prepare => {
                    const table_value = self.table();
                    if (table_value.slots.len != 0 and table_value.count < table_value.slots.len / 2) {
                        self.phase = .intern_append;
                        return;
                    }
                    if (fixed_storage) {
                        if (self.family == .node and b.nodes.items.len >= b.limits.max_nodes) return error.NodeLimit;
                        self.new_slots = switch (self.family) {
                            inline else => |family| blk: {
                                const field = switch (family) {
                                    .node => "node_slots",
                                    .scope => "scope_slots",
                                    .key => "key_slots",
                                };
                                try a.ensureTable(field, table_value.count + 1);
                                break :blk a.slice(field);
                            },
                        };
                    } else {
                        const capacity = if (table_value.slots.len == 0) 16 else std.math.mul(usize, table_value.slots.len, 2) catch return error.IndexLimit;
                        if (capacity > std.math.maxInt(u32)) return error.IndexLimit;
                        self.new_slots = try storage.allocate(u32, a, capacity);
                    }
                    self.table_index = 0;
                    self.phase = .table_clear;
                },
                .table_clear => {
                    if (self.table_index == self.new_slots.len) {
                        self.table_index = 0;
                        self.phase = .rehash_scan;
                        return;
                    }
                    const end = @min(self.new_slots.len, @as(usize, self.table_index) + 16);
                    @memset(self.new_slots[self.table_index..end], none);
                    self.table_index = @intCast(end);
                },
                .rehash_scan => {
                    const slots = self.table().slots;
                    if (self.table_index == slots.len) {
                        if (!fixed_storage) storage.release(u32, a, slots);
                        self.table().slots = self.new_slots;
                        self.new_slots = &.{};
                        // Growth invalidates the empty slot found by lookup.
                        self.slot = @intCast(self.hash & (self.table().slots.len - 1));
                        self.phase = .intern_append;
                        return;
                    }
                    self.rehash_id = slots[self.table_index];
                    self.table_index += 1;
                    if (self.rehash_id != none) {
                        self.slot = @intCast(self.storedHash(self.rehash_id) & (self.new_slots.len - 1));
                        self.phase = .rehash_probe;
                    }
                },
                .rehash_probe => {
                    if (self.new_slots[self.slot] == none) {
                        self.new_slots[self.slot] = self.rehash_id;
                        self.phase = .rehash_scan;
                    } else self.slot = @intCast((self.slot + 1) & (self.new_slots.len - 1));
                },
                .intern_append => {
                    switch (self.family) {
                        .node => {
                            if (b.nodes.items.len >= b.limits.max_nodes) return error.NodeLimit;
                            self.intern_id = try r.index(b.nodes.items.len);
                            if (self.intern_id >= t.node_bit) return error.IndexLimit;
                            if (!try self.node_growth.step(&b.nodes, 1, a)) return;
                            const state = if (b.attribute_data.scopes.len == 0) none else b.attribute_data.scopes[@backingInt(b.occurrences[self.occurrence].scope)].node;
                            b.nodes.appendAssumeCapacity(.{ .name = self.name, .first_mention = b.mention_count, .attribute_state = state, .hash = self.hash });
                        },
                        .scope => {
                            if (!try self.scope_growth.step(&b.scopes, 1, a)) return;
                            self.intern_id = try r.index(b.scopes.items.len);
                            const name = doc.subgraph_records[self.index - 1].name;
                            b.scopes.appendAssumeCapacity(.{ .parent = self.scope_parent, .name = name, .first_occurrence = @fromBackingInt(self.index), .hash = self.hash });
                            if (name == null) {
                                self.phase = self.intern_after;
                                return;
                            }
                        },
                        .key => {
                            if (!try self.key_growth.step(&b.attribute_data.keys, 1, a)) return;
                            self.intern_id = try r.index(b.attribute_data.keys.items.len);
                            b.attribute_data.keys.appendAssumeCapacity(.{ .name = self.name, .hash = self.hash, .first_attribute = self.attribute_index, .kind = self.kind });
                        },
                    }
                    // Without index growth, lookup already located an empty
                    // slot. Keep it across bounded record-list growth as well.
                    self.phase = .intern_insert;
                },
                .intern_insert => {
                    const slots = self.table().slots;
                    if (slots[self.slot] == none) {
                        slots[self.slot] = self.intern_id;
                        self.table().count += 1;
                        self.phase = self.intern_after;
                    } else self.slot = @intCast((self.slot + 1) & (slots.len - 1));
                },
                .gap => if (partial) {
                    if (!try self.gap_growth.step(&b.publication.coverage_data.entries, 1, a)) return;
                    b.publication.coverage_data.entries.appendAssumeCapacity(.{ .gap = self.gap_value, .boundary = try r.index(b.declarations.items.len), .connection_boundary = b.connection_count });
                    self.phase = self.gap_after;
                } else unreachable,
                .unfinished => if (partial) {
                    if (self.index < doc.subgraph_records.len) {
                        if (doc.subgraph_records[self.index].subtree_end == 0) self.unfinished_scope = @fromBackingInt(self.index + 1);
                        self.index += 1;
                        return;
                    }
                    self.index = @intCast(b.publication.coverage_data.entries.items.len);
                    self.phase = .gap_suffix;
                    if (doc.unrepresented() != null or self.unfinished_scope != null or (!doc.scopeComplete() and self.index == 0)) {
                        self.gap_value = .{ .reason = .unfinished_input, .range = doc.unrepresented() orelse .{ .start = @intCast(doc.source.len), .len = 0 }, .occurrence = self.unfinished_scope };
                        self.index += 1;
                        self.gap_after = .gap_suffix;
                        self.phase = .gap;
                    }
                } else unreachable,
                .gap_suffix => if (partial) {
                    if (self.index == 0) {
                        self.phase = .posting_allocate;
                        return;
                    }
                    self.index -= 1;
                    const entries = b.publication.coverage_data.entries.items;
                    if (self.index + 1 == entries.len or entries[self.index].gap.range.start <= entries[self.suffix_first].gap.range.start) self.suffix_first = self.index;
                    entries[self.index].suffix_first = self.suffix_first;
                } else unreachable,
                .posting_allocate => {
                    if (b.mention_count != b.mentions.len or b.connection_count != b.connections.len or b.attribute_count != b.attributes.len) return error.InvalidDocument;
                    if (b.offsets.len == 0) b.offsets = try mem.allocate(u32, a, b.nodes.items.len + 1, "offsets", true) else {
                        b.positions = try mem.allocate(u32, a, b.mentions.len, "positions", true);
                        self.index = 0;
                        self.phase = .posting_clear;
                    }
                },
                .posting_clear => {
                    if (self.index == b.offsets.len) {
                        self.index = 0;
                        self.phase = .posting_count;
                        return;
                    }
                    b.offsets[self.index] = 0;
                    self.index += 1;
                },
                .posting_count => {
                    if (self.index == b.mentions.len) {
                        self.index = 1;
                        self.phase = .posting_prefix;
                        return;
                    }
                    b.offsets[@backingInt(b.mentions[self.index].node) + 1] += 1;
                    self.index += 1;
                },
                .posting_prefix => {
                    if (self.index == b.offsets.len) {
                        self.index = 0;
                        self.phase = .posting_fill;
                        return;
                    }
                    b.offsets[self.index] += b.offsets[self.index - 1];
                    self.index += 1;
                },
                .posting_fill => {
                    if (self.index == b.mentions.len) {
                        self.index = @intCast(b.offsets.len - 1);
                        self.phase = .posting_restore;
                        return;
                    }
                    const cursor = &b.offsets[@backingInt(b.mentions[self.index].node)];
                    b.positions[cursor.*] = self.index;
                    cursor.* += 1;
                    self.index += 1;
                },
                .posting_restore => {
                    if (self.index == 0) {
                        b.offsets[0] = 0;
                        self.phase = .finish;
                        return;
                    }
                    b.offsets[self.index] = b.offsets[self.index - 1];
                    self.index -= 1;
                },
                .finish => self.outcome = .success,
            }
        }
    };
}

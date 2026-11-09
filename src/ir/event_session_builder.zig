//! Bounded event consumption. Shares staging records, publication, name
//! interning and attribute-map primitives with the existing construction paths.
const std = @import("std");
const support = @import("parser_support");
const e = @import("../dot/events.zig");
const syntax = @import("../dot/syntax.zig");
const policy = @import("../dot/policy.zig");
const direct = @import("event_builder.zig");
const r = @import("resources.zig");
const t = @import("topology.zig");
const attrs = @import("attributes.zig");
const names = @import("names.zig");
const p = @import("lowering_primitives.zig");
const storage = @import("session_storage.zig");
const Slice = @import("event_session_storage.zig").SliceFor;
const checking = @import("event_validation_session.zig");
const none = std.math.maxInt(u32);
const Span = support.location.Span;
fn Item(comptime Owner: type, comptime field: []const u8) type {
    return std.meta.Elem(@FieldType(@FieldType(Owner, field), "items"));
}

pub fn Builder(comptime rep: @import("representation.zig").Identity, comptime fixed: ?policy.ValidationSettings, comptime partial: bool) type {
    return BuilderWith(rep, fixed, partial, void);
}
pub fn BuilderWith(comptime rep: @import("representation.zig").Identity, comptime fixed: ?policy.ValidationSettings, comptime partial: bool, comptime Context: type) type {
    const fixed_storage = Context != void;
    const Memory = if (fixed_storage) *Context else std.mem.Allocator;
    const D = direct.BuilderWith(.utf8, rep, fixed, partial, Context);
    const B = @FieldType(D, "b");
    const Statement = Item(D, "statements");
    const Pending = Item(B, "pending");
    const Endpoint = @FieldType(Pending, "node");
    const Partial = @FieldType(D, "aborted");
    return struct {
        const Self = @This();
        pub const Error = D.Error;
        const Phase = enum {
            idle,
            flush,
            receive,
            begin_statement,
            begin_scope,
            scope_done,
            scope_arrays,
            scope_install,
            commit,
            validate_attributes,
            validate_assignment,
            validate_reference,
            validate_links,
            commit_done,
            replay,
            enter,
            enter_overlay,
            enter_overlay_set,
            enter_push,
            node_start,
            node_done,
            node_port,
            node_end,
            pending_node,
            pending_scope,
            copy_attributes,
            attributes_init,
            attributes_scope_clear,
            attributes_defaults_clear,
            copy_attribute,
            declaration,
            bind,
            bind_done,
            bind_value,
            apply,
            apply_set,
            apply_next,
            connect,
            connection_bound,
            chain_next,
            flat_first,
            flat_right,
            flat_next,
            gap,
            prefix,
            prefix_link,
            partial_start,
            partial_scopes,
            partial_flush,
            partial_end,
            gap_suffix,
            finish_kind,
            finish_encoding,
            finish_start,
            release_stage,
            compact,
            strict_connections,
            group_clear,
            group_count,
            group_prefix,
            group_assign,
            group_rewrite,
            posting_allocate,
            posting_clear,
            posting_count,
            posting_prefix,
            posting_fill,
            posting_restore,
            indexes,
            joined_allocate,
            joined_connections,
            joined_ports,
            checked,
            done,
            // Fixed-only state: preserve the existing phase values and hot
            // dispatch layout of allocator-backed construction.
            group_copy,
            intern_hash,
            intern_probe,
            intern_equal,
            intern_prepare,
            table_clear,
            rehash_scan,
            rehash_probe,
            intern_append,
            intern_insert,
        };
        d: D,
        phase: Phase = .idle,
        event: e.Event = undefined,
        substep: u8 = 0,
        after: Phase = .idle,
        scope_name: ?Span = null,
        scope_source: Span = .{ .start = 0, .len = 0 },
        scope_parent_occurrence: ?u32 = null,
        scope_parent: t.ScopeId = .root,
        scope_id: u32 = 0,
        known_scopes: u32 = 0,
        occurrence: u32 = 0,
        statement: u32 = 0,
        current_link: u32 = none,
        scoped: bool = false,
        prefix_end: u32 = 0,
        prefix_edge: e.Edge = undefined,
        enter_id: u32 = 0,
        enter_stage: u2 = 0,
        overlay_root: u32 = none,
        overlay_cursor: u32 = none,
        overlay_depth: u8 = 0,
        overlay_path: [48]u32 = undefined,
        overlay_next: u32 = none,
        node_view: syntax.NodeReferenceView = undefined,
        node_value: Endpoint = undefined,
        keep_port: bool = false,
        node_after: Phase = .idle,
        pending_start: u32 = 0,
        pending_cursor: u32 = 0,
        left: Pending = undefined,
        right: Pending = undefined,
        operator: syntax.EdgeOperator = .directed,
        operator_span: Span = .{ .start = 0, .len = 0 },
        connect_after: Phase = .replay,
        group: []const syntax.Attribute = &.{},
        range: syntax.AttributeRange = .{},
        copy_after: Phase = .replay,
        copy_index: u32 = 0,
        target: @FieldType(t.Declaration, "target") = undefined,
        kind: attrs.Kind = .node,
        origin: attrs.Origin = undefined,
        attribute_index: u32 = 0,
        bind_after: Phase = .apply,
        apply_after: Phase = .replay,
        apply_local: bool = false,
        setting: p.Set = undefined,
        mutable_from: u32 = 0,
        family: enum { node, scope, key } = .node,
        actual: support.encoding.Actual = .utf8,
        name: Span = .{ .start = 0, .len = 0 },
        hash: u64 = 0,
        hasher: std.hash.Wyhash = .init(0),
        reader: p.Name(rep.encodings) = .{},
        comparison: p.Name(rep.encodings) = .{},
        left_byte: ?u8 = null,
        left_end: bool = false,
        slot: u32 = 0,
        intern_id: u32 = 0,
        intern_after: Phase = .node_done,
        new_slots: []u32 = &.{},
        table_index: u32 = 0,
        rehash_id: u32 = 0,
        validation: checking.AttributesFor(fixed_storage) = .{},
        encoding: checking.Encoding = undefined,
        facts: e.Coverage = .{},
        complete: bool = false,
        unfinished: ?t.OccurrenceId = null,
        gap_value: @import("coverage.zig").Gap = undefined,
        gap_after: Phase = .replay,
        index: u32 = 0,
        suffix_first: u32 = 0,
        compact_index: u8 = 0,
        grouped: []t.Body = &.{},
        grouped_base: u32 = 0,
        indexer: if (rep.indexes.any()) @import("query_indexes.zig").Builder(rep.indexes) else void = if (rep.indexes.any()) .{} else {},
        joined: ?@TypeOf(@import("topology_storage.zig").allocate(t.ConnectionFor(rep.attributes), undefined, 0, 0, true) catch unreachable) = null,
        stage_growth: Slice(Statement, fixed_storage, "statements") = .{},
        stage_scope_growth: Slice(Item(D, "stage_scopes"), fixed_storage, "stage_scopes") = .{},
        stage_attribute_growth: Slice(syntax.Attribute, fixed_storage, "stage_attributes") = .{},
        stage_link_growth: Slice(Item(D, "stage_links"), fixed_storage, "stage_links") = .{},
        stage_port_growth: Slice(syntax.NodeReferenceView, fixed_storage, "stage_ports") = .{},
        replay_growth: Slice(Item(D, "replay"), fixed_storage, "replay") = .{},
        partial_statement_growth: if (partial) Slice(Item(Partial, "statements"), fixed_storage, "partial_statements") else void = if (partial) .{} else {},
        partial_scope_growth: if (partial) Slice(Item(Partial, "scopes"), fixed_storage, "partial_scopes") else void = if (partial) .{} else {},
        node_growth: Slice(t.NodeFor(rep.attributes), fixed_storage, "nodes") = .{},
        scope_growth: Slice(t.Scope, fixed_storage, "scopes") = .{},
        key_growth: if (rep.attributes) Slice(attrs.Key, fixed_storage, "keys") else void = if (rep.attributes) .{} else {},
        cell_growth: if (rep.attributes) Slice(attrs.Cell, fixed_storage, "cells") else void = if (rep.attributes) .{} else {},
        declaration_growth: if (rep.attributes) Slice(t.Declaration, fixed_storage, "declarations") else void = if (rep.attributes) .{} else {},
        occurrence_growth: Slice(t.Occurrence, fixed_storage, "occurrences") = .{},
        body_growth: Slice(t.Body, fixed_storage, "bodies") = .{},
        cursor_growth: Slice(std.meta.Elem(@FieldType(B, "cursors")), fixed_storage, "cursors") = .{},
        mention_growth: Slice(t.Mention, fixed_storage, "mentions") = .{},
        connection_growth: Slice(t.ConnectionFor(rep.attributes), fixed_storage, "connections") = .{},
        port_growth: Slice(syntax.PortSyntax, fixed_storage, "endpoint_ports") = .{},
        attribute_growth: if (rep.attributes) Slice(syntax.Attribute, fixed_storage, "attributes") else void = if (rep.attributes) .{} else {},
        meta_growth: if (rep.attributes) Slice(attrs.Meta, fixed_storage, "meta") else void = if (rep.attributes) .{} else {},
        attribute_scope_growth: if (rep.attributes) Slice(attrs.Scope, fixed_storage, "attribute_scopes") else void = if (rep.attributes) .{} else {},
        defaults_growth: if (rep.attributes) Slice(u32, fixed_storage, "connection_defaults") else void = if (rep.attributes) .{} else {},
        pending_growth: Slice(Pending, fixed_storage, "pending") = .{},
        gap_growth: if (partial) Slice(@import("coverage.zig").EntryFor(rep.attributes), fixed_storage, "gaps") else void = if (partial) .{} else {},

        pub fn init(a: Memory, source: []const u8, info: support.encoding.Info, limits: r.Limits, settings: policy.ValidationSettings, sink: @import("../dot/diagnostic.zig").Sink) r.Error!Self {
            return .{ .d = try D.init(a, source, info, limits, null, settings, sink) };
        }
        pub fn deinit(self: *Self) void {
            if (fixed_storage) return;
            const a = self.d.b.a;
            self.validation.deinit(a);
            inline for (@typeInfo(Self).@"struct".field_names) |field| {
                if (comptime std.mem.endsWith(u8, field, "_growth") and @FieldType(Self, field) != void) @field(self, field).deinit(a);
            }
            storage.release(u32, a, self.new_slots);
            storage.release(t.Body, a, self.grouped);
            if (self.joined) |joined| @import("topology_storage.zig").release(a, joined);
            self.d.deinit();
        }
        pub fn bind(self: *Self, a: Memory) void {
            self.d.b.a = a;
            self.d.b.doc = &self.d.header;
        }
        pub fn accept(self: *Self, event: e.Event) void {
            std.debug.assert(self.phase == .idle);
            self.event = event;
            self.substep = 0;
            self.phase = .receive;
        }
        pub fn abort(self: *Self, reason: e.Abort) void {
            self.d.onAbort(reason);
        }
        pub fn idle(self: *const Self) bool {
            return self.phase == .idle;
        }
        pub fn hashing(self: *const Self) bool {
            return self.phase == .intern_hash;
        }
        /// Execute the same single-unit hash steps without routing each byte
        /// through the composition or full semantic switch. No callouts occur
        /// here; the caller caps this run by work, grant and polling allowance.
        pub fn advanceHash(self: *Self, allowance: u32) struct { used: u32, failure: ?r.Error = null } {
            var used: u32 = 0;
            while (used < allowance and self.phase == .intern_hash) {
                used += 1;
                @import("lowering_intern.zig").step(rep, fixed_storage, Phase.intern_hash, self) catch |err| return .{ .used = used, .failure = err };
            }
            return .{ .used = used };
        }
        pub fn phaseKind(self: *const Self) enum { stage, validate, replay, finalize } {
            return switch (self.phase) {
                .receive, .begin_statement, .begin_scope, .scope_done, .scope_arrays, .scope_install => .stage,
                .commit, .validate_attributes, .validate_assignment, .validate_reference, .validate_links, .commit_done, .prefix, .prefix_link, .finish_kind, .finish_encoding => .validate,
                .partial_start, .partial_scopes, .partial_flush, .partial_end, .gap_suffix, .finish_start, .release_stage, .compact, .strict_connections, .group_clear, .group_count, .group_prefix, .group_assign, .group_rewrite, .group_copy, .posting_allocate, .posting_clear, .posting_count, .posting_prefix, .posting_fill, .posting_restore, .indexes, .joined_allocate, .joined_connections, .joined_ports, .done => .finalize,
                else => .replay,
            };
        }
        pub fn internBuilder(self: *Self) *B {
            return &self.d.b;
        }
        pub fn internScopeName(self: *Self) ?Span {
            return self.scope_name;
        }
        pub fn internScopeOccurrence(self: *Self) u32 {
            return self.d.occurrence_count;
        }
        pub fn table(self: *Self) *names.Table {
            return switch (self.family) {
                .node => &self.d.b.node_table,
                .scope => &self.d.b.scope_table,
                .key => if (rep.attributes) &self.d.b.attribute_data.table else unreachable,
            };
        }
        pub fn storedHash(self: *Self, id: u32) u64 {
            return switch (self.family) {
                .node => self.d.b.nodes.items[id].hash,
                .scope => self.d.b.scopes.items[id].hash,
                .key => if (rep.attributes) self.d.b.attribute_data.keys.items[id].hash else unreachable,
            };
        }
        pub fn storedName(self: *Self, id: u32) Span {
            return switch (self.family) {
                .node => self.d.b.nodes.items[id].name,
                .scope => self.d.b.scopes.items[id].name.?,
                .key => if (rep.attributes) self.d.b.attribute_data.keys.items[id].name else unreachable,
            };
        }
        pub fn startName(self: *Self, family: @FieldType(Self, "family"), name: Span, after: Phase) r.Error!void {
            self.family = family;
            self.name = name;
            self.intern_after = after;
            self.reader = .{ .raw = try self.d.b.raw(name), .actual = self.actual };
            self.hasher = .init(0);
            self.phase = .intern_hash;
        }
        fn beginScope(self: *Self, parent: ?u32, name: ?Span, span: Span) void {
            self.known_scopes = @intCast(self.d.b.scopes.items.len);
            self.scope_parent_occurrence = parent;
            self.scope_parent = if (parent) |id| self.d.b.occurrences[id].scope else .root;
            self.scope_name = name;
            self.scope_source = span;
            self.phase = .begin_scope;
        }
        fn beginReplay(self: *Self, id: u32) Error!void {
            if (!try self.replay_growth.step(&self.d.replay, 1, self.d.b.a)) return;
            self.d.replay.appendAssumeCapacity(.{ .statement = id });
            self.phase = .replay;
        }
        fn beginNode(self: *Self, reference: syntax.NodeReferenceView, occurrence: u32, keep_port: bool, after: Phase) void {
            self.node_view = reference;
            self.occurrence = occurrence;
            self.keep_port = keep_port;
            self.node_after = after;
            self.phase = .node_start;
        }
        fn beginEnter(self: *Self, occurrence: u32) void {
            self.enter_id = occurrence;
            self.enter_stage = 0;
            self.phase = .enter;
        }
        fn copyAttributes(self: *Self, group: []const syntax.Attribute, after: Phase) void {
            self.group = group;
            self.copy_after = after;
            self.copy_index = 0;
            self.phase = .copy_attributes;
        }
        pub fn applyAfter(self: *Self) Phase {
            return self.apply_after;
        }
        pub fn applyRoot(self: *Self) *u32 {
            const scope = &self.d.b.attribute_data.scopes[@backingInt(self.d.b.occurrences[self.occurrence].scope)];
            return switch (self.target) {
                .node => |id| &self.d.b.nodes.items[@backingInt(id)].attribute_state,
                .graph_assignment => &scope.graph,
                .defaults => |kind| switch (kind) {
                    .graph => &scope.graph,
                    .node => if (self.apply_local) &scope.local_node else &scope.node,
                    .edge => if (self.apply_local) &scope.local_edge else &scope.edge,
                },
            };
        }
        fn beginGap(self: *Self, gap: @import("coverage.zig").Gap, after: Phase) void {
            self.gap_value = gap;
            self.gap_after = after;
            self.phase = .gap;
        }
        pub fn finishInput(self: *Self, facts: e.Coverage, complete: bool) void {
            std.debug.assert(self.idle());
            self.facts = facts;
            self.complete = complete;
            self.phase = if (partial) .partial_start else .finish_kind;
        }
        pub fn publish(self: *Self) @import("lower.zig").Output(rep, partial) {
            std.debug.assert(self.phase == .done);
            if (!fixed_storage) if (self.joined) |joined| {
                const b = &self.d.b;
                storage.release(t.ConnectionFor(rep.attributes), b.a, b.connections);
                storage.release(syntax.PortSyntax, b.a, b.endpoint_ports);
                b.connections = joined.connections;
                b.endpoint_ports = joined.endpoint_ports;
                self.joined = null;
            };
            return self.d.b.publish();
        }
        pub fn step(self: *Self) Error!void {
            const d = &self.d;
            const b = &d.b;
            const a = b.a;
            switch (self.phase) {
                .idle, .done => {},
                .receive => {
                    if (!partial and d.aborted) {
                        self.phase = .idle;
                        return;
                    }
                    switch (self.event) {
                        .begin_document => |value| {
                            d.header = .{ .source = d.header.source, .source_info = value.source_info, .kind = if (value.kind == .digraph) .digraph else .undigraph, .strict = value.strict, .name = if (value.name_span) |name| name.span() else null };
                            d.keyword = value.keyword_span;
                            const interpretation = direct.interpretation(d.header.kind, d.checker.settings(), false);
                            b.interpretation = .{ .kind = interpretation.kind, .directed = interpretation.directed, .undirected = interpretation.undirected };
                            self.beginScope(null, d.header.name, .{ .start = 0, .len = try r.index(d.header.source.len) });
                        },
                        .begin_statement => |value| {
                            // Capacity-growth estimates have no role in fixed
                            // storage. Keep the receive step and its credit.
                            if (!fixed_storage and d.current == 0) {
                                const remaining = d.header.source.len - @backingInt(value.owner.statement);
                                d.header.node_capacity_bound = bound(b.nodes.items.len, remaining);
                                d.mention_bound = bound(b.mention_count, remaining);
                                d.connection_bound = bound(b.connection_count, remaining);
                                if (rep.attributes) d.attribute_bound = bound(b.attribute_count, remaining);
                            }
                            self.occurrence = @backingInt(value.owner.scope);
                            self.after = .idle;
                            self.phase = .begin_statement;
                        },
                        .begin_scope => |value| {
                            if (@backingInt(value.id) != d.occurrence_count) return error.InvalidDocument;
                            self.beginScope(@backingInt(value.parent), if (value.name) |name| name.span() else null, value.start);
                        },
                        .end_scope => |value| {
                            b.occurrences[@backingInt(value.id)].source.len = @intCast(value.close.endOffset() - b.occurrences[@backingInt(value.id)].source.start);
                            if (partial) d.aborted.scopes.items[d.current].closed = true;
                            d.current = d.stage_scopes.items[d.current].parent;
                            if (partial) d.aborted.statements.items[d.active()].certified_end = @intCast(value.close.endOffset());
                            self.phase = .idle;
                        },
                        .attribute => |value| {
                            if (!try self.stage_attribute_growth.step(&d.stage_attributes, 1, a)) return;
                            const index = try r.index(d.stage_attributes.items.len);
                            d.stage_attributes.appendAssumeCapacity(attribute(value.pair));
                            const stmt = &d.statements.items[d.active()];
                            if (stmt.attributes.len == 0) stmt.attributes.start = index;
                            stmt.attributes.len += 1;
                            self.phase = .idle;
                        },
                        .ported_reference => |value| {
                            if (@backingInt(value.id) != d.next_reference) return error.InvalidDocument;
                            if (!try self.stage_port_growth.step(&d.stage_ports, 1, a)) return;
                            d.stage_ports.appendAssumeCapacity(.{ .identifier = value.reference.identifier.span(), .port = .{ .first = value.reference.first.span(), .second = if (value.reference.second) |name| name.span() else null } });
                            d.next_reference += 1;
                            self.phase = .idle;
                        },
                        .edge_link => |value| {
                            if (!try self.stage_link_growth.step(&d.stage_links, 1, a)) return;
                            self.appendLink(.{ .node = try d.reference(value.link.right.span(), value.link.right_port) }, convert(value.link.operator), value.link.operator_span);
                            self.phase = .idle;
                        },
                        .commit_node, .commit_edge, .commit_edge_chain, .commit_subgraph, .commit_assignment, .commit_attribute_statement => {
                            self.statement = d.active();
                            d.statements.items[self.statement].value = switch (self.event) {
                                .commit_node => |value| .{ .node = value.value },
                                .commit_edge, .commit_edge_chain => |value| .{ .edge = value.value },
                                .commit_subgraph => |value| .{ .scope = @backingInt(value.value) },
                                .commit_assignment => |value| .{ .assignment = attribute(value.value) },
                                .commit_attribute_statement => |value| .{ .defaults = switch (value.value.target) {
                                    .graph => .graph,
                                    .node => .node,
                                    .edge => .edge,
                                } },
                                else => unreachable,
                            };
                            self.phase = .commit;
                        },
                        .end_document => {
                            b.bodies[0].end = b.mention_count;
                            b.cursors[0].head = 0;
                            self.phase = .idle;
                        },
                        .skipped => |value| if (partial) {
                            if (d.stage_scopes.items.len == 0 or d.active() == none) {
                                self.occurrence = @backingInt(value.scope);
                                self.after = .receive;
                                self.phase = .begin_statement;
                                return;
                            }
                            self.statement = d.active();
                            d.aborted.statements.items[self.statement].gap = value.span;
                            d.stage_scopes.items[d.current].active = none;
                            self.after = .idle;
                            self.phase = if (d.current == 0) .flush else .idle;
                        } else {
                            d.aborted = true;
                            self.phase = .idle;
                        },
                        else => self.phase = .idle,
                    }
                },
                .begin_statement => {
                    if (d.stage_scopes.items.len == 0) {
                        if (!try self.stage_scope_growth.step(&d.stage_scopes, 1, a)) return;
                        if (partial) if (!try self.partial_scope_growth.step(&d.aborted.scopes, 1, a)) return;
                        d.stage_scopes.appendAssumeCapacity(.{ .occurrence = 0 });
                        if (partial) d.aborted.scopes.appendAssumeCapacity(.{});
                        return;
                    }
                    if (!try self.stage_growth.step(&d.statements, 1, a)) return;
                    if (partial) if (!try self.partial_statement_growth.step(&d.aborted.statements, 1, a)) return;
                    const id = try r.index(d.statements.items.len);
                    d.statements.appendAssumeCapacity(.{ .occurrence = self.occurrence });
                    if (partial) d.aborted.statements.appendAssumeCapacity(.{});
                    const scope = &d.stage_scopes.items[d.current];
                    if (scope.last != none) d.statements.items[scope.last].next = id else scope.first = id;
                    scope.last = id;
                    scope.active = id;
                    self.phase = self.after;
                },
                .begin_scope => {
                    if (d.occurrence_count >= b.limits.max_scopes) return error.ScopeLimit;
                    if (d.occurrence_count >= t.node_bit) return error.IndexLimit;
                    if (self.scope_parent_occurrence == null) {
                        if (!try self.scope_growth.step(&b.scopes, 1, a)) return;
                        b.scopes.appendAssumeCapacity(.{ .parent = null, .name = self.scope_name, .first_occurrence = .root, .hash = 0 });
                        self.intern_id = 0;
                        self.phase = .scope_done;
                    } else if (self.scope_name) |name| try self.startName(.scope, name, .scope_done) else {
                        self.family = .scope;
                        self.hash = 0;
                        self.intern_after = .scope_done;
                        self.phase = .intern_append;
                    }
                },
                .scope_done => {
                    self.scope_id = self.intern_id;
                    self.phase = .scope_arrays;
                },
                .scope_arrays => {
                    if (!try self.cursor_growth.reserve(a, &b.cursors, self.known_scopes, b.scopes.items.len, b.limits.max_scopes)) return;
                    if (rep.attributes and b.attribute_data.scopes.len != 0) if (!try self.attribute_scope_growth.reserve(a, &b.attribute_data.scopes, self.known_scopes, b.scopes.items.len, b.limits.max_scopes)) return;
                    if (!try self.occurrence_growth.reserve(a, &b.occurrences, d.occurrence_count, @as(usize, d.occurrence_count) + 1, b.limits.max_scopes)) return;
                    if (!try self.body_growth.reserve(a, &b.bodies, d.occurrence_count, @as(usize, d.occurrence_count) + 1, b.limits.max_scopes)) return;
                    if (self.scope_id >= self.known_scopes) {
                        b.cursors[self.scope_id] = .{};
                        if (rep.attributes and b.attribute_data.scopes.len != 0) b.attribute_data.scopes[self.scope_id] = .{};
                    }
                    self.scope_id = d.occurrence_count;
                    b.occurrences[self.scope_id] = .{ .scope = @fromBackingInt(self.intern_id), .parent = if (self.scope_parent_occurrence) |parent| @fromBackingInt(parent) else null, .source = self.scope_source, .membership = @fromBackingInt(self.scope_id) };
                    b.bodies[self.scope_id] = .{ .start = 0, .end = 0, .first = 0 };
                    d.occurrence_count += 1;
                    self.phase = .scope_install;
                },
                .scope_install => {
                    if (self.scope_parent_occurrence == null) {
                        self.phase = .idle;
                        return;
                    }
                    const value = self.event.begin_scope;
                    if (!try self.stage_scope_growth.step(&d.stage_scopes, 1, a)) return;
                    if (partial) if (!try self.partial_scope_growth.step(&d.aborted.scopes, 1, a)) return;
                    if (value.role == .link) {
                        if (!try self.stage_link_growth.step(&d.stage_links, 1, a)) return;
                        self.appendLink(.{ .scope = self.scope_id }, convert(value.link_operator.?), value.link_operator_span.?);
                    }
                    const child = try r.index(d.stage_scopes.items.len);
                    d.stage_scopes.appendAssumeCapacity(.{ .occurrence = self.scope_id, .parent = d.current });
                    if (partial) {
                        d.aborted.scopes.appendAssumeCapacity(.{});
                        const owner = &d.aborted.statements.items[d.active()];
                        if (!owner.prefix) if (value.edge) |prefix| {
                            d.statements.items[d.active()].value = .{ .edge = prefix };
                            owner.prefix = true;
                        };
                        owner.certified_end = @intCast(value.start.endOffset());
                        if (owner.last_child != none) d.aborted.scopes.items[owner.last_child].next = child else owner.first_child = child;
                        owner.last_child = child;
                    }
                    d.current = child;
                    try d.checker.restriction(d.checker.settings().restrictions.subgraphs, value.start, .subgraph);
                    self.phase = .idle;
                },
                .commit => {
                    const stmt = d.statements.items[self.statement];
                    self.validation.start(d.stage_attributes.items[stmt.attributes.start..][0..stmt.attributes.len]);
                    self.phase = .validate_attributes;
                },
                .validate_attributes => if (try self.validation.step(&d.checker, a)) {
                    if (d.statements.items[self.statement].value == .assignment) {
                        self.validation.start((&d.statements.items[self.statement].value.assignment)[0..1]);
                        self.phase = .validate_assignment;
                    } else self.phase = .validate_reference;
                },
                .validate_assignment => if (try self.validation.step(&d.checker, a)) {
                    self.phase = .commit_done;
                },
                .validate_reference => {
                    const stmt = d.statements.items[self.statement];
                    switch (stmt.value) {
                        .node => |node| try d.checkReference(try d.reference(node.identifier.span(), node.port)),
                        .edge => |edge| {
                            const left = try d.endpoint(edge, true);
                            const right = try d.endpoint(edge, false);
                            self.scoped = left == .scope or right == .scope;
                            if (left == .node) try d.checkReference(left.node);
                            if (right == .node) try d.checkReference(right.node);
                            try d.checkOperator(convert(edge.operator), edge.operator_span);
                            self.current_link = stmt.first_link;
                            self.phase = .validate_links;
                            return;
                        },
                        else => {},
                    }
                    self.phase = .commit_done;
                },
                .validate_links => {
                    if (self.current_link == none) {
                        if (self.scoped) {
                            const edge = d.statements.items[self.statement].value.edge;
                            d.statements.items[self.statement].value = .{ .scoped_edge = edge };
                        }
                        self.phase = .commit_done;
                        return;
                    }
                    const link = d.stage_links.items[self.current_link];
                    self.scoped = self.scoped or link.right == .scope;
                    if (link.right == .node) try d.checkReference(link.right.node);
                    try d.checkOperator(link.operator, link.span);
                    self.current_link = link.next;
                },
                .commit_done => {
                    if (partial) d.aborted.statements.items[self.statement].committed = true;
                    self.after = .idle;
                    self.phase = if (d.current == 0) .flush else .idle;
                    if (partial and d.current != 0) d.stage_scopes.items[d.current].active = none;
                },
                .flush => try self.beginReplay(self.statement),
                .replay => {
                    if (d.replay.items.len == 0) {
                        d.resetStage(true);
                        self.phase = self.after;
                        return;
                    }
                    const top = d.replay.items.len - 1;
                    switch (d.replay.items[top]) {
                        .scope => |frame| {
                            if (frame.statement == none) {
                                b.bodies[frame.scope].end = b.mention_count;
                                b.cursors[@backingInt(b.occurrences[frame.scope].scope)].head = frame.scope;
                                _ = d.replay.pop();
                            } else {
                                if (!try self.replay_growth.step(&d.replay, 1, a)) return;
                                d.replay.items[top].scope.statement = d.statements.items[frame.statement].next;
                                d.replay.appendAssumeCapacity(.{ .statement = frame.statement });
                            }
                        },
                        .statement => |id| {
                            self.statement = id;
                            if (partial and !d.aborted.statements.items[id].committed) {
                                const state = &d.aborted.statements.items[id];
                                if (state.prefix) {
                                    self.prefix_edge = d.statements.items[id].value.edge;
                                    self.prefix_end = state.certified_end;
                                    state.prefix = false;
                                    self.phase = .prefix;
                                    return;
                                }
                                if (state.first_child != none) {
                                    const child = state.first_child;
                                    state.first_child = d.aborted.scopes.items[child].next;
                                    self.beginEnter(d.stage_scopes.items[child].occurrence);
                                } else {
                                    _ = d.replay.pop();
                                    if (state.gap) |gap| self.beginGap(.{ .reason = .skipped_input, .range = gap, .occurrence = @fromBackingInt(d.statements.items[id].occurrence) }, .replay);
                                }
                                return;
                            }
                            const stmt = d.statements.items[id];
                            _ = d.replay.pop();
                            self.occurrence = stmt.occurrence;
                            const group = d.stage_attributes.items[stmt.attributes.start..][0..stmt.attributes.len];
                            switch (stmt.value) {
                                .scope => |scope| self.beginEnter(scope),
                                .scoped_edge => {
                                    // Reuse the popped frame's capacity. Every endpoint
                                    // scope executes before its frozen membership is read.
                                    d.replay.appendAssumeCapacity(.{ .edge = .{ .statement = id, .link = stmt.first_link, .pending = try r.index(b.pending.items.len) } });
                                },
                                .node => |node| {
                                    self.group = group;
                                    self.copy_after = .declaration;
                                    self.copy_index = 0;
                                    self.beginNode(try d.reference(node.identifier.span(), node.port), stmt.occurrence, false, .copy_attributes);
                                },
                                .defaults => |target| {
                                    self.target = .{ .defaults = target };
                                    self.copyAttributes(group, .declaration);
                                },
                                .assignment => {
                                    self.target = .graph_assignment;
                                    self.copyAttributes((&d.statements.items[id].value.assignment)[0..1], .declaration);
                                },
                                .edge => self.copyAttributes(group, .flat_first),
                                .pending => return error.InvalidDocument,
                            }
                        },
                        .edge => |frame| {
                            self.statement = frame.statement;
                            const stmt = d.statements.items[frame.statement];
                            const edge = stmt.value.scoped_edge;
                            self.occurrence = stmt.occurrence;
                            if (frame.phase < 2) {
                                d.replay.items[top].edge.phase += 1;
                                self.takeEndpoint(if (frame.phase == 0) try d.endpoint(edge, true) else try d.endpoint(edge, false));
                            } else if (frame.link != none) {
                                const link = d.stage_links.items[frame.link];
                                d.replay.items[top].edge.link = link.next;
                                self.takeEndpoint(link.right);
                            } else {
                                self.pending_start = frame.pending;
                                self.pending_cursor = frame.pending;
                                self.left = b.pending.items[frame.pending];
                                self.right = b.pending.items[frame.pending + 1];
                                self.current_link = stmt.first_link;
                                self.operator = convert(edge.operator);
                                self.operator_span = edge.operator_span;
                                self.connect_after = .chain_next;
                                self.copyAttributes(d.stage_attributes.items[stmt.attributes.start..][0..stmt.attributes.len], .connect);
                            }
                        },
                    }
                },
                inline .enter, .enter_overlay, .enter_overlay_set => |phase| try @import("lowering_attribute_steps.zig").enter(rep, phase, self),
                .enter_push => {
                    if (!try self.replay_growth.step(&d.replay, 1, a)) return;
                    const local = self.enter_id - d.scope_base + 1;
                    b.bodies[self.enter_id].start = b.mention_count;
                    d.replay.appendAssumeCapacity(.{ .scope = .{ .scope = self.enter_id, .statement = d.stage_scopes.items[local].first } });
                    self.phase = .replay;
                },
                .node_start => {
                    if (b.mention_count >= b.limits.max_mentions) return error.MentionLimit;
                    try self.startName(.node, self.node_view.identifier, .node_done);
                },
                .node_done => {
                    if (!try self.mention_growth.reserve(a, &b.mentions, b.mention_count, @as(usize, b.mention_count) + 1, @min(b.limits.max_mentions, d.mention_bound))) return;
                    b.mentions[b.mention_count] = .{ .node = @fromBackingInt(self.intern_id), .source = self.node_view.identifier, .occurrence = @fromBackingInt(self.occurrence) };
                    b.mention_count += 1;
                    self.node_value = .{ .members = @fromBackingInt(t.node_bit | self.intern_id) };
                    if (self.node_after == .copy_attributes) self.target = .{ .node = @fromBackingInt(self.intern_id) };
                    self.phase = .node_port;
                },
                .node_port => {
                    if (self.keep_port and self.node_view.port != null) {
                        if (!try self.port_growth.reserve(a, &b.endpoint_ports, b.port_count, @as(usize, b.port_count) + 1, std.math.maxInt(u32) - 1)) return;
                        self.node_value.port = try b.storePort(self.node_view.port);
                    }
                    self.phase = .node_end;
                },
                .node_end => self.phase = self.node_after,
                .pending_node => {
                    if (!try self.pending_growth.step(&b.pending, 1, a)) return;
                    b.pending.appendAssumeCapacity(.{ .node = self.node_value });
                    self.phase = .replay;
                },
                .pending_scope => {
                    if (!try self.pending_growth.step(&b.pending, 1, a)) return;
                    b.pending.appendAssumeCapacity(.{ .scope = b.occurrences[self.enter_id].scope });
                    self.beginEnter(self.enter_id);
                },
                .copy_attributes => {
                    if (!rep.attributes or self.group.len == 0) {
                        self.range = .{};
                        self.phase = self.copy_after;
                        return;
                    }
                    if (self.group.len > b.limits.max_attributes - b.attribute_count) return error.AttributeLimit;
                    const end = b.attribute_count + @as(u32, @intCast(self.group.len));
                    if (end >= @import("ports.zig").right) return error.IndexLimit;
                    if (!try self.attribute_growth.reserve(a, &b.attributes, b.attribute_count, end, @min(b.limits.max_attributes, d.attribute_bound))) return;
                    if (!try self.meta_growth.reserve(a, &b.attribute_data.meta, b.attribute_count, end, @min(b.limits.max_attributes, d.attribute_bound))) return;
                    self.range = .{ .start = b.attribute_count, .len = @intCast(self.group.len) };
                    self.copy_index = 0;
                    self.phase = if (b.attribute_data.scopes.len == 0) .attributes_init else .copy_attribute;
                },
                .attributes_init => if (rep.attributes) {
                    if (!try self.attribute_scope_growth.reserve(a, &b.attribute_data.scopes, 0, b.scopes.items.len, b.limits.max_scopes)) return;
                    self.index = 0;
                    self.phase = .attributes_scope_clear;
                } else unreachable,
                .attributes_scope_clear => if (rep.attributes) {
                    if (self.index < b.scopes.items.len) {
                        b.attribute_data.scopes[self.index] = .{};
                        self.index += 1;
                        return;
                    }
                    if (!try self.defaults_growth.reserve(a, &b.attribute_data.connection_defaults, 0, b.connection_count, b.limits.max_connections)) return;
                    self.index = 0;
                    self.phase = .attributes_defaults_clear;
                } else unreachable,
                .attributes_defaults_clear => if (rep.attributes) {
                    if (self.index < b.connection_count) {
                        b.attribute_data.connection_defaults[self.index] = none;
                        self.index += 1;
                        return;
                    }
                    self.phase = .copy_attribute;
                } else unreachable,
                .copy_attribute => if (rep.attributes) {
                    if (self.copy_index == self.group.len) {
                        b.attribute_count += self.range.len;
                        self.phase = self.copy_after;
                        return;
                    }
                    const index = self.range.start + self.copy_index;
                    b.attributes[index] = self.group[self.copy_index];
                    b.attribute_data.meta[index] = .{};
                    self.copy_index += 1;
                } else unreachable,
                .declaration => {
                    if (!rep.attributes) {
                        self.phase = .replay;
                        return;
                    }
                    if (!try self.declaration_growth.step(&b.declarations, 1, a)) return;
                    self.origin = .{ .declaration = try r.index(b.declarations.items.len) };
                    b.declarations.appendAssumeCapacity(.{ .target = self.target, .occurrence = @fromBackingInt(self.occurrence), .attributes = self.range });
                    if (self.range.len == 0) {
                        self.phase = .replay;
                        return;
                    }
                    self.kind = switch (self.target) {
                        .node => .node,
                        .graph_assignment => .graph,
                        .defaults => |kind| switch (kind) {
                            .graph => .graph,
                            .node => .node,
                            .edge => .edge,
                        },
                    };
                    self.attribute_index = self.range.start;
                    self.bind_after = .apply;
                    self.apply_after = .replay;
                    self.apply_local = false;
                    self.phase = .bind;
                },
                inline .bind, .bind_done, .bind_value => |phase| try @import("lowering_attribute_steps.zig").bind(rep, phase, self),
                inline .apply, .apply_set, .apply_next => |phase| try @import("lowering_attribute_steps.zig").apply(rep, phase, self),
                .connect => {
                    if (b.connection_count >= b.limits.max_connections) return error.ConnectionLimit;
                    if (!try self.connection_growth.reserve(a, &b.connections, b.connection_count, @as(usize, b.connection_count) + 1, @min(b.limits.max_connections, d.connection_bound))) return;
                    const with_attributes = rep.attributes and b.attribute_data.scopes.len != 0;
                    if (rep.attributes and with_attributes) if (!try self.defaults_growth.reserve(a, &b.attribute_data.connection_defaults, b.connection_count, @as(usize, b.connection_count) + 1, b.limits.max_connections)) return;
                    const id = try b.storeConnection(self.operator, self.operator_span, self.occurrence, self.left, self.right, self.range, with_attributes);
                    if (rep.attributes and with_attributes) {
                        self.kind = .edge;
                        self.origin = .{ .connection = id };
                        self.attribute_index = self.range.start;
                        self.bind_after = .connection_bound;
                        self.phase = .bind;
                    } else self.phase = .connection_bound;
                },
                .connection_bound => {
                    b.connection_count += 1;
                    self.phase = self.connect_after;
                },
                .chain_next => {
                    if (self.current_link == none) {
                        b.pending.items.len = self.pending_start;
                        _ = d.replay.pop();
                        self.phase = .replay;
                        return;
                    }
                    const link = d.stage_links.items[self.current_link];
                    self.current_link = link.next;
                    self.pending_cursor += 1;
                    self.left = b.pending.items[self.pending_cursor];
                    self.right = b.pending.items[self.pending_cursor + 1];
                    self.operator = link.operator;
                    self.operator_span = link.span;
                    self.phase = .connect;
                },
                .flat_first => {
                    const stmt = d.statements.items[self.statement];
                    const edge = stmt.value.edge;
                    self.operator = convert(edge.operator);
                    self.operator_span = edge.operator_span;
                    self.current_link = stmt.first_link;
                    self.connect_after = .flat_next;
                    self.beginNode(try d.reference(edge.left, edge.left_port), stmt.occurrence, true, .flat_right);
                },
                .flat_right => {
                    self.left = .{ .node = self.node_value };
                    const stmt = d.statements.items[self.statement];
                    const edge = stmt.value.edge;
                    self.beginNode(try d.reference(edge.right, edge.right_port), stmt.occurrence, true, .flat_next);
                    // The first right endpoint is ready for emission next.
                    self.substep = 0;
                },
                .flat_next => {
                    if (self.substep == 0) {
                        self.right = .{ .node = self.node_value };
                        self.substep = 1;
                        self.phase = .connect;
                        return;
                    }
                    if (self.current_link == none) {
                        self.phase = .replay;
                        return;
                    }
                    const link = d.stage_links.items[self.current_link];
                    self.current_link = link.next;
                    self.left = self.right;
                    self.operator = link.operator;
                    self.operator_span = link.span;
                    self.substep = 0;
                    self.beginNode(link.right.node, self.occurrence, true, .flat_next);
                },
                .gap => if (partial) {
                    const gaps = &b.publicationState().coverage_data.entries;
                    if (!try self.gap_growth.step(gaps, 1, a)) return;
                    gaps.appendAssumeCapacity(.{ .gap = self.gap_value, .boundary = if (rep.attributes) try r.index(b.declarations.items.len) else {}, .connection_boundary = b.connection_count });
                    self.phase = self.gap_after;
                } else unreachable,
                .prefix => {
                    inline for (.{ true, false }) |left| {
                        const endpoint = try d.endpoint(self.prefix_edge, left);
                        if (endpoint == .node) try self.checkPrefixReference(endpoint.node);
                    }
                    if (self.prefix_edge.operator_span.endOffset() <= self.prefix_end) try d.checker.operator(d.header.kind, d.keyword, convert(self.prefix_edge.operator), self.prefix_edge.operator_span);
                    self.current_link = d.statements.items[self.statement].first_link;
                    self.phase = .prefix_link;
                },
                .prefix_link => {
                    if (self.current_link == none) {
                        self.phase = .replay;
                        return;
                    }
                    const link = d.stage_links.items[self.current_link];
                    self.current_link = link.next;
                    if (link.right == .node) try self.checkPrefixReference(link.right.node);
                    if (link.span.endOffset() <= self.prefix_end) try d.checker.operator(d.header.kind, d.keyword, link.operator, link.span);
                },
                inline .intern_hash, .intern_probe, .intern_equal, .intern_prepare, .table_clear, .rehash_scan, .rehash_probe, .intern_append, .intern_insert => |phase| try @import("lowering_intern.zig").step(rep, fixed_storage, phase, self),
                .partial_start => if (partial) {
                    self.unfinished = if (self.facts.root_closed) null else .root;
                    self.index = 0;
                    self.phase = .partial_scopes;
                } else unreachable,
                .partial_scopes => if (partial) {
                    if (self.index == d.stage_scopes.items.len) {
                        self.phase = .partial_flush;
                        return;
                    }
                    const scope = d.stage_scopes.items[self.index];
                    if (self.index != 0 and !d.aborted.scopes.items[self.index].closed) {
                        b.occurrences[scope.occurrence].source.len = self.facts.retained_end - b.occurrences[scope.occurrence].source.start;
                        self.unfinished = @fromBackingInt(scope.occurrence);
                    }
                    self.index += 1;
                } else unreachable,
                .partial_flush => if (partial) {
                    self.after = .partial_end;
                    if (d.stage_scopes.items.len != 0 and d.stage_scopes.items[0].first != none) {
                        self.statement = d.stage_scopes.items[0].first;
                        self.phase = .flush;
                    } else self.phase = .partial_end;
                } else unreachable,
                .partial_end => if (partial) {
                    b.bodies[0].end = b.mention_count;
                    b.cursors[0].head = 0;
                    const gaps = &b.publicationState().coverage_data.entries;
                    self.index = @intCast(gaps.items.len);
                    self.phase = .gap_suffix;
                    if (self.facts.retained_end < d.header.source.len or self.unfinished != null or (!self.complete and gaps.items.len == 0)) {
                        self.index += 1;
                        self.beginGap(.{ .reason = .unfinished_input, .range = .{ .start = self.facts.retained_end, .len = try r.index(d.header.source.len - self.facts.retained_end) }, .occurrence = self.unfinished }, .gap_suffix);
                    }
                    if (!self.complete and d.header.kind == .undigraph and d.checker.settings().graph.treated_as == .auto and b.interpretation.kind != .generic) b.interpretation.kind = null;
                    if (!self.complete) d.checker.source = d.header.source[0..self.facts.retained_end];
                } else unreachable,
                .gap_suffix => if (partial) {
                    if (self.index == 0) {
                        self.phase = .finish_kind;
                        return;
                    }
                    self.index -= 1;
                    const entries = b.publicationState().coverage_data.entries.items;
                    if (self.index + 1 == entries.len or entries[self.index].gap.range.start <= entries[self.suffix_first].gap.range.start) self.suffix_first = self.index;
                    entries[self.index].suffix_first = self.suffix_first;
                } else unreachable,
                .finish_kind => {
                    if (partial) {
                        if (b.interpretation.kind) |kind| try d.checker.graphKind(kind, d.keyword);
                    } else try d.checker.graphKind(b.interpretation.kind, d.keyword);
                    self.encoding = checking.Encoding.init(d.checker.source);
                    self.encoding.ascii = d.header.source_info.encoding == .ascii;
                    self.phase = .finish_encoding;
                },
                .finish_encoding => if (try self.encoding.step(&d.checker)) {
                    self.phase = .checked;
                },
                .checked => {}, // Admission belongs to the composed driver.
                .finish_start => {
                    if (d.semantic_failure) |failure| return failure;
                    if (d.header.strict and (b.interpretation.kind == .generic or (partial and b.interpretation.kind == null))) return error.UnsupportedSemantics;
                    self.index = 0;
                    self.phase = .release_stage;
                },
                .release_stage => {
                    if (fixed_storage) {
                        self.compact_index = 0;
                        self.phase = .compact;
                        return;
                    }
                    const fields = .{ "statements", "stage_scopes", "stage_attributes", "stage_links", "stage_ports", "replay" };
                    inline for (fields, 0..) |field, i| if (self.index == i) {
                        const list = &@field(d, field);
                        storage.release(std.meta.Elem(@TypeOf(list.items)), a, list.allocatedSlice());
                        list.* = .empty;
                        self.index += 1;
                        return;
                    };
                    switch (self.index - fields.len) {
                        0 => {
                            storage.release(Pending, a, b.pending.allocatedSlice());
                            b.pending = .empty;
                        },
                        1 => {
                            storage.release(checksEntry(), a, d.checker.entries.allocatedSlice());
                            d.checker.entries = .empty;
                        },
                        2 => if (partial) {
                            storage.release(Item(Partial, "statements"), a, d.aborted.statements.allocatedSlice());
                            d.aborted.statements = .empty;
                        },
                        3 => if (partial) {
                            storage.release(Item(Partial, "scopes"), a, d.aborted.scopes.allocatedSlice());
                            d.aborted.scopes = .empty;
                        },
                        else => {
                            self.compact_index = 0;
                            self.phase = .compact;
                            return;
                        },
                    }
                    self.index += 1;
                },
                .compact => {
                    const ready = switch (self.compact_index) {
                        0 => try self.node_growth.compactList(a, &b.nodes),
                        1 => try self.scope_growth.compactList(a, &b.scopes),
                        2 => if (rep.attributes) try self.declaration_growth.compactList(a, &b.declarations) else true,
                        3 => try self.mention_growth.compact(a, &b.mentions, b.mention_count),
                        4 => try self.connection_growth.compact(a, &b.connections, b.connection_count),
                        5 => try self.port_growth.compact(a, &b.endpoint_ports, b.port_count),
                        6 => try self.occurrence_growth.compact(a, &b.occurrences, d.occurrence_count),
                        7 => try self.body_growth.compact(a, &b.bodies, d.occurrence_count),
                        8 => if (rep.attributes) try self.attribute_growth.compact(a, &b.attributes, b.attribute_count) else true,
                        9 => if (rep.attributes) try self.meta_growth.compact(a, &b.attribute_data.meta, b.attribute_count) else true,
                        10 => if (rep.attributes and b.attribute_count != 0) try self.attribute_scope_growth.compact(a, &b.attribute_data.scopes, b.scopes.items.len) else true,
                        11 => if (rep.attributes and b.attribute_count != 0) try self.defaults_growth.compact(a, &b.attribute_data.connection_defaults, b.connection_count) else true,
                        else => {
                            self.index = 0;
                            self.phase = .strict_connections;
                            return;
                        },
                    };
                    if (ready) self.compact_index += 1;
                },
                .strict_connections => {
                    if (d.header.strict and self.index < b.connections.len) {
                        const connection = b.connections[self.index];
                        self.index += 1;
                        if ((b.interpretation.kind == .digraph) != (connection.effective_operator == .directed)) return error.UnsupportedSemantics;
                        return;
                    }
                    self.index = 0;
                    self.phase = .group_clear;
                },
                .group_clear => {
                    if (d.occurrence_count == b.scopes.items.len) {
                        if (self.index < b.bodies.len) {
                            b.bodies[self.index].first = self.index;
                            self.index += 1;
                            return;
                        }
                        self.phase = .posting_allocate;
                        return;
                    }
                    if (self.index < b.scopes.items.len) {
                        b.cursors[self.index].next = 0;
                        self.index += 1;
                        return;
                    }
                    self.index = 0;
                    self.phase = .group_count;
                },
                .group_count => {
                    if (self.index < b.occurrences.len) {
                        b.cursors[@backingInt(b.occurrences[self.index].scope)].next += 1;
                        self.index += 1;
                        return;
                    }
                    self.index = 0;
                    self.grouped_base = 0;
                    self.phase = .group_prefix;
                },
                .group_prefix => {
                    if (self.index < b.scopes.items.len) {
                        const cursor = &b.cursors[self.index];
                        self.index += 1;
                        const count = cursor.next;
                        cursor.first = self.grouped_base;
                        cursor.next = self.grouped_base;
                        self.grouped_base += count;
                        return;
                    }
                    self.grouped = try @import("lowering_storage.zig").allocate(t.Body, a, d.occurrence_count, "grouped", true);
                    self.index = 0;
                    self.phase = .group_assign;
                },
                .group_assign => {
                    if (self.index < b.occurrences.len) {
                        const occurrence = &b.occurrences[self.index];
                        self.index += 1;
                        const cursor = &b.cursors[@backingInt(occurrence.scope)];
                        self.grouped[cursor.next] = b.bodies[@backingInt(occurrence.membership)];
                        self.grouped[cursor.next].first = cursor.first;
                        occurrence.membership = @fromBackingInt(cursor.next);
                        cursor.next += 1;
                        return;
                    }
                    if (fixed_storage) {
                        self.index = 0;
                        self.phase = .group_copy;
                        return;
                    }
                    storage.release(t.Body, a, b.bodies);
                    b.bodies = self.grouped;
                    self.grouped = &.{};
                    self.index = 0;
                    self.phase = .group_rewrite;
                },
                .group_copy => {
                    if (self.index < b.bodies.len) {
                        b.bodies[self.index] = self.grouped[self.index];
                        self.index += 1;
                        return;
                    }
                    self.index = 0;
                    self.phase = .group_rewrite;
                },
                .group_rewrite => {
                    if (self.index == b.connections.len) {
                        self.phase = .posting_allocate;
                        return;
                    }
                    const connection = &b.connections[self.index];
                    self.index += 1;
                    inline for (.{ "left", "right" }) |side| {
                        const id = @backingInt(@field(connection, side).members);
                        if (id & t.node_bit == 0) @field(connection, side).members = b.occurrences[id].membership;
                    }
                },
                .posting_allocate => {
                    if (b.offsets.len == 0) b.offsets = try @import("lowering_storage.zig").allocate(u32, a, b.nodes.items.len + 1, "offsets", true) else {
                        b.positions = try @import("lowering_storage.zig").allocate(u32, a, b.mention_count, "positions", true);
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
                        self.phase = if (comptime rep.indexes.any()) .indexes else .joined_allocate;
                        return;
                    }
                    b.offsets[self.index] = b.offsets[self.index - 1];
                    self.index -= 1;
                },
                .indexes => if (comptime rep.indexes.any()) {
                    if (try self.indexer.step(b, true)) self.phase = .joined_allocate;
                } else unreachable,
                .joined_allocate => {
                    if (fixed_storage) {
                        self.phase = .done;
                        return;
                    }
                    if (b.port_count == 0) {
                        self.phase = .done;
                        return;
                    }
                    self.joined = try @import("topology_storage.zig").allocate(t.ConnectionFor(rep.attributes), a, b.connection_count, b.port_count, true);
                    self.index = 0;
                    self.phase = .joined_connections;
                },
                .joined_connections => {
                    if (self.index == b.connections.len) {
                        self.index = 0;
                        self.phase = .joined_ports;
                        return;
                    }
                    self.joined.?.connections[self.index] = b.connections[self.index];
                    self.index += 1;
                },
                .joined_ports => {
                    if (self.index == b.endpoint_ports.len) {
                        self.phase = .done;
                        return;
                    }
                    self.joined.?.endpoint_ports[self.index] = b.endpoint_ports[self.index];
                    self.index += 1;
                },
            }
        }
        fn appendLink(self: *Self, right: @FieldType(Item(D, "stage_links"), "right"), operator: syntax.EdgeOperator, span: Span) void {
            const id: u32 = @intCast(self.d.stage_links.items.len);
            self.d.stage_links.appendAssumeCapacity(.{ .right = right, .operator = operator, .span = span });
            const stmt = &self.d.statements.items[self.d.active()];
            if (stmt.last_link != none) self.d.stage_links.items[stmt.last_link].next = id else stmt.first_link = id;
            stmt.last_link = id;
        }
        fn takeEndpoint(self: *Self, value: @FieldType(Item(D, "stage_links"), "right")) void {
            switch (value) {
                .node => |node| self.beginNode(node, self.occurrence, true, .pending_node),
                .scope => |scope| {
                    self.enter_id = scope;
                    self.phase = .pending_scope;
                },
            }
        }
        fn checkPrefixReference(self: *Self, reference: syntax.NodeReferenceView) Error!void {
            const last = if (reference.port) |port| port.second orelse port.first else reference.identifier;
            if (last.endOffset() <= self.prefix_end) try self.d.checkReference(reference);
        }
        pub fn finalize(self: *Self) void {
            std.debug.assert(self.phase == .checked);
            self.phase = .finish_start;
        }
        pub fn checked(self: *const Self) bool {
            return self.phase == .checked;
        }
        pub fn done(self: *const Self) bool {
            return self.phase == .done;
        }
    };
}
fn bound(written: usize, remaining: usize) u32 {
    return @intCast(@min(std.math.maxInt(u32), @as(u64, written) + remaining));
}
fn attribute(value: e.Attribute) syntax.Attribute {
    return .{ .key = value.key.span(), .value = value.value.span() };
}
fn convert(value: e.EdgeOperator) syntax.EdgeOperator {
    return if (value == .directed) .directed else .undirected;
}
fn checksEntry() type {
    return @import("../dot/validation_checks.zig").AttributeKeyScratch;
}

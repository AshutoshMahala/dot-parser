//! Shared bounded default overlays and attribute binding/folding continuations.
//! Phase selection comes from the caller's inline switch, without redispatch.
const std = @import("std");
const p = @import("lowering_primitives.zig");
const r = @import("resources.zig");
const none = @import("names.zig").empty;

pub inline fn enter(comptime rep: @import("representation.zig").Identity, comptime phase: anytype, self: anytype) r.Error!void {
    const b = self.internBuilder();
    const a = b.a;
    switch (phase) {
        .enter => {
            if (!rep.attributes) {
                self.phase = .enter_push;
                return;
            }
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
        .enter_overlay => if (rep.attributes) {
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
        } else unreachable,
        .enter_overlay_set => if (rep.attributes) {
            if (try self.setting.step(&b.attribute_data, &self.cell_growth, a, b.limits.max_attribute_states, self.mutable_from)) |root| {
                self.overlay_root = root;
                self.overlay_cursor = self.overlay_next;
                self.phase = .enter_overlay;
            }
        } else unreachable,
        else => unreachable,
    }
}

pub inline fn bind(comptime rep: @import("representation.zig").Identity, comptime phase: anytype, self: anytype) r.Error!void {
    const b = self.internBuilder();
    switch (phase) {
        .bind => if (rep.attributes) {
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
        } else unreachable,
        .bind_done => if (rep.attributes) {
            b.attribute_data.meta[self.attribute_index] = .{ .key = self.intern_id, .origin = self.origin };
            if (self.actual != .utf8 and self.actual != .ascii) {
                self.reader = .{ .raw = try b.raw(b.attributes[self.attribute_index].value), .actual = self.actual };
                self.phase = .bind_value;
            } else {
                self.attribute_index += 1;
                self.phase = .bind;
            }
        } else unreachable,
        .bind_value => {
            if (try self.reader.step() == .end) {
                if (!rep.attributes or self.bind_after == .node_port) self.phase = .node_port else {
                    self.attribute_index += 1;
                    self.phase = .bind;
                }
            }
        },
        else => unreachable,
    }
}

pub inline fn apply(comptime rep: @import("representation.zig").Identity, comptime phase: anytype, self: anytype) r.Error!void {
    const b = self.internBuilder();
    const a = b.a;
    switch (phase) {
        .apply => if (rep.attributes) {
            if (self.attribute_index == self.range.start) self.mutable_from = try r.index(b.attribute_data.cells.items.len);
            if (self.attribute_index == self.range.start + self.range.len) {
                self.phase = .apply_next;
                return;
            }
            self.setting = p.Set.init(self.applyRoot().*, b.attribute_data.meta[self.attribute_index].key, self.attribute_index);
            self.phase = .apply_set;
        } else unreachable,
        .apply_set => if (rep.attributes) {
            if (try self.setting.step(&b.attribute_data, &self.cell_growth, a, b.limits.max_attribute_states, self.mutable_from)) |root| {
                self.applyRoot().* = root;
                self.attribute_index += 1;
                self.phase = .apply;
            }
        } else unreachable,
        .apply_next => if (rep.attributes) {
            if (!self.apply_local and self.target == .defaults and self.target.defaults != .graph and b.occurrences[self.occurrence].scope != .root) {
                self.apply_local = true;
                self.attribute_index = self.range.start;
                self.phase = .apply;
            } else self.phase = self.applyAfter();
        } else unreachable,
        else => unreachable,
    }
}

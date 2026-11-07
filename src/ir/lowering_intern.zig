//! Shared bounded name interning for Document and event construction sessions.
const std = @import("std");
const p = @import("lowering_primitives.zig");
const t = @import("topology.zig");
const r = @import("resources.zig");
const storage = @import("session_storage.zig");
const none = @import("names.zig").empty;

// The caller already dispatched this phase. Specialize it here so sharing the
// continuation does not introduce a second runtime switch per work credit.
pub inline fn step(comptime rep: @import("representation.zig").Identity, comptime fixed_storage: bool, comptime phase: anytype, self: anytype) r.Error!void {
    @setEvalBranchQuota(4000);
    const caps = rep.encodings;
    const b = self.internBuilder();
    const a = b.a;
    switch (phase) {
        .intern_hash => switch (try @call(.always_inline, p.Name(caps).step, .{&self.reader})) {
            .pending => {},
            .byte => |byte| self.hasher.update(&.{byte}),
            .end => {
                self.hash = self.hasher.final();
                if (self.family == .scope) {
                    const parent = @backingInt(self.scope_parent);
                    self.hash = std.hash.Wyhash.hash(self.hash, std.mem.asBytes(&parent));
                }
                if (rep.attributes and self.family == .key) self.hash ^= @as(u64, @backingInt(self.kind));
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
                .key => if (rep.attributes) b.attribute_data.keys.items[id].kind == self.kind else unreachable,
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
                            .key => if (rep.attributes) "key_slots" else unreachable,
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
                    if (!try self.node_growth.stepCapped(&b.nodes, 1, a, try b.nodeCapacityBound())) return;
                    const state = if (!rep.attributes) {} else if (b.attribute_data.scopes.len == 0) none else b.attribute_data.scopes[@backingInt(b.occurrences[self.occurrence].scope)].node;
                    b.nodes.appendAssumeCapacity(.{ .name = self.name, .first_mention = b.mention_count, .attribute_state = state, .hash = self.hash });
                },
                .scope => {
                    if (!try self.scope_growth.step(&b.scopes, 1, a)) return;
                    self.intern_id = try r.index(b.scopes.items.len);
                    const name = self.internScopeName();
                    b.scopes.appendAssumeCapacity(.{ .parent = self.scope_parent, .name = name, .first_occurrence = @fromBackingInt(self.internScopeOccurrence()), .hash = self.hash });
                    if (name == null) {
                        self.phase = self.intern_after;
                        return;
                    }
                },
                .key => if (rep.attributes) {
                    if (!try self.key_growth.step(&b.attribute_data.keys, 1, a)) return;
                    self.intern_id = try r.index(b.attribute_data.keys.items.len);
                    b.attribute_data.keys.appendAssumeCapacity(.{ .name = self.name, .hash = self.hash, .first_attribute = self.attribute_index, .kind = self.kind });
                } else unreachable,
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
        else => unreachable,
    }
}

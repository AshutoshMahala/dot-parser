//! Bounded helpers used only by opt-in lowering sessions.
const std = @import("std");
const enc = @import("parser_support").encoding;
const r = @import("resources.zig");
const storage = @import("session_storage.zig");
const attrs = @import("attributes.zig");
const none = attrs.none;

pub fn ReserveFor(comptime T: type, comptime fixed_storage: bool, comptime field: []const u8) type {
    if (!fixed_storage) return Reserve(T);
    return struct {
        pub fn step(_: *@This(), list: *std.ArrayList(T), count: usize, context: *@import("fixed_storage.zig").Context) r.Error!bool {
            try context.ensure(field, std.math.add(usize, list.items.len, count) catch return error.IndexLimit);
            return true;
        }
        pub fn stepCapped(self: *@This(), list: *std.ArrayList(T), count: usize, context: *@import("fixed_storage.zig").Context, _: usize) r.Error!bool {
            return self.step(list, count, context);
        }
    };
}

/// Reserve several records without hiding an ArrayList copy. Each call copies
/// at most 64 bytes or performs one external allocator operation.
pub fn Reserve(comptime T: type) type {
    return struct {
        pending: []T = &.{},
        copied: usize = 0,
        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            storage.release(T, a, self.pending);
        }
        pub fn step(self: *@This(), list: *std.ArrayList(T), count: usize, a: std.mem.Allocator) r.Error!bool {
            return self.stepCapped(list, count, a, std.math.maxInt(u32) - 1);
        }
        /// Cap only new growth; already-owned capacity is never copied merely
        /// to shrink it. Pending copies still use the same 64-byte steps.
        pub fn stepCapped(self: *@This(), list: *std.ArrayList(T), count: usize, a: std.mem.Allocator, maximum: usize) r.Error!bool {
            if (self.pending.len != 0) {
                if (self.copied < list.items.len * @sizeOf(T)) {
                    const end = self.copied + @min(64, list.items.len * @sizeOf(T) - self.copied);
                    @memcpy(std.mem.sliceAsBytes(self.pending)[self.copied..end], std.mem.sliceAsBytes(list.items)[self.copied..end]);
                    self.copied = end;
                } else {
                    storage.release(T, a, list.allocatedSlice());
                    list.items = self.pending[0..list.items.len];
                    list.capacity = self.pending.len;
                    self.pending = &.{};
                    self.copied = 0;
                }
                return false;
            }
            if (list.capacity - list.items.len >= count) return true;
            const wanted = std.math.add(usize, list.items.len, count) catch return error.IndexLimit;
            if (wanted >= std.math.maxInt(u32)) return error.IndexLimit;
            if (wanted > maximum) return error.InvalidDocument;
            const capacity = @min(maximum, std.math.maxInt(u32) - 1, std.ArrayList(T).growCapacity(wanted));
            const bytes = std.math.mul(usize, capacity, @sizeOf(T)) catch return error.IndexLimit;
            const old = list.allocatedSlice();
            // rawResize avoids Debug's implicit whole-buffer poison.
            if (old.len != 0 and a.rawResize(std.mem.sliceAsBytes(old), .of(T), bytes, @returnAddress())) {
                list.capacity = capacity;
            } else self.pending = try storage.allocate(T, a, capacity);
            return false;
        }
    };
}

/// Parser-certified DOT names: preserve byte-profile bytes, decode native
/// scalars, remove only DOT quote/concatenation framing. No string validator or
/// HTML/entity processor is invoked. At most one scalar (two UTF-16 units),
/// one glue unit, or one pending output byte is examined per step.
pub fn Name(comptime caps: enc.Capabilities) type {
    return struct {
        raw: []const u8 = &.{},
        actual: enc.Actual = .utf8,
        offset: u32 = 0,
        state: enum { initial, bare, quote, escape, cr, html, gap, slash, line, block, star } = .initial,
        depth: u32 = 0,
        output: [4]u8 = undefined,
        length: u3 = 0,
        index: u3 = 0,
        pub const Step = union(enum) { pending, end, byte: u8 };
        pub fn step(self: *@This()) r.Error!Step {
            if (self.index < self.length) {
                const byte = self.output[self.index];
                self.index += 1;
                return .{ .byte = byte };
            }
            if (self.offset == self.raw.len) return .end;
            return switch (self.actual) {
                inline else => |actual| if (comptime caps.allows(actual)) self.read(actual) else error.UnsupportedEncoding,
            };
        }
        // Specialize the one-unit decoder within step; an extra call here is
        // paid for every byte of quoted names and concatenation/comment glue.
        inline fn read(self: *@This(), comptime actual: enc.Actual) r.Error!Step {
            const E = enc.Reader(actual);
            const unit = E.unit(self.raw, self.offset);
            self.offset += E.width;
            if (self.state == .cr) {
                self.state = .quote;
                if (unit == '\n') return .pending;
            }
            switch (self.state) {
                .initial => switch (unit) {
                    '"' => {
                        self.state = .quote;
                        return .pending;
                    },
                    '<' => {
                        self.state = .html;
                        self.depth = 1;
                        return .pending;
                    },
                    else => self.state = .bare,
                },
                .bare => {},
                .quote => switch (unit) {
                    '"' => {
                        self.state = .gap;
                        return .pending;
                    },
                    '\\' => {
                        self.state = .escape;
                        return .pending;
                    },
                    else => {},
                },
                .html => {
                    if (unit == '<') self.depth += 1;
                    if (unit == '>') {
                        self.depth -= 1;
                        if (self.depth == 0) {
                            self.state = .gap;
                            return .pending;
                        }
                    }
                },
                .escape => {
                    self.state = .quote;
                    if (unit == '\r') {
                        self.state = .cr;
                        return .pending;
                    }
                    if (unit == '\n') return .pending;
                    if (unit != '"') {
                        // Preserve unknown escapes, including backslash pairs.
                        // Re-read the tail as data, not quote/escape framing.
                        try self.encode(actual, unit);
                        return .{ .byte = '\\' };
                    }
                },
                .gap => {
                    switch (unit) {
                        '"' => self.state = .quote,
                        '<' => {
                            self.state = .html;
                            self.depth = 1;
                        },
                        '/' => self.state = .slash,
                        '#' => self.state = .line,
                        else => {},
                    }
                    return .pending;
                },
                .slash => {
                    self.state = if (unit == '/') .line else .block;
                    return .pending;
                },
                .line => {
                    if (unit == '\n' or unit == '\r') self.state = .gap;
                    return .pending;
                },
                .block => {
                    if (unit == '*') self.state = .star;
                    return .pending;
                },
                .star => {
                    self.state = if (unit == '/') .gap else if (unit == '*') .star else .block;
                    return .pending;
                },
                .cr => unreachable,
            }
            try self.encode(actual, unit);
            self.index = 1;
            return .{ .byte = self.output[0] };
        }
        fn encode(self: *@This(), comptime actual: enc.Actual, unit: u32) r.Error!void {
            self.index = 0;
            if (actual == .ascii or actual == .utf8) {
                self.output[0] = @intCast(unit);
                self.length = 1;
            } else {
                const E = enc.Reader(actual);
                const scalar = E.decode(self.raw, self.offset - E.width) catch return error.InvalidIdentifier;
                self.offset += scalar.len - E.width;
                self.length = std.unicode.utf8Encode(scalar.scalar, &self.output) catch return error.InvalidIdentifier;
            }
        }
    };
}

/// One AVL visit or bounded ancestor update per step. Only this unpublished
/// batch's cells may be reused. Reserve before updating so no step hides a copy.
pub const Set = struct {
    root: u32,
    key: u32,
    attribute: u32,
    cursor: u32,
    child: u32 = none,
    path: [48]u32 = undefined,
    depth: u8 = 0,
    phase: enum { probe, leaf, unwind, done } = .probe,
    pub fn init(root: u32, key: u32, attribute: u32) Set {
        return .{ .root = root, .key = key, .attribute = attribute, .cursor = root };
    }
    pub fn step(self: *Set, store: *attrs.Store, growth: anytype, a: anytype, limit: u32, mutable_from: u32) r.Error!?u32 {
        switch (self.phase) {
            .probe => {
                if (self.cursor == none) {
                    self.phase = .leaf;
                    return null;
                }
                const cell = store.cells.items[self.cursor];
                if (cell.key == self.key) {
                    if (cell.attribute == self.attribute) {
                        self.child = self.root;
                        self.phase = .done;
                    } else self.phase = .leaf;
                } else {
                    if (self.depth == self.path.len) return error.IndexLimit;
                    self.path[self.depth] = self.cursor;
                    self.depth += 1;
                    self.cursor = if (self.key < cell.key) cell.left else cell.right;
                }
            },
            .leaf, .unwind => {
                if (self.phase == .unwind and self.depth == 0) {
                    self.phase = .done;
                    return null;
                }
                var work: r.Work = .{ .remaining = 32, .cancellation = null };
                if (self.phase == .leaf) {
                    var cell: attrs.Cell = if (self.cursor == none) .{ .key = self.key, .attribute = self.attribute } else store.cells.items[self.cursor];
                    cell.attribute = self.attribute;
                    if (@TypeOf(a) == std.mem.Allocator) {
                        const count: u32 = @intFromBool(self.cursor == none or self.cursor < mutable_from);
                        if (!try growth.step(&store.cells, count, a)) return null;
                    }
                    const capacity = store.cells.capacity;
                    self.child = try store.put(a, self.cursor, cell, mutable_from, limit, &work);
                    std.debug.assert(store.cells.capacity == capacity);
                    self.phase = .unwind;
                } else {
                    const id = self.path[self.depth - 1];
                    var cell = store.cells.items[id];
                    if (self.key < cell.key) cell.left = self.child else cell.right = self.child;
                    if (@TypeOf(a) == std.mem.Allocator) {
                        // Only this ancestor may still be shared. A rotation
                        // is caused by insertion along the changed path: its
                        // child (and grandchild for a double rotation) was
                        // already copied/reused while unwinding that path.
                        const count: u32 = @intFromBool(id < mutable_from);
                        std.debug.assert(store.updateCapacity(id, cell, mutable_from) == count);
                        if (!try growth.step(&store.cells, count, a)) return null;
                    }
                    self.depth -= 1;
                    const capacity = store.cells.capacity;
                    self.child = try store.update(a, id, cell, mutable_from, limit, &work);
                    std.debug.assert(store.cells.capacity == capacity);
                }
            },
            .done => return self.child,
        }
        return null;
    }
};

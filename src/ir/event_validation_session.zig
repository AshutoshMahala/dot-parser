//! Bounded validation over a committed event group or the retained source.
//! Owns only reusable duplicate-check scratch, never an event log or Document.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("../dot/syntax.zig");
const checks = @import("../dot/validation_checks.zig");
const p = @import("lowering_primitives.zig");
const r = @import("resources.zig");
const Entry = checks.AttributeKeyScratch;
const none = std.math.maxInt(u32);
const Name = p.Name(.{ .utf8 = true });
const Stop = @import("event_validation.zig").Stop;

pub const Attributes = AttributesFor(false);
pub fn AttributesFor(comptime fixed: bool) type {
    return struct {
        const Self = @This();
        const Phase = enum { idle, catalog_start, catalog_name, reserve, hash_start, hash_name, sort_start, heap_build, heap_extract, sift, child, parent, compare, duplicates, duplicate_compare, emit };
        phase: Phase = .idle,
        group: []const syntax.Attribute = &.{},
        growth: if (fixed) @import("event_session_storage.zig").SliceFor(Entry, true, "validation_keys") else p.Reserve(Entry) = .{},
        index: u32 = 0,
        reader: Name = .{},
        other: Name = .{},
        byte: ?u8 = null,
        ended: bool = false,
        hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),
        catalog: [18]u8 = undefined,
        catalog_len: u8 = 0,
        by_index: bool = false,
        heap: u32 = 0,
        end: u32 = 0,
        root: u32 = 0,
        child: u32 = 0,
        left: Entry = undefined,
        right: Entry = undefined,
        after_compare: Phase = .idle,
        after_sift: Phase = .idle,
        ordering: std.math.Order = .eq,
        first: Entry = undefined,

        pub fn start(self: *Self, group: []const syntax.Attribute) void {
            self.group = group;
            self.index = 0;
            self.phase = .catalog_start;
        }
        pub fn deinit(self: *Self, a: anytype) void {
            self.growth.deinit(a);
        }
        fn compare(self: *Self, source: []const u8, left: Entry, right: Entry, after: Phase) void {
            self.left = left;
            self.right = right;
            self.after_compare = after;
            self.ordering = if (self.by_index) std.math.order(left.index, right.index) else std.math.order(left.hash, right.hash);
            if (self.by_index or self.ordering != .eq) {
                self.phase = after;
                return;
            }
            self.reader = .{ .raw = self.group[left.index].key.slice(source) };
            self.other = .{ .raw = self.group[right.index].key.slice(source) };
            self.byte = null;
            self.ended = false;
            self.phase = .compare;
        }
        /// One source unit, one bounded comparison, one heap transition or one
        /// scratch-growth step. The caller charges/polls before each call.
        pub fn step(self: *Self, checker: anytype, a: anytype) (r.Error || Stop)!bool {
            const source = checker.source;
            const settings = checker.settings();
            const entries = &checker.entries;
            switch (self.phase) {
                .idle => return true,
                .catalog_start => {
                    if (settings.graphviz.unknown_attribute == .off or self.index == self.group.len) {
                        self.index = 0;
                        self.phase = if (settings.repeated_attribute == .off or self.group.len < 2) .idle else .reserve;
                        return false;
                    }
                    self.reader = .{ .raw = self.group[self.index].key.slice(source) };
                    self.catalog_len = 0;
                    self.phase = .catalog_name;
                },
                .catalog_name => {
                    const read = try self.reader.step();
                    if (read == .pending) return false;
                    if (read == .byte and read.byte < 128 and self.catalog_len < self.catalog.len) {
                        self.catalog[self.catalog_len] = read.byte;
                        self.catalog_len += 1;
                        return false;
                    }
                    if (read != .end or @import("../dot/attribute_catalog.zig").lookup(self.catalog[0..self.catalog_len]) == null)
                        try checker.emit(.{ .code = checks.severityCode(settings.graphviz.unknown_attribute, .validation_unknown_attribute, .validation_unknown_attribute_tolerated), .span = self.group[self.index].key });
                    self.index += 1;
                    self.phase = .catalog_start;
                },
                .reserve => {
                    entries.items.len = 0;
                    if (!try self.growth.step(entries, self.group.len, a)) return false;
                    entries.items.len = self.group.len;
                    self.phase = .hash_start;
                },
                .hash_start => {
                    if (self.index == self.group.len) {
                        self.by_index = false;
                        self.phase = .sort_start;
                        return false;
                    }
                    self.reader = .{ .raw = self.group[self.index].key.slice(source) };
                    self.hasher = .init(0);
                    self.phase = .hash_name;
                },
                .hash_name => switch (try self.reader.step()) {
                    .pending => {},
                    .byte => |byte| self.hasher.update(&.{byte}),
                    .end => {
                        entries.items[self.index] = .{ .hash = self.hasher.final(), .index = self.index, .first = none };
                        self.index += 1;
                        self.phase = .hash_start;
                    },
                },
                .sort_start => {
                    self.heap = @intCast(self.group.len / 2);
                    self.end = @intCast(self.group.len);
                    self.phase = .heap_build;
                },
                .heap_build => {
                    if (self.heap == 0) {
                        self.phase = .heap_extract;
                        return false;
                    }
                    self.heap -= 1;
                    self.root = self.heap;
                    self.after_sift = .heap_build;
                    self.phase = .sift;
                },
                .heap_extract => {
                    if (self.end <= 1) {
                        self.index = if (self.by_index) 0 else 1;
                        self.first = entries.items[0];
                        self.phase = if (self.by_index) .emit else .duplicates;
                        return false;
                    }
                    self.end -= 1;
                    std.mem.swap(Entry, &entries.items[0], &entries.items[self.end]);
                    self.root = 0;
                    self.after_sift = .heap_extract;
                    self.phase = .sift;
                },
                .sift => {
                    if (self.root >= self.end / 2) {
                        self.phase = self.after_sift;
                        return false;
                    }
                    self.child = self.root * 2 + 1;
                    if (self.child + 1 < self.end) self.compare(source, entries.items[self.child], entries.items[self.child + 1], .child) else {
                        self.ordering = .gt;
                        self.phase = .child;
                    }
                },
                .child => {
                    if (self.less()) self.child += 1;
                    self.compare(source, entries.items[self.root], entries.items[self.child], .parent);
                },
                .parent => {
                    if (!self.less()) {
                        self.phase = self.after_sift;
                        return false;
                    }
                    std.mem.swap(Entry, &entries.items[self.root], &entries.items[self.child]);
                    self.root = self.child;
                    self.phase = .sift;
                },
                .compare => {
                    if (self.byte == null and !self.ended) {
                        switch (try self.reader.step()) {
                            .pending => {},
                            .byte => |byte| self.byte = byte,
                            .end => self.ended = true,
                        }
                        return false;
                    }
                    const right = try self.other.step();
                    if (right == .pending) return false;
                    self.ordering = if (self.ended) (if (right == .end) .eq else .lt) else if (right == .end) .gt else std.math.order(self.byte.?, right.byte);
                    if (self.ordering != .eq or self.ended) self.phase = self.after_compare else self.byte = null;
                },
                .duplicates => {
                    if (self.index == self.group.len) {
                        self.by_index = true;
                        self.phase = .sort_start;
                        return false;
                    }
                    self.compare(source, self.first, entries.items[self.index], .duplicate_compare);
                },
                .duplicate_compare => {
                    if (self.ordering == .eq) entries.items[self.index].first = self.first.index else self.first = entries.items[self.index];
                    self.index += 1;
                    self.phase = .duplicates;
                },
                .emit => {
                    if (self.index == self.group.len) {
                        self.phase = .idle;
                        return false;
                    }
                    const entry = entries.items[self.index];
                    self.index += 1;
                    if (entry.first != none) try checker.emit(.{ .code = checks.severityCode(settings.repeated_attribute, .validation_repeated_attribute, .validation_repeated_attribute_tolerated), .span = self.group[entry.index].key, .details = .{ .repeated_attribute = self.group[entry.first].key } });
                },
            }
            return false;
        }
        fn less(self: *const Self) bool {
            return self.ordering == .lt or (self.ordering == .eq and self.left.index < self.right.index);
        }
    };
}

/// The lexer identifies complete markup-containing expressions. Traversal of
/// their quote/comment/angle framing is also resumable; no operand rescan hides
/// inside one credit. Only the markup interiors are excluded from DOT checks.
pub const Encoding = struct {
    const Scanner = @import("../dot/lexer/lexer.zig").scannerForEncoding(.utf8, .scalar, false)(false, false, false);
    scanner: Scanner,
    ascii: bool = false,
    checked: u32 = 0,
    end: u32 = 0,
    at: u32 = 0,
    token_end: u32 = 0,
    depth: u32 = 0,
    phase: enum { scan, parts, range, done } = .scan,
    after_range: enum { parts, done } = .parts,
    framing: enum { gap, quote, escape, slash, line, block, star, html } = .gap,
    pub fn init(source: []const u8) @This() {
        return .{ .scanner = Scanner.init(source) };
    }
    pub fn step(self: *@This(), checker: anytype) (r.Error || Stop)!bool {
        if (checker.settings().invalid_encoding == .off) return true;
        const source = checker.source;
        switch (self.phase) {
            .done => return true,
            .scan => {
                const value = self.scanner.drive(true, 1).result orelse return false;
                switch (value) {
                    .failure => switch (self.scanner.terminal) {
                        .oversize, .none, .eof => {
                            self.end = @intCast(source.len);
                            self.after_range = .done;
                            self.phase = .range;
                        },
                        else => self.scanner.resumeAfterFailure(),
                    },
                    .token => |token| {
                        if (token.tag == .eof) {
                            self.end = @intCast(source.len);
                            self.after_range = .done;
                            self.phase = .range;
                        } else if (token.flags.has_html) {
                            self.at = token.span.start;
                            self.token_end = @intCast(token.span.endOffset());
                            self.framing = .gap;
                            self.phase = .parts;
                        }
                    },
                }
            },
            .range => {
                if (self.checked == self.end) {
                    self.phase = if (self.after_range == .parts) .parts else .done;
                    return false;
                }
                const start = self.checked;
                const next = if (self.ascii) support.encoding.validationStep(.ascii, source[0..self.end], start) else support.encoding.validationStep(.utf8, source[0..self.end], start);
                self.checked += next.len;
                if (next.invalid) |bad| try checker.emit(.{ .code = checks.severityCode(checker.settings().invalid_encoding, .validation_invalid_encoding, .validation_invalid_encoding_tolerated), .span = .{ .start = start, .len = 1 }, .details = .{ .invalid_encoding = bad } });
            },
            .parts => {
                if (self.at == self.token_end) {
                    self.phase = .scan;
                    return false;
                }
                const byte = source[self.at];
                self.at += 1;
                switch (self.framing) {
                    .gap => switch (byte) {
                        '"' => self.framing = .quote,
                        '<' => {
                            self.depth = 1;
                            self.framing = .html;
                            self.end = self.at;
                            self.after_range = .parts;
                            self.phase = .range;
                        },
                        '/' => self.framing = .slash,
                        '#' => self.framing = .line,
                        else => {},
                    },
                    .quote => switch (byte) {
                        '"' => self.framing = .gap,
                        '\\' => self.framing = .escape,
                        else => {},
                    },
                    .escape => self.framing = .quote,
                    .slash => self.framing = if (byte == '*') .block else if (byte == '/') .line else .gap,
                    .line => if (byte == '\n') {
                        self.framing = .gap;
                    },
                    .block => if (byte == '*') {
                        self.framing = .star;
                    },
                    .star => if (byte == '/') {
                        self.framing = .gap;
                    } else if (byte != '*') {
                        self.framing = .block;
                    },
                    .html => {
                        if (byte == '<') self.depth += 1;
                        if (byte == '>') {
                            self.depth -= 1;
                            if (self.depth == 0) {
                                self.checked = self.at - 1;
                                self.framing = .gap;
                            }
                        }
                    },
                }
            },
        }
        return false;
    }
};

test "bounded event checks preserve duplicate and catalog diagnostics with long glue" {
    const dot = @import("../root.zig");
    const config = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .warning, .graphviz = .{ .unknown_attribute = .warning } } } });
    // Use independently valid quoted concatenations and duplicate groups,
    // groups as well as groups with equal hashes/names and distinct spellings.
    for ([_][]const u8{
        "digraph{a[color=x \"color\"=y \"c\" + /* glue */ \"olor\"=z x=q x=r]}",
        "digraph{a[z=x y=x z=x shape=x shape=y z=y x=z x=w]}",
    }) |input| {
        var parsed = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
        defer parsed.deinit(std.testing.allocator);
        const group = parsed.document.?.attributes;
        const C = @import("event_validation.zig").Checker(.utf8, config.baseline.validation);
        var expected_bag: dot.FixedDiagnosticBag(32) = .{};
        var bag: dot.FixedDiagnosticBag(32) = .{};
        var expected: C = .{ .source = input, .runtime_settings = {}, .sink = expected_bag.sink() };
        defer expected.deinit(std.testing.allocator);
        var actual: C = .{ .source = input, .runtime_settings = {}, .sink = bag.sink() };
        defer actual.deinit(std.testing.allocator);
        var work = try r.Work.init(.{}, null);
        try expected.attributes(std.testing.allocator, group, &work);
        var task: Attributes = .{};
        defer task.deinit(std.testing.allocator);
        task.start(group);
        var steps: usize = 0;
        while (!try task.step(&actual, std.testing.allocator)) : (steps += 1) try std.testing.expect(steps < 10000);
        try std.testing.expectEqualDeep(expected_bag.items(), bag.items());
    }
}

test "bounded encoding walk excludes exactly the same markup interiors" {
    const dot = @import("../root.zig");
    const config = dot.Profile(.{ .policy = .{ .validation = .{ .invalid_encoding = .warning } } });
    const C = @import("event_validation.zig").Checker(.utf8, config.baseline.validation);
    for ([_][]const u8{
        "digraph{a[label=<<b>\xff</b>>];b[label=\"\xff\"]}",
        "digraph{a[label=\"\xff\" + /* < */ <<b>\xff</b>> + \"\xff\"]}",
        "digraph{a; \xff; bad[label=\"unfinished\xff",
        "digraph{a[label=<x> + \"\xff\" + <y>]} // \xff",
    }) |source| {
        var expected_bag: dot.FixedDiagnosticBag(32) = .{};
        var bag: dot.FixedDiagnosticBag(32) = .{};
        var expected: C = .{ .source = source, .runtime_settings = {}, .sink = expected_bag.sink() };
        var actual: C = .{ .source = source, .runtime_settings = {}, .sink = bag.sink() };
        var work = try r.Work.init(.{}, null);
        try expected.encoding(&work);
        var task = Encoding.init(source);
        var steps: usize = 0;
        while (!try task.step(&actual)) : (steps += 1) try std.testing.expect(steps < 10000);
        try std.testing.expectEqualDeep(expected_bag.items(), bag.items());
    }
}

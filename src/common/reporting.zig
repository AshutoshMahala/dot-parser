//! Processor-independent diagnostic transport. Payloads stay processor-owned.
//! Bags copy values, not referenced data: borrowed payloads must outlive retention.
const std = @import("std");

/// WDP severity alphabet (WDP part 1). The enum value is the WDP priority.
pub const Severity = enum(u4) {
    trace = 0,
    info = 1,
    completed = 2,
    success = 3,
    help = 4,
    warning = 5,
    critical = 6,
    blocked = 7,
    err = 8,

    /// The single-character WDP severity code.
    pub fn letter(self: Severity) u8 {
        return switch (self) {
            .trace => 'T',
            .info => 'I',
            .completed => 'K',
            .success => 'S',
            .help => 'H',
            .warning => 'W',
            .critical => 'C',
            .blocked => 'B',
            .err => 'E',
        };
    }

    /// WDP priority, 0 (trace) through 8 (error).
    pub fn priority(self: Severity) u4 {
        return @intFromEnum(self);
    }

    /// Only E and B block the operation that reported them (WDP part 1 §5).
    pub fn isBlocking(self: Severity) bool {
        return self == .err or self == .blocked;
    }

    pub const Tone = enum { negative, positive, neutral };

    pub fn tone(self: Severity) Tone {
        return switch (self) {
            .err, .blocked, .critical, .warning => .negative,
            .success, .completed => .positive,
            .help, .info, .trace => .neutral,
        };
    }
};

/// Whether a tool may apply the fix without asking. `machine_applicable`
/// means the edit is the one correct repair; `maybe` means it is a plausible
/// repair among others, or its position is a guess — offer it, do not apply
/// it unattended.
pub const Applicability = enum(u8) {
    machine_applicable,
    maybe,
};

pub const Action = enum { proceed, stop };
pub const SinkError = error{ DiagnosticSinkFailure, DiagnosticCapacityExceeded, OutOfMemory };
pub const Delivery = enum { complete, failed };
pub const StopReason = enum {
    requested,
    capacity,
    failure,
    out_of_memory,

    pub fn fromError(err: SinkError) StopReason {
        return switch (err) {
            error.DiagnosticSinkFailure => .failure,
            error.DiagnosticCapacityExceeded => .capacity,
            error.OutOfMemory => .out_of_memory,
        };
    }
};

/// Explicit runtime destination adapter. Statically bound producers may call a
/// concrete sink's push method directly; they need not erase its type.
pub fn Sink(comptime Item: type) type {
    return struct {
        context: ?*anyopaque,
        emit_fn: *const fn (?*anyopaque, Item) SinkError!Action,

        pub fn emit(self: @This(), item: Item) SinkError!Action {
            return self.emit_fn(self.context, item);
        }

        pub const discard: @This() = .{ .context = null, .emit_fn = discardEmit };
        fn discardEmit(_: ?*anyopaque, _: Item) SinkError!Action {
            return .proceed;
        }
    };
}

pub const Overflow = enum { stop, omit };

/// `stop` accepts the last available entry and asks the producer to stop.
/// `omit` explicitly continues, retaining the first entries and counting omissions.
pub fn FixedBag(comptime Item: type, comptime capacity: usize, comptime overflow: Overflow) type {
    return struct {
        const Self = @This();
        entries: [capacity]Item = undefined,
        len: usize = 0,
        omitted: u64 = 0,

        pub fn push(self: *Self, item: Item) SinkError!Action {
            if (capacity == 0 or self.len == capacity) {
                if (overflow == .stop) return error.DiagnosticCapacityExceeded;
                self.omitted = std.math.add(u64, self.omitted, 1) catch return error.DiagnosticSinkFailure;
                return .proceed;
            }
            self.entries[self.len] = item;
            self.len += 1;
            return if (overflow == .stop and self.len == capacity) .stop else .proceed;
        }

        pub fn items(self: *const Self) []const Item {
            return self.entries[0..self.len];
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.omitted = 0;
        }

        pub fn sink(self: *Self) Sink(Item) {
            return .{ .context = self, .emit_fn = emitOpaque };
        }

        fn emitOpaque(context: ?*anyopaque, item: Item) SinkError!Action {
            const self: *Self = @ptrCast(@alignCast(context.?));
            return self.push(item);
        }
    };
}

/// A bounded retention budget, or explicit opt-in to allocator/representation
/// limits only. Zero means no retention; 65,535 is an ordinary finite limit.
/// This is not a finding counter or a limit on source/processor work.
pub const EntryLimit = union(enum) {
    limited: u16,
    unlimited,

    fn maximum(self: EntryLimit, comptime Item: type) usize {
        return switch (self) {
            .limited => |count| count,
            .unlimited => std.math.maxInt(usize) / @max(1, @sizeOf(Item)),
        };
    }
};
pub const default_entry_limit: u16 = 1024;

/// Explicitly allocator-backed retention, limited to 1,024 entries by default.
/// init does not allocate. Growth never reserves more than the selected limit;
/// this excludes allocator overhead and simultaneous old/new growth buffers.
/// items() views expire on growth/reset/deinit. The bag and allocator are caller-owned.
/// Treat configuration as immutable after init; reset retains capacity and limit.
pub fn GrowableBag(comptime Item: type) type {
    return struct {
        const Self = @This();
        pub const Options = struct { max_entries: EntryLimit = .{ .limited = default_entry_limit } };
        allocator: std.mem.Allocator,
        storage: std.ArrayList(Item) = .empty,
        max_entries: EntryLimit,

        pub fn init(allocator: std.mem.Allocator, options: Options) Self {
            return .{ .allocator = allocator, .max_entries = options.max_entries };
        }

        pub fn push(self: *Self, item: Item) SinkError!Action {
            const maximum = self.max_entries.maximum(Item);
            if (self.storage.items.len >= maximum) return error.DiagnosticCapacityExceeded;
            if (self.storage.items.len == self.storage.capacity) {
                const grown = std.math.add(usize, self.storage.capacity, self.storage.capacity / 2 + 8) catch std.math.maxInt(usize);
                try self.storage.ensureTotalCapacityPrecise(self.allocator, @min(grown, maximum));
            }
            self.storage.appendAssumeCapacity(item);
            return if (self.storage.items.len == maximum) .stop else .proceed;
        }

        pub fn items(self: *const Self) []const Item {
            return self.storage.items;
        }

        pub fn reset(self: *Self) void {
            self.storage.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            self.storage.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn sink(self: *Self) Sink(Item) {
            return .{ .context = self, .emit_fn = emitOpaque };
        }

        fn emitOpaque(context: ?*anyopaque, item: Item) SinkError!Action {
            const self: *Self = @ptrCast(@alignCast(context.?));
            return self.push(item);
        }
    };
}

test "fixed destinations acknowledge accepted stop, zero capacity and explicit omission" {
    var bag: FixedBag(u8, 1, .stop) = .{};
    try std.testing.expectEqual(Action.stop, try bag.sink().emit(7));
    try std.testing.expectError(error.DiagnosticCapacityExceeded, bag.push(8));
    try std.testing.expectEqualSlices(u8, &.{7}, bag.items());
    bag.reset();
    try std.testing.expectEqual(Action.stop, try bag.push(9));
    var zero: FixedBag(u8, 0, .stop) = .{};
    try std.testing.expectError(error.DiagnosticCapacityExceeded, zero.push(1));
    var omitted: FixedBag(u8, 0, .omit) = .{};
    try std.testing.expectEqual(Action.proceed, try omitted.push(1));
    try std.testing.expectEqual(@as(u64, 1), omitted.omitted);
    omitted.omitted = std.math.maxInt(u64);
    try std.testing.expectError(error.DiagnosticSinkFailure, omitted.push(1));
}

test "growth, hard limit, retained capacity and allocation failure" {
    var bag = GrowableBag(u32).init(std.testing.allocator, .{ .max_entries = .{ .limited = 40 } });
    defer bag.deinit();
    for (0..40) |i| try std.testing.expectEqual(if (i == 39) Action.stop else Action.proceed, try bag.push(@intCast(i)));
    try std.testing.expect(bag.storage.capacity <= 40);
    try std.testing.expectError(error.DiagnosticCapacityExceeded, bag.push(99));
    for (bag.items(), 0..) |item, i| try std.testing.expectEqual(@as(u32, @intCast(i)), item);
    const capacity = bag.storage.capacity;
    bag.reset();
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);
    try std.testing.expectEqual(capacity, bag.storage.capacity);
    _ = try bag.push(99);
    var failing = GrowableBag(u32).init(std.testing.failing_allocator, .{});
    defer failing.deinit();
    try std.testing.expectError(error.OutOfMemory, failing.sink().emit(1));
    try std.testing.expectEqual(@as(usize, 0), failing.items().len);
    var zero = GrowableBag(u32).init(std.testing.failing_allocator, .{ .max_entries = .{ .limited = 0 } });
    defer zero.deinit();
    try std.testing.expectError(error.DiagnosticCapacityExceeded, zero.push(1));
}

test "default retention cap stops at 1024, never over-reserves, and survives reset" {
    try std.testing.expect(@FieldType(EntryLimit, "limited") == u16);
    var bag = GrowableBag(u32).init(std.testing.allocator, .{});
    defer bag.deinit();
    try std.testing.expectEqual(@as(usize, 0), bag.storage.capacity);
    for (0..2) |_| {
        for (0..1024) |i| {
            try std.testing.expectEqual(if (i == 1023) Action.stop else .proceed, try bag.push(@intCast(i)));
            try std.testing.expect(bag.storage.capacity <= 1024);
        }
        try std.testing.expectEqual(@as(usize, 1024), bag.items().len);
        try std.testing.expectError(error.DiagnosticCapacityExceeded, bag.push(1024));
        bag.reset();
        try std.testing.expectEqual(@as(usize, 0), bag.items().len);
        try std.testing.expectEqual(@as(usize, 1024), bag.storage.capacity);
        try std.testing.expectEqual(EntryLimit{ .limited = 1024 }, bag.max_entries);
    }
}

test "finite u16 maximum is not unlimited and one is not zero" {
    inline for (.{ 1, std.math.maxInt(u16) }) |limit| {
        var bag = GrowableBag(u8).init(std.testing.allocator, .{ .max_entries = .{ .limited = limit } });
        defer bag.deinit();
        for (0..limit) |i| {
            try std.testing.expectEqual(if (i + 1 == limit) Action.stop else .proceed, try bag.push(@truncate(i)));
            try std.testing.expect(bag.storage.capacity <= limit);
        }
        try std.testing.expectError(error.DiagnosticCapacityExceeded, bag.push(0));
    }
}

test "unlimited retention crosses u16 without narrowing native storage lengths" {
    var bag = GrowableBag(u8).init(std.testing.allocator, .{ .max_entries = .unlimited });
    defer bag.deinit();
    for (0..65_536) |i| try std.testing.expectEqual(Action.proceed, try bag.push(@truncate(i)));
    try std.testing.expectEqual(@as(usize, 65_536), bag.items().len);
    for (bag.items(), 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
    bag.reset();
    try std.testing.expectEqual(Action.proceed, try bag.push(1));
}

fn bagAllocationCase(allocator: std.mem.Allocator) !void {
    var bag = GrowableBag(u32).init(allocator, .{});
    defer bag.deinit();
    for (0..1024) |i| {
        const action = bag.push(@intCast(i)) catch |err| {
            // Failed growth neither appends a value nor discards prior entries.
            try std.testing.expectEqual(i, bag.items().len);
            for (bag.items(), 0..) |value, index| try std.testing.expectEqual(@as(u32, @intCast(index)), value);
            return err;
        };
        try std.testing.expectEqual(if (i == 1023) Action.stop else .proceed, action);
    }
}

test "every diagnostic growth failure preserves entries and releases storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, bagAllocationCase, .{});
}

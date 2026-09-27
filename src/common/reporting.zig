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

/// Explicitly allocator-backed retention. init does not allocate. Growth never
/// reserves more than max_entries; the limit counts entries, not allocator overhead.
/// items() views expire on growth/reset/deinit. The bag and allocator are caller-owned.
pub fn GrowableBag(comptime Item: type) type {
    return struct {
        const Self = @This();
        pub const Options = struct { max_entries: usize = std.math.maxInt(usize) / @max(1, @sizeOf(Item)) };
        allocator: std.mem.Allocator,
        storage: std.ArrayList(Item) = .empty,
        max_entries: usize,

        pub fn init(allocator: std.mem.Allocator, options: Options) Self {
            return .{ .allocator = allocator, .max_entries = options.max_entries };
        }

        pub fn push(self: *Self, item: Item) SinkError!Action {
            if (self.storage.items.len == self.max_entries) return error.DiagnosticCapacityExceeded;
            if (self.storage.items.len == self.storage.capacity) {
                const grown = std.math.add(usize, self.storage.capacity, self.storage.capacity / 2 + 8) catch std.math.maxInt(usize);
                try self.storage.ensureTotalCapacityPrecise(self.allocator, @min(grown, self.max_entries));
            }
            self.storage.appendAssumeCapacity(item);
            return if (self.storage.items.len == self.max_entries) .stop else .proceed;
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
    var bag = GrowableBag(u32).init(std.testing.allocator, .{ .max_entries = 40 });
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
    var zero = GrowableBag(u32).init(std.testing.failing_allocator, .{ .max_entries = 0 });
    defer zero.deinit();
    try std.testing.expectError(error.DiagnosticCapacityExceeded, zero.push(1));
}

//! Test-only recording consumer of the public event contract.
const std = @import("std");
const events = @import("events.zig");
pub const Record = union(enum) { event: events.Event, abort: events.Abort };

pub fn RecordingSink(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        // These grammar tests deliberately exercise document-level aborts;
        // the public integration tests exercise statement transactions.
        pub const recover_statements = false;
        pub const wants_begin_statement = false;
        pub const Error = error{EventCapacityExceeded};
        events: [capacity + 1]Record = undefined,
        len: usize = 0,
        pub fn onEvent(self: *Self, value: events.Event) Error!events.Action {
            if (value == .end_document) self.recordTerminal(.{ .event = value }) else {
                if (self.len >= capacity) return error.EventCapacityExceeded;
                self.events[self.len] = .{ .event = value };
                self.len += 1;
            }
            return .proceed;
        }
        pub fn onAbort(self: *Self, value: events.Abort) void {
            self.recordTerminal(.{ .abort = value });
        }
        pub fn recorded(self: *const Self) []const Record {
            return self.events[0..self.len];
        }
        fn recordTerminal(self: *Self, value: Record) void {
            std.debug.assert(self.len < self.events.len);
            self.events[self.len] = value;
            self.len += 1;
        }
    };
}

const header: events.BeginDocument = .{ .kind = .undigraph, .keyword_span = .{ .start = 0, .len = 5 } };
const node: events.Event = .{ .commit_node = .{
    .owner = .{ .statement = @fromBackingInt(@intCast(8)), .scope = .root },
    .value = .{ .identifier = .{ .start = 8, .len = 1 } },
} };

test "shared event recorder preserves order and borrowed source spans" {
    const source = "graph { a; }";
    var sink: RecordingSink(4) = .{};
    _ = try sink.onEvent(.{ .begin_document = header });
    _ = try sink.onEvent(node);
    _ = try sink.onEvent(.end_document);
    try std.testing.expectEqual(@as(usize, 3), sink.len);
    const identifier = sink.recorded()[1].event.commit_node.value.identifier;
    try std.testing.expectEqualStrings("a", identifier.slice(source));
    try std.testing.expect(identifier.slice(source).ptr == source[8..].ptr);
    try std.testing.expect(sink.recorded()[2].event == .end_document);
}

test "shared event recorder records document rejection after begin" {
    var sink: RecordingSink(1) = .{};
    _ = try sink.onEvent(.{ .begin_document = header });
    sink.onAbort(.{ .document = .invalid_syntax });
    try std.testing.expectEqual(events.AbortReason.invalid_syntax, sink.recorded()[1].abort.document);
}

test "shared event recorder propagates capacity errors" {
    var sink: RecordingSink(1) = .{};
    _ = try sink.onEvent(.{ .begin_document = header });
    try std.testing.expectError(error.EventCapacityExceeded, sink.onEvent(node));
    try std.testing.expectEqual(@as(usize, 1), sink.len);
}

test "shared event recorder reserves infallible abort capacity" {
    var sink: RecordingSink(1) = .{};
    _ = try sink.onEvent(.{ .begin_document = header });
    try std.testing.expectError(error.EventCapacityExceeded, sink.onEvent(node));
    sink.onAbort(.{ .document = .sink_failure });
    try std.testing.expectEqual(@as(usize, 2), sink.len);
    try std.testing.expectEqual(events.AbortReason.sink_failure, sink.recorded()[1].abort.document);
}

test "zero-capacity event recorder can always record cleanup" {
    var sink: RecordingSink(0) = .{};
    try std.testing.expectError(error.EventCapacityExceeded, sink.onEvent(.{ .begin_document = header }));
    sink.onAbort(.{ .document = .sink_failure });
    try std.testing.expectEqual(@as(usize, 1), sink.len);
}

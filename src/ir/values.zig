//! Borrowed views over certified DOT values. No operand array, decoded cache,
//! implicit markup processing or renderer interpretation is retained.
const std = @import("std");
const support = @import("parser_support");
const encodings = support.encoding;
const Range = support.location.Range;
const attrs = @import("attributes.zig");
const r = @import("resources.zig");
const operands = @import("../dot/identifier_parts.zig");
const logical = @import("../dot/identifier_value.zig");
const Unmetered = @import("../dot/identifier_cursor.zig").Unmetered;
const ports = @import("ports.zig");

pub const Kind = enum { string, markup, concatenation };
pub const OperandKind = enum { string, markup };
pub const EncodedFragment = struct { input: support.processor.Fragment, encoding: encodings.Actual };

pub fn For(comptime Graph: type, comptime caps: encodings.Capabilities) type {
    return struct {
        pub const Value = struct {
            graph: *const Graph,
            selected: attrs.Value,

            pub fn raw(self: Value) ?[]const u8 {
                return if (self.span()) |range| self.graph.text(range) else null;
            }
            pub fn span(self: Value) ?Range {
                return switch (self.selected) {
                    .empty => null,
                    .written => |range| range,
                    .port => |reference| ports.span(ports.syntax(self.graph, reference)),
                };
            }
            pub fn encoding(self: Value) encodings.Actual {
                return self.graph.source_info.encoding;
            }
            fn reader(self: Value) encodings.Actual {
                return @import("names.zig").reader(caps, self.encoding());
            }
            pub fn kind(self: Value) Kind {
                return self.kindWork(Unmetered{}) catch unreachable;
            }
            pub fn kindWith(self: Value, options: r.Options) r.Error!Kind {
                var work = try r.Work.init(options.limits orelse self.graph.limits, options.cancellation);
                return self.kindWork(&work);
            }
            fn kindWork(self: Value, work: anytype) !Kind {
                if (self.selected == .port) {
                    try work.spend(0);
                    return .string;
                }
                var iterator = self.parts();
                const first = (try iterator.nextWork(work)).?;
                // Certified expression ranges end at their last operand. The
                // first operand's end distinguishes a concatenation without
                // re-reading later operands or scanning twice before parts().
                if (self.span()) |range| if (first.span().?.len != range.len) return .concatenation;
                return if (first.kind() == .markup) .markup else .string;
            }
            pub fn parts(self: Value) Parts {
                return .{ .value = self };
            }
            pub fn partsWith(self: Value, options: r.Options) r.Error!BoundedParts {
                return .{ .iterator = self.parts(), .work = try r.Work.init(options.limits orelse self.graph.limits, options.cancellation) };
            }
            pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.writeLogical(writer);
            }
            /// Logical DOT strings plus unchanged markup interiors. No entity
            /// expansion, text extraction, renderer escapes or variable substitution.
            pub fn writeLogical(self: Value, writer: anytype) !void {
                if (self.selected == .port) return self.writePort(writer, Unmetered{});
                const bytes = self.raw() orelse return;
                switch (self.reader()) {
                    inline else => |actual| if (comptime caps.allows(actual)) {
                        try @import("names.zig").writeUnmetered(actual, bytes, writer);
                    } else unreachable,
                }
            }
            pub fn writeLogicalWith(self: Value, writer: anytype, options: r.Options) !void {
                var work = try r.Work.init(options.limits orelse self.graph.limits, options.cancellation);
                return self.writeWork(writer, &work);
            }
            fn writeWork(self: Value, writer: anytype, work: anytype) !void {
                try work.spend(0);
                if (self.selected == .port) return self.writePort(writer, work);
                const bytes = self.raw() orelse return;
                switch (self.reader()) {
                    inline else => |actual| if (comptime caps.allows(actual)) {
                        try write(actual, bytes, writer, work);
                    } else unreachable, // Encoding was admitted by the owning IR.
                }
            }
            pub fn toString(self: Value, allocator: std.mem.Allocator) r.Error![]u8 {
                return self.toStringWith(allocator, .{});
            }
            fn writePort(self: Value, writer: anytype, work: anytype) !void {
                const port = ports.syntax(self.graph, self.selected.port);
                switch (self.reader()) {
                    inline else => |actual| if (comptime caps.allows(actual)) {
                        try write(actual, self.graph.text(port.first), writer, work);
                        if (port.second) |second| {
                            try work.spend(1);
                            try writer.writeAll(":");
                            try write(actual, self.graph.text(second), writer, work);
                        }
                    } else unreachable,
                }
            }
            /// Two bounded passes, one exact allocation. No growable-buffer
            /// peak/slack. Caller frees the result with the supplied allocator.
            pub fn toStringWith(self: Value, allocator: std.mem.Allocator, options: r.Options) r.Error![]u8 {
                const limits = options.limits orelse self.graph.limits;
                var work = try r.Work.init(limits, options.cancellation);
                var count: Counter = .{};
                try self.writeWork(&count, &work);
                if (count.len > limits.max_bytes) return error.MemoryLimit;
                const output = try allocator.alloc(u8, count.len);
                errdefer allocator.free(output);
                var writer = std.Io.Writer.fixed(output);
                self.writeWork(&writer, &work) catch |err| switch (err) {
                    error.WriteFailed => unreachable, // Exact same immutable value, counted above.
                    else => |failure| return failure,
                };
                return output;
            }
        };

        pub const Operand = struct {
            graph: *const Graph,
            // One representation, not two optional payloads: ordinary operand
            // views do not grow just to carry a derived port reference.
            selected: union(enum) { written: operands.Part, port: attrs.PortReference, empty },
            pub fn kind(self: Operand) OperandKind {
                return if (self.selected == .written and self.selected.written.form == .html) .markup else .string;
            }
            pub fn form(self: Operand) ?operands.Part.Form {
                return if (self.selected == .written) self.selected.written.form else null;
            }
            pub fn span(self: Operand) ?Range {
                return switch (self.selected) {
                    .written => |part| .{ .start = part.raw.start, .len = part.raw.len },
                    .port => |reference| ports.span(ports.syntax(self.graph, reference)),
                    .empty => null,
                };
            }
            pub fn innerSpan(self: Operand) ?Range {
                return if (self.selected == .written) .{ .start = self.selected.written.inner.start, .len = self.selected.written.inner.len } else null;
            }
            pub fn raw(self: Operand) ?[]const u8 {
                return if (self.span()) |range| self.graph.text(range) else null;
            }
            pub fn encoding(self: Operand) encodings.Actual {
                return self.graph.source_info.encoding;
            }
            pub fn fragment(self: Operand) ?EncodedFragment {
                if (self.kind() != .markup) return null;
                const inner = self.innerSpan().?;
                return .{ .input = .{ .bytes = self.graph.text(inner), .origin = inner.start }, .encoding = self.encoding() };
            }
            fn value(self: Operand) Value {
                return .{ .graph = self.graph, .selected = if (self.selected == .port) .{ .port = self.selected.port } else if (self.span()) |range| .{ .written = range } else .empty };
            }
            pub fn format(self: Operand, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.value().format(writer);
            }
            pub fn writeLogical(self: Operand, writer: anytype) !void {
                return self.value().writeLogical(writer);
            }
            pub fn writeLogicalWith(self: Operand, writer: anytype, options: r.Options) !void {
                return self.value().writeLogicalWith(writer, options);
            }
        };

        pub const Parts = struct {
            value: Value,
            offset: u32 = 0,
            done: bool = false,
            pub fn next(self: *Parts) ?Operand {
                return self.nextWork(Unmetered{}) catch unreachable;
            }
            fn nextWork(self: *Parts, work: anytype) !?Operand {
                if (self.done) return null;
                try work.spend(0);
                if (self.value.selected == .port) {
                    self.done = true;
                    return .{ .graph = self.value.graph, .selected = .{ .port = self.value.selected.port } };
                }
                const range = self.value.span() orelse {
                    self.done = true;
                    return .{ .graph = self.value.graph, .selected = .empty };
                };
                const bytes = self.value.graph.text(range);
                const part = switch (self.value.reader()) {
                    inline else => |actual| if (comptime caps.allows(actual)) blk: {
                        const E = encodings.Reader(actual);
                        var iterator: operands.ForEncoding(actual).Parts = .{
                            .input = .{ .bytes = bytes, .origin = range.start },
                            .compound = E.byteAt(bytes, 0) == '"' or E.byteAt(bytes, 0) == '<',
                            .offset = self.offset,
                        };
                        const part = try iterator.nextWith(work);
                        self.offset = iterator.offset;
                        break :blk part;
                    } else unreachable,
                };
                self.done = self.offset == range.len;
                return if (part) |found| .{ .graph = self.value.graph, .selected = .{ .written = found } } else null;
            }
        };

        pub const BoundedParts = struct {
            iterator: Parts,
            work: r.Work,
            failure: ?r.Error = null,
            /// Cumulative work over the iterator lifetime. Errors are terminal
            /// and repeat; null only means exhaustion. No deinit/allocation.
            pub fn next(self: *BoundedParts) r.Error!?Operand {
                if (self.failure) |err| return err;
                return self.iterator.nextWork(&self.work) catch |err| {
                    self.failure = err;
                    return err;
                };
            }
        };
    };
}

const Counter = struct {
    len: usize = 0,
    fn writeAll(self: *Counter, bytes: []const u8) r.Error!void {
        self.len = std.math.add(usize, self.len, bytes.len) catch return error.IndexLimit;
    }
};

fn write(comptime actual: encodings.Actual, bytes: []const u8, writer: anytype, work: anytype) !void {
    const E = encodings.Reader(actual);
    var chunks: logical.ForEncoding(actual).Chunks = .{ .raw = bytes };
    while (try chunks.nextWith(work)) |chunk| {
        if (comptime E.width == 1) {
            try work.spend(chunk.len);
            try writer.writeAll(chunk);
        } else {
            var at: usize = 0;
            while (at < chunk.len) {
                try work.spend(2 * E.width); // Covers a UTF-16 surrogate pair too.
                const scalar = E.decode(chunk, at) catch unreachable; // Certified at lowering.
                at += scalar.len;
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(scalar.scalar, &utf8) catch unreachable;
                try writer.writeAll(utf8[0..len]);
            }
        }
    }
    try work.spend(0);
}

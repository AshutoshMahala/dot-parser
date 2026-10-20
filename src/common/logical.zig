//! Shared, allocation-free logical-value reading. Host adapters own spelling;
//! this module owns bounded scalar decoding and original-source coordinates.
const std = @import("std");
const encoding = @import("encoding.zig");
const Fragment = @import("processor.zig").Fragment;
const Span = @import("location.zig").Span;

pub const SourceLocation = struct {
    span: Span,
    /// Original opening delimiter (or content start). Distinguishes operands
    /// without retaining an operand array or a pointer into mutable reader state.
    segment_start: u32,
    /// Exact spelling of an item versus a whole-value/enclosing highlight.
    /// Neither is permission to splice logical replacement bytes into source.
    mapping: enum { exact, enclosing } = .exact,
};
pub const Scalar = struct { codepoint: u21, location: SourceLocation };
pub const Failure = struct {
    reason: enum { invalid_encoding, invalid_syntax, unresolved_reference, unsupported_form },
    location: SourceLocation,
};
pub const Step = union(enum) { pending, scalar: Scalar, end, failure: Failure };
pub const BorrowedContents = struct {
    bytes: []const u8,
    encoding: encoding.Actual,
    location: SourceLocation,
};
/// Maximum scalar-equivalent run offered by the optional reader batch contract.
pub const ascii_width = 16;

/// Content only: no BOM removal, escapes, normalization or host grammar. Each
/// step consumes at most one physical code unit; assembling a UTF-8 scalar or
/// surrogate pair can yield pending. Constant-time decoding examines <=4 bytes.
/// Admission never scans. Source must remain immutable and outlive all views.
/// Copying/moving this reader preserves progress: no pointers into its own state.
pub fn Reader(comptime actual: encoding.Actual) type {
    const E = encoding.Reader(actual);
    return struct {
        const Self = @This();
        pub const encoding_kind = actual;
        input: Fragment,
        offset: u32 = 0,
        segment_start: u32,
        buffer: [4]u8 = undefined,
        buffered: u3 = 0,
        needed: u3 = 0,
        failure: ?Failure = null,

        pub fn init(input: Fragment) Fragment.Error!Self {
            return .{ .input = try Fragment.init(input.bytes, input.origin), .segment_start = input.origin };
        }
        pub fn fragment(self: *const Self) Fragment {
            return self.input;
        }
        /// A fresh traversal, retaining the source but no progress or failure.
        pub fn restarted(self: *const Self) Fragment.Error!Self {
            return init(self.input);
        }
        pub fn location(self: *const Self) SourceLocation {
            return .{ .span = .{ .start = self.input.origin, .len = @intCast(self.input.bytes.len) }, .segment_start = self.input.origin };
        }
        /// No scan and no validity claim: unchanged borrowed contents only.
        pub fn contiguous(self: *const Self) ?BorrowedContents {
            return .{ .bytes = self.input.bytes, .encoding = actual, .location = self.location() };
        }
        pub fn position(self: *const Self) u32 {
            return self.offset;
        }
        /// A bounded, unchanged ASCII run at the current cursor. No input is
        /// consumed; empty means use step(). No terminal/failure is skipped.
        pub inline fn asciiRun(self: *const Self) []const u8 {
            if (comptime actual != .utf8 and actual != .ascii) return &.{};
            if (self.failure != null or self.buffered != 0 or self.offset >= self.input.bytes.len or
                self.input.bytes.len - self.offset < ascii_width) return &.{};
            const bytes = self.input.bytes[self.offset..][0..ascii_width];
            const block: @Vector(ascii_width, u8) = bytes.*;
            return if (@reduce(.Or, block) & 0x80 == 0) bytes else &.{};
        }
        /// Checked commit: equivalent to count scalar-producing step() calls.
        /// These bytes remain borrowed; no caller-provided span is trusted.
        pub inline fn skipAscii(self: *Self, count: u32) bool {
            if (count == 0 or count > self.asciiRun().len) return false;
            self.offset += count;
            return true;
        }
        pub fn step(self: *Self) Step {
            if (self.failure) |f| return .{ .failure = f };
            const start = self.offset - self.buffered;
            if (self.offset == self.input.bytes.len) {
                if (self.buffered != 0) return self.fail(start, self.offset - start);
                return .end;
            }
            const remaining = self.input.bytes.len - self.offset;
            if (remaining < E.width) return self.fail(start, @intCast(self.input.bytes.len - start));
            const unit = E.unit(self.input.bytes, self.offset);
            if (self.buffered == 0) {
                // Common ASCII path does not initialize the assembly buffer.
                if (unit < 128) {
                    self.offset += E.width;
                    return self.scalar(@intCast(unit), start, E.width);
                }
                self.needed = if (actual == .utf8)
                    std.unicode.utf8ByteSequenceLength(@intCast(unit)) catch return self.fail(start, E.width)
                else if (E.width == 2 and unit >= 0xd800 and unit <= 0xdbff) 4 else E.width;
            }
            @memcpy(self.buffer[self.buffered..][0..E.width], self.input.bytes[self.offset..][0..E.width]);
            self.buffered += E.width;
            self.offset += E.width;
            if (self.buffered < self.needed) return .pending;
            const decoded = E.decode(self.buffer[0..self.buffered], 0) catch return self.fail(start, self.buffered);
            const length = self.buffered;
            self.buffered = 0;
            self.needed = 0;
            return self.scalar(decoded.scalar, start, length);
        }
        fn scalar(self: *const Self, codepoint: u21, start: u32, len: u32) Step {
            return .{ .scalar = .{ .codepoint = codepoint, .location = .{
                .span = .{ .start = self.input.origin + start, .len = len },
                .segment_start = self.segment_start,
            } } };
        }
        fn fail(self: *Self, start: u32, len: u32) Step {
            self.failure = .{ .reason = .invalid_encoding, .location = .{
                .span = .{ .start = self.input.origin + start, .len = len },
                .segment_start = self.segment_start,
            } };
            return .{ .failure = self.failure.? };
        }
    };
}

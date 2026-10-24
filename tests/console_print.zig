const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");

// Capture only caller-IO writes to stderr; no process-global redirection.
const Capture = struct {
    bytes: [32 * 1024]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,
    max_write: usize = std.math.maxInt(usize),

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.operate = operate;
        break :blk table;
    };

    fn io(self: *Capture) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    fn operate(context: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        const request = switch (operation) {
            .file_write_streaming => |request| request,
            else => unreachable,
        };
        std.debug.assert(request.file.handle == std.Io.File.stderr().handle);
        self.calls += 1;
        const before = self.len;
        var left = self.max_write;
        self.append(request.header, &left);
        for (request.data, 0..) |bytes, index| {
            const repeat = if (index + 1 == request.data.len) request.splat else 1;
            for (0..repeat) |_| self.append(bytes, &left);
        }
        return .{ .file_write_streaming = self.len - before };
    }

    fn append(self: *Capture, bytes: []const u8, left: *usize) void {
        const n = @min(left.*, bytes.len);
        @memcpy(self.bytes[self.len..][0..n], bytes[0..n]);
        self.len += n;
        left.* -= n;
    }
};

fn expectPrinted(comptime R: type, items: anytype, options: dot.console.RenderOptions, max_write: usize) !void {
    var expected_buffer: [32 * 1024]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_buffer);
    for (items, 1..) |item, n| try R.renderBoxed(item, n, options, &expected);

    var capture: Capture = .{ .max_write = max_write };
    try R.printDiagnostics(capture.io(), items, options);
    try std.testing.expectEqualStrings(expected.buffered(), capture.bytes[0..capture.len]);
    try std.testing.expect(capture.calls > 0);
}

test "diagnostic printing flushes numbered boxes in order through caller IO" {
    const findings = [_]dot.Diagnostic{
        .{ .code = .syntax_unexpected_token, .span = .{ .start = 5, .len = 1 } },
        .{ .code = .syntax_ambiguous_numeral, .span = .{ .start = 7, .len = 3 } },
    };
    const options: dot.console.RenderOptions = .{ .source = "graph} 1e3", .source_name = "graph.dot" };
    try expectPrinted(dot.console, &findings, options, std.math.maxInt(usize));
    // Short writes still flush the entire output, without duplicating bytes.
    try expectPrinted(dot.console, &findings, options, 7);
    var many: [40]dot.Diagnostic = undefined;
    for (&many, 0..) |*finding, i| finding.* = findings[i % findings.len];
    try expectPrinted(dot.console, &many, .{ .style = .ascii }, 251);
}

test "diagnostic printing skips IO for empty input and propagates write failures" {
    try dot.console.printDiagnostics(.failing, &.{}, .{});
    const findings = [_]dot.Diagnostic{
        .{ .code = .syntax_unexpected_token, .span = .{ .start = 0, .len = 1 } },
    };
    // A short message fails on the final flush; a long list fails during rendering.
    try std.testing.expectError(error.WriteFailed, dot.console.printDiagnostics(.failing, &findings, .{}));
    const many: [40]dot.Diagnostic = @splat(findings[0]);
    try std.testing.expectError(error.WriteFailed, dot.console.printDiagnostics(.failing, &many, .{}));
}

test "markup and composed diagnostic printing use their own shared adapters" {
    const finding: markup.Diagnostic = .{ .code = .unexpected_close, .span = .{ .start = 2, .len = 1 } };
    try markup.console.printDiagnostics(.failing, &.{}, .{});
    const markup_findings = [_]markup.Diagnostic{finding};
    try expectPrinted(markup.console, &markup_findings, .{ .source = "</b>" }, 13);

    const Parser = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    const findings = [_]Parser.Diagnostic{
        .{ .dot = .{ .code = .syntax_unexpected_token, .span = .{ .start = 0, .len = 1 } } },
        .{ .markup = finding },
    };
    try Parser.console.printDiagnostics(.failing, &.{}, .{});
    try expectPrinted(Parser.console, &findings, .{ .source = "</b>" }, 7);
    try std.testing.expectError(error.WriteFailed, Parser.console.printDiagnostics(.failing, &findings, .{}));
}

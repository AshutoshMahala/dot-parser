const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const strings = std.testing.expectEqualStrings;
const IR = dot.ir.Lowering(.{});

fn lower(source: []const u8) !IR.Graph {
    var parsed = dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    return IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = dot.Profile(.{}).interpretation(&parsed.document.?, .{}) });
}

fn value(ir: anytype) @TypeOf(ir.*).ValueView {
    var nodes = ir.nodeIterator();
    return nodes.next().?.attribute("label").?.value();
}

fn joined(expected: []const u8, v: anytype) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{v});
    try strings(expected, writer.buffered());
    writer.end = 0;
    try v.writeLogical(&writer);
    try strings(expected, writer.buffered());
    writer.end = 0;
    try v.writeLogicalWith(&writer, .{});
    try strings(expected, writer.buffered());
    const copy = try v.toString(a);
    defer a.free(copy);
    try strings(expected, copy);
}

test "IR value forms preserve raw operands glue and joined DOT semantics" {
    const Case = struct { raw: []const u8, joined: []const u8, kind: dot.ir.ValueKind, parts: u32 };
    const cases = [_]Case{
        .{ .raw = "red", .joined = "red", .kind = .string, .parts = 1 },
        .{ .raw = "-12.50", .joined = "-12.50", .kind = .string, .parts = 1 },
        .{ .raw = "\"\"", .joined = "", .kind = .string, .parts = 1 },
        .{ .raw = "<>", .joined = "", .kind = .markup, .parts = 1 },
        .{ .raw = "\"a&amp;b\"", .joined = "a&amp;b", .kind = .string, .parts = 1 },
        .{ .raw = "<<b>A&amp;B</b>>", .joined = "<b>A&amp;B</b>", .kind = .markup, .parts = 1 },
        .{ .raw = "\"a\" + \"bee\"", .joined = "abee", .kind = .concatenation, .parts = 2 },
        .{ .raw = "\"a\" + <<b><c>bee</c></b>>", .joined = "a<b><c>bee</c></b>", .kind = .concatenation, .parts = 2 },
        .{ .raw = "<>+\"\"+<>", .joined = "", .kind = .concatenation, .parts = 3 },
        .{ .raw = "\"a\" /* < > \" */ + // < > \"\n\"b\"", .joined = "ab", .kind = .concatenation, .parts = 2 },
        .{ .raw = "\"a\" +\n# \"<fake>\"\n\"b\"", .joined = "ab", .kind = .concatenation, .parts = 2 },
        .{ .raw = "\"a\\\"b\\N\\n\"", .joined = "a\"b\\N\\n", .kind = .string, .parts = 1 },
        .{ .raw = "\"a\\\nb\\\r\nc\"", .joined = "abc", .kind = .string, .parts = 1 },
        .{ .raw = "\"café😀\" + <中文>", .joined = "café😀中文", .kind = .concatenation, .parts = 2 },
        .{ .raw = "\"\xff\"", .joined = "\xff", .kind = .string, .parts = 1 },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "digraph {{ a[label={s}] }}", .{case.raw});
        defer a.free(source);
        var ir = try lower(source);
        defer ir.deinit();
        const retained = ir.retainedBytes();
        const v = value(&ir);
        try equal(case.kind, v.kind());
        try equal(case.kind, try v.kindWith(.{}));
        try strings(case.raw, v.raw().?);
        try equal(@as(u32, 18), v.span().?.start);
        try joined(case.joined, v);
        var parts = v.parts();
        var bounded = try v.partsWith(.{});
        var count: u32 = 0;
        var last_end: u32 = v.span().?.start;
        while (parts.next()) |part| : (count += 1) {
            const same = (try bounded.next()).?;
            try std.testing.expectEqualDeep(part, same);
            try expect(part.span().?.start >= last_end);
            last_end = part.span().?.start + part.span().?.len;
            try strings(ir.text(part.span().?), part.raw().?);
            if (part.fragment()) |fragment| {
                try equal(.markup, part.kind());
                try equal(part.innerSpan().?.start, fragment.input.origin);
                try strings(ir.text(part.innerSpan().?), fragment.input.bytes);
                try equal(v.encoding(), fragment.encoding);
            } else try equal(.string, part.kind());
        }
        try equal(case.parts, count);
        try equal(v.span().?.start + v.span().?.len, last_end);
        try expect(parts.next() == null);
        try expect(try bounded.next() == null);
        try equal(retained, ir.retainedBytes());
    }
}

test "IR implicit empty is one sourceless operand distinct from absent and written empties" {
    var ir = try lower("graph {a; b[label=\"\"]; c[label=<>]}");
    defer ir.deinit();
    var nodes = ir.nodeIterator();
    const first = nodes.next().?;
    try expect(first.attribute("missing") == null);
    const empty = first.attribute("label").?.value();
    try equal(.string, empty.kind());
    try expect(empty.raw() == null and empty.span() == null);
    try joined("", empty);
    var parts = empty.parts();
    const part = parts.next().?;
    try equal(.string, part.kind());
    try expect(part.raw() == null and part.span() == null and part.innerSpan() == null and part.form() == null and part.fragment() == null);
    try expect(parts.next() == null);
    const quoted = nodes.next().?.attribute("label").?.value();
    try equal(.string, quoted.kind());
    try strings("\"\"", quoted.raw().?);
    const html = nodes.next().?.attribute("label").?.value();
    try equal(.markup, html.kind());
    try strings("<>", html.raw().?);
}

test "IR views stay usable after iterator advancement and without query budgets" {
    var ir = try lower("digraph {label=\"graph\"; a[label=\"a\"+\"bee\"]; a->b[label=<<b>x</b>>]}");
    defer ir.deinit();
    ir.limits.max_work = 0;
    var nodes = ir.nodeIterator();
    const node = nodes.next().?;
    const v = node.attribute("label").?.value();
    while (nodes.next() != null) {}
    var parts = v.parts();
    const first = parts.next().?;
    while (parts.next() != null) {}
    try strings("\"a\"", first.raw().?);
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}:{f}:{f}", .{ node.name(), first, v });
    try strings("a:a:abee", writer.buffered());
    try equal(.concatenation, v.kind());
    try expect((try ir.scopeView(.root)).attribute("label") != null);
    try std.testing.expectError(error.WorkLimit, node.attributeWith("label", .{}));
    try std.testing.expectError(error.WorkLimit, v.kindWith(.{}));
    try std.testing.expectError(error.WorkLimit, v.toString(a));
    var edges = try ir.edgeIterator(.{ .limits = .{} });
    defer edges.deinit();
    const edge = (try edges.next()).?;
    try std.testing.expectError(error.WorkLimit, edge.attribute("label"));
}

const Polls = struct {
    count: u32 = 0,
    stop: u32,
    fn poll(ctx: ?*anyopaque) bool {
        const self: *Polls = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        return self.count >= self.stop;
    }
    fn options(self: *Polls) dot.ir.Options {
        return .{ .cancellation = .{ .context = self, .is_requested = poll } };
    }
};

fn owningFailure(allocator: std.mem.Allocator, v: IR.Graph.ValueView) !void {
    const result = try v.toString(allocator);
    defer allocator.free(result);
    try strings("abee", result);
}

test "IR bounded values retain cumulative terminal failures writer failures and exact allocation limits" {
    var ir = try lower("graph {a[label=\"a\"+\"bee\"]}");
    defer ir.deinit();
    const v = value(&ir);
    var parts = try v.partsWith(.{ .limits = .{ .max_work = 5 } });
    try expect(try parts.next() != null);
    try std.testing.expectError(error.WorkLimit, parts.next());
    try std.testing.expectError(error.WorkLimit, parts.next());
    var polls: Polls = .{ .stop = 1 };
    try std.testing.expectError(error.Cancelled, v.partsWith(polls.options()));
    try std.testing.expectError(error.Cancelled, v.toStringWith(a, polls.options()));
    polls = .{ .stop = 1000 };
    var cancelled = try v.partsWith(polls.options());
    try expect(try cancelled.next() != null);
    polls.stop = 0;
    try std.testing.expectError(error.Cancelled, cancelled.next());
    polls.stop = 1000;
    try std.testing.expectError(error.Cancelled, cancelled.next());
    var bytes: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expectError(error.WriteFailed, v.writeLogical(&writer));
    writer.end = 0;
    try std.testing.expectError(error.WriteFailed, v.writeLogicalWith(&writer, .{}));
    try std.testing.expectError(error.MemoryLimit, v.toStringWith(a, .{ .limits = .{ .max_bytes = 3 } }));
    const exact = try v.toStringWith(a, .{ .limits = .{ .max_bytes = 4 } });
    defer a.free(exact);
    try strings("abee", exact);
    try std.testing.checkAllAllocationFailures(a, owningFailure, .{v});
    // Failure can happen in either pass; every failed allocation is cleaned up.
    for (0..80) |budget| {
        const result = v.toStringWith(a, .{ .limits = .{ .max_work = budget } }) catch |err| {
            try equal(error.WorkLimit, err);
            continue;
        };
        a.free(result);
    }
}

test "IR bounded traversal polls inside long quotes markup and concatenation glue" {
    const long: [4096]u8 = @splat('z');
    inline for (.{ "\"" ++ long ++ "\"", "<<b>" ++ long ++ "</b>>", "\"a\" /*" ++ long ++ "*/ + \"b\"", "\"a\" + //" ++ long ++ "\n\"b\"" }) |raw| {
        var ir = try lower("graph {a[label=" ++ raw ++ "]}");
        defer ir.deinit();
        const v = value(&ir);
        var polls: Polls = .{ .stop = 32 };
        var parts = try v.partsWith(polls.options());
        while (parts.next() catch |err| {
            try equal(error.Cancelled, err);
            break;
        }) |_| {}
        try equal(@as(u32, 32), polls.count);
        polls.count = 0;
        var buffer: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.Cancelled, v.writeLogicalWith(&writer, polls.options()));
        try equal(@as(u32, 32), polls.count);
    }
}

test "IR value native encodings preserve byte spans and produce identical UTF-8" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const raw = "\"café\\😀\" + /*glue*/ <<b>中文&amp;</b>> + \"\"";
    const source = "digraph {a[label=" ++ raw ++ "]}";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var encoded: std.Io.Writer.Allocating = .init(a);
        defer encoded.deinit();
        var characters = (try std.unicode.Utf8View.init(source)).iterator();
        while (characters.nextCodepoint()) |cp| {
            if (E.width == 2) {
                if (cp <= 0xffff) try encoded.writer.writeInt(u16, @intCast(cp), E.endian) else {
                    try encoded.writer.writeInt(u16, @intCast(0xd800 + ((cp - 0x10000) >> 10)), E.endian);
                    try encoded.writer.writeInt(u16, @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff)), E.endian);
                }
            } else try encoded.writer.writeInt(u32, cp, E.endian);
        }
        var parsed = try P.parseAndValidate(a, encoded.written(), dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        var ir = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer ir.deinit();
        const v = value(&ir);
        try equal(actual, v.encoding());
        try equal(.concatenation, v.kind());
        try equal(.concatenation, try v.kindWith(.{}));
        try joined("café\\😀<b>中文&amp;</b>", v);
        var parts = v.parts();
        var bounded = try v.partsWith(.{});
        while (parts.next()) |part| {
            try std.testing.expectEqualDeep(part, (try bounded.next()).?);
            try equal(@as(u32, 0), part.span().?.start % E.width);
            try equal(part.span().?.len - 2 * E.width, part.innerSpan().?.len);
            if (part.fragment()) |fragment| {
                try equal(actual, fragment.encoding);
                try equal(part.span().?.start + E.width, fragment.input.origin);
                try equal(part.innerSpan().?.len, fragment.input.bytes.len);
            }
        }
        try expect(try bounded.next() == null);
    }
}

test "IR UTF-8 lowering can borrow an ASCII-profile document without losing encoding provenance" {
    const Ascii = dot.Profile(.{ .source_encodings = &.{} });
    var parsed = try Ascii.parseAndValidate(a, "graph {a[label=\"a\"+<b>]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    var ir = try IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = Ascii.interpretation(&parsed.document.?, .{}) });
    defer ir.deinit();
    const v = value(&ir);
    try equal(.ascii, v.encoding());
    try equal(.concatenation, v.kind());
    try joined("ab", v);
}

test "IR markup operand can be processed explicitly and its existing tree exposes a subtree" {
    var ir = try lower("graph {a[label=\"a\"+<<b><c>bee</c></b>>]}");
    defer ir.deinit();
    var parts = value(&ir).parts();
    try strings("\"a\"", parts.next().?.raw().?);
    const fragment = parts.next().?.fragment().?;
    const P = markup.Profile(.{ .policy = .{ .mode = .structural } });
    var checked = try P.parseAndValidate(a, fragment.input, markup.diagnostic.discard, .{});
    defer checked.deinit();
    try expect(checked.documentValid());
    var roots = checked.parse.document.?.roots();
    const b = roots.next().?;
    try strings("b", b.name().?);
    var children = b.children();
    const c = children.next().?;
    try strings("<c>bee</c>", c.raw());
    try expect(parts.next() == null);
}

test "IR value views agree with checked identifier helpers across generated expressions" {
    const atoms = [_][]const u8{ "\"\"", "<>", "\"a\"", "\"\\\"\"", "\"\\N\"", "\"\\\r\n\"", "<<b>&amp;</b>>", "\"café😀\"", "\"/*+<>*/\"" };
    const glue = [_][]const u8{ "+", " /* \"<a>\" */ + ", "+// \"<b>\"\n", "+\n# ignored\n" };
    for (atoms) |left| for (atoms) |right| for (glue) |separator| {
        const source = try std.fmt.allocPrint(a, "graph {{a[label={s}{s}{s}]}}", .{ left, separator, right });
        defer a.free(source);
        var ir = try lower(source);
        defer ir.deinit();
        const v = value(&ir);
        try equal(dot.identifier.Form.concatenation, try dot.identifier.form(v.raw().?));
        try equal(.concatenation, v.kind());
        var reference: [128]u8 = undefined;
        const expected = try dot.identifier.decodeInto(v.raw().?, &reference);
        try joined(expected, v);
        const range = v.span().?;
        var checked = try dot.identifier.parts(source, .{ .start = range.start, .len = range.len });
        var parts = v.parts();
        while (parts.next()) |part| {
            const ref = checked.next().?;
            try equal(ref.form, part.form().?);
            try equal(ref.raw.start, part.span().?.start);
            try equal(ref.raw.len, part.span().?.len);
            try equal(ref.inner.start, part.innerSpan().?.start);
            try equal(ref.inner.len, part.innerSpan().?.len);
        }
        try expect(checked.next() == null);
    };
}

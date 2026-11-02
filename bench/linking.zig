//! Detect parser code-generation changes caused by linked lexical/name helpers.
//! `zig build bench-linking -Doptimize=small` builds a separate executable per
//! consumer. Helpers run OUTSIDE the timed region: only parsing is measured.
//! Compare fast/safe/small separately; compiler inlining differs between them.
const std = @import("std");
const builtin = @import("builtin");
const dot = @import("dot_parser");
const options = @import("link_options");
const statements = 50_000;

noinline fn parseOnce(allocator: std.mem.Allocator, source: []const u8) !void {
    var result = dot.parseBorrowed(allocator, source, dot.diagnostic.discard, .{});
    defer result.deinit(allocator);
    if (result.outcome != .success) return error.UnexpectedParseFailure;
    std.mem.doNotOptimizeAway(&result);
}

noinline fn linkedHelper(doc: *const dot.Document) u64 {
    switch (options.consumer) {
        .parser_only => return 0,
        .scalar_lexer, .block_lexer => {
            const Lexer = dot.lexer.For(if (options.consumer == .block_lexer) .block else .scalar);
            var lexer = Lexer.init(doc.source);
            const result = lexer.next();
            return if (result == .token) result.token.span.len else 1;
        },
        .checked_identifier => return dot.identifier.hash(doc.source[8..9]) catch 0,
        .checked_document => {
            const node = doc.nodeReference(doc.nodes[0].reference).?;
            return doc.hashIdentifier(node.identifier) catch 0;
        },
        .trusted_name => {
            const node = doc.nodeReference(doc.nodes[0].reference).?;
            return dot.identifier.fromName(doc.source, node.name()).hash() catch 0;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const writer = &file.interface;
    if (options.consumer == .parser_only)
        try writer.writeAll("build,consumer,fixture,bytes,median_ns,MB/s,checksum\n");
    var small = dot.parseBorrowed(init.gpa, "graph { a }", dot.diagnostic.discard, .{});
    defer small.deinit(init.gpa);
    if (small.outcome != .success) return error.UnexpectedParseFailure;

    inline for (.{ "a;\n", "\"node\" -> \"b\" [label=\"xyz\"];\n" }, .{ "nodes", "quoted_edges" }) |line, name| {
        const source = try init.gpa.alloc(u8, 8 + statements * line.len);
        defer init.gpa.free(source);
        @memcpy(source[0..7], "graph {");
        for (0..statements) |i| @memcpy(source[7 + line.len * i ..][0..line.len], line);
        source[source.len - 1] = '}';
        var samples: [15]u64 = undefined;
        var checksum: u64 = 0;
        for (0..18) |round| {
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            for (0..4) |_| try parseOnce(init.gpa, source);
            const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds;
            if (round >= 3) samples[round - 3] = @intCast(@divTrunc(elapsed, 4));
            checksum +%= linkedHelper(&small.document.?);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        const elapsed: f64 = @floatFromInt(samples[7]);
        const bytes: f64 = @floatFromInt(source.len);
        try writer.print("{t},{t},{s},{d},{d},{d:.2},{x}\n", .{
            builtin.mode, options.consumer, name, source.len, samples[7], bytes * 1000 / elapsed, checksum,
        });
        try writer.flush();
    }
}

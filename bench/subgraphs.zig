//! Fixed storage excludes allocation from timing; these are synthetic fixtures.
const std = @import("std");
const dot = @import("dot_parser");
const build_options = @import("build_options");

/// `-Dlexer=scalar|block` pins the scanner; `auto` follows the library default.
const Parser = dot.Profile(.{ .policy = .{ .scanner = selectedBackend() } });

fn selectedBackend() dot.ScannerBackend {
    if (std.mem.eql(u8, build_options.lexer, "auto")) return dot.Profile(.{}).baseline.scanner;
    return std.meta.stringToEnum(dot.ScannerBackend, build_options.lexer) orelse @compileError("-Dlexer must be auto, scalar, or block");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("scanner backend: {s}\n", .{@tagName(Parser.baseline.scanner)});
    inline for (.{ false, true }) |nested| {
        for ([_]usize{ 1000, 10000, 100000 }) |n| {
            const bytes = try allocator.alloc(u8, 8 + 2 * n);
            @memcpy(bytes[0..7], "graph {");
            if (nested) {
                @memset(bytes[7..][0..n], '{');
                @memset(bytes[7 + n ..][0..n], '}');
            } else for (0..n) |i| {
                @memcpy(bytes[7 + 2 * i ..][0..2], "{}");
            }
            bytes[bytes.len - 1] = '}';
            const depth = if (nested) n else 1;
            const Frame = std.meta.Child(@FieldType(dot.ParseScratch, "frames"));
            const memory: dot.ParseMemory = .{
                .document = .{
                    .nodes = &.{},
                    .edges = &.{},
                    .statement_ids = try allocator.alloc(dot.StatementId, n),
                    .subgraphs = try allocator.alloc(dot.Subgraph, n),
                },
                .scratch = .{ .frames = try allocator.alloc(Frame, depth) },
            };
            var times: [9]u64 = undefined;
            for (0..11) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                const result = Parser.parseBorrowedIn(bytes, memory, dot.diagnostic.discard, .{});
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                const doc = result.document orelse return error.ParseFailed;
                if (doc.subgraph_records.len != n) return error.WrongCount;
                var it = doc.statements();
                var visited: usize = 0;
                while (it.nextScoped() != null) visited += 1;
                if (visited != n) return error.WrongTraversal;
                if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            try output.interface.print("{s}, {d} scopes: median {d:.3} ms ({d:.3}–{d:.3}), retained {d} B, scratch {d} B\n", .{
                if (nested) "nested" else "siblings",    n,
                @as(f64, @floatFromInt(times[4])) / 1e6, @as(f64, @floatFromInt(times[0])) / 1e6,
                @as(f64, @floatFromInt(times[8])) / 1e6, n * (@sizeOf(dot.Subgraph) + @sizeOf(dot.StatementId)),
                depth * @sizeOf(Frame),
            });
        }
    }
    try output.interface.flush();
}

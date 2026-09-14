//! Reproducible throughput/memory baseline (milestone 1, step 9;
//! R-PERF-004). Synthesizes a large milestone-grammar document and times
//! `parseAndValidate` over it, with and without capacity hints.
//!
//! Run with: `zig build bench -Doptimize=ReleaseFast`

const std = @import("std");
const dot = @import("dot_parser");

const statement_count = 200_000;
const warmup_rounds = 2;
const rounds = 9;

pub fn main(init: std.process.Init) !void {
    const arena_allocator = init.arena.allocator();

    var source_builder: std.ArrayList(u8) = .empty;
    try source_builder.appendSlice(arena_allocator, "graph {\n");
    var line_buffer: [64]u8 = undefined;
    var i: usize = 0;
    while (i < statement_count) : (i += 1) {
        const line = if (i % 2 == 0)
            try std.fmt.bufPrint(&line_buffer, "n{d};\n", .{i})
        else
            try std.fmt.bufPrint(&line_buffer, "n{d} -- n{d};\n", .{ i - 1, i });
        try source_builder.appendSlice(arena_allocator, line);
    }
    try source_builder.appendSlice(arena_allocator, "}\n");
    const source = source_builder.items;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("source: {d} bytes, {d} statements\n", .{ source.len, statement_count });
    try stdout.print("element sizes: StatementId={d} NodeStatement={d} EdgeStatement={d}\n\n", .{
        @sizeOf(dot.StatementId), @sizeOf(dot.NodeStatement), @sizeOf(dot.EdgeStatement),
    });

    try run(init.io, stdout, source, "default (growing pools)", .{});
    try run(init.io, stdout, source, "with capacity hints", .{
        .parse = .{ .document_capacities = .{
            .statements = statement_count,
            .nodes = statement_count / 2,
            .edges = statement_count / 2,
        } },
    });
    try stdout.flush();
}

fn run(
    io: std.Io,
    stdout: *std.Io.Writer,
    source: []const u8,
    label: []const u8,
    options: dot.CheckOptions,
) !void {
    var times: [rounds]u64 = undefined;
    var retained_bytes: usize = 0;
    var arena_footprint: usize = 0;

    var round: usize = 0;
    while (round < warmup_rounds + rounds) : (round += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var bag: dot.FixedDiagnosticBag(4) = .{};

        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var checked = dot.parseAndValidate(arena.allocator(), source, bag.sink(), options);
        const end = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed: u64 = @intCast(start.durationTo(end).raw.nanoseconds);

        if (checked.outcome != .success or !checked.documentValid()) return error.BenchParseFailed;
        if (round >= warmup_rounds) times[round - warmup_rounds] = elapsed;

        const document = checked.document.?;
        retained_bytes = document.order.len * @sizeOf(dot.StatementId) +
            document.nodes.len * @sizeOf(dot.NodeStatement) +
            document.edges.len * @sizeOf(dot.EdgeStatement) +
            document.edge_chains.len * @sizeOf(dot.EdgeChainStatement) +
            document.edge_links.len * @sizeOf(dot.EdgeLink) +
            document.ported_references.len * @sizeOf(dot.PortedReference) +
            document.attributes.len * @sizeOf(dot.Attribute) +
            document.assignments.len * @sizeOf(dot.Assignment) +
            document.attribute_statements.len * @sizeOf(dot.AttributeStatement);
        // Arena *backing capacity*: includes pool-growth copies and arena
        // block sizing — not live document memory and not process RSS.
        arena_footprint = arena.queryCapacity();
    }

    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    const median_ns = times[rounds / 2];
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1e9;
    const mib = @as(f64, @floatFromInt(source.len)) / (1024.0 * 1024.0);
    try stdout.print(
        \\== {s}
        \\parse+validate: median {d:.2} ms (min {d:.2}, max {d:.2}; {d} rounds after {d} warm-up)
        \\throughput:     {d:.0} MiB/s at median, {d:.0} ns/statement
        \\retained:       {d} bytes ({d:.2} bytes/statement)
        \\arena capacity: {d} bytes (backing capacity, not RSS)
        \\
        \\
    , .{
        label,
        seconds * 1000.0,
        @as(f64, @floatFromInt(times[0])) / 1e6,
        @as(f64, @floatFromInt(times[rounds - 1])) / 1e6,
        rounds,
        warmup_rounds,
        mib / seconds,
        @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(statement_count)),
        retained_bytes,
        @as(f64, @floatFromInt(retained_bytes)) / @as(f64, @floatFromInt(statement_count)),
        arena_footprint,
    });
}

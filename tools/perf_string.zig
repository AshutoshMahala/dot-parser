//! Host-only benchmark orchestration. No parser dependency and no checkout
//! changes: both source trees are snapshotted, then all builds precede timing.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const max_runs = 31;
const csv_header = "case,bytes,ns_per_value,session_bytes,credits,polls";
const help =
    \\zig build perf-string -- [options]
    \\  --baseline REF       Git commit/ref to compare with (default HEAD)
    \\  --modes LIST         ReleaseFast,ReleaseSafe,ReleaseSmall (default Fast,Safe)
    \\  --suites LIST        native,sessions,integration,host-defaults (default native,sessions)
    \\  --runs N             Repeated process runs, odd 3..31 (default 3)
    \\  --threshold PERCENT  Flag median time increases above this (default 5)
    \\  --output DIRECTORY   New report directory; existing directories refused
    \\  --help               Show this help
    \\
    \\Builds the SAME current harness against both source snapshots with the same
    \\compiler. Runs serially, alternating before/after. Writes summary.md,
    \\results.csv, metadata.txt, source snapshots and raw per-run CSVs.
    \\Native covers UTF-8/16/32, exact/available folding modes, built-in/custom.
    \\Sessions covers default, runtime policies, metering and cancellation.
    \\Integration covers host defaults, bound passthrough and attribute processing.
    \\Host-defaults isolates default-only binaries without enabled routing variants.
    \\These are hot-buffer microbenchmarks, not RSS or diagnostic-heavy workloads.
    \\No downloads, branch switches, commits, or library changes. Requires Git.
    \\
;

const Options = struct {
    baseline: []const u8 = "HEAD",
    modes: []const u8 = "ReleaseFast,ReleaseSafe",
    suites: []const u8 = "native,sessions",
    runs: u8 = 3,
    threshold: f64 = 5,
    output: ?[]const u8 = null,
    zig: []const u8 = "zig",
    repo: []const u8 = ".",
    show_help: bool = false,

    fn parse(args: []const []const u8) !Options {
        var result: Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--help")) {
                result.show_help = true;
                continue;
            }
            const known = for ([_][]const u8{ "--baseline", "--modes", "--suites", "--output", "--zig", "--repo", "--runs", "--threshold" }) |option| {
                if (std.mem.eql(u8, arg, option)) break true;
            } else false;
            if (!known) return error.UnknownOption;
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            const value = args[i];
            if (std.mem.eql(u8, arg, "--baseline")) result.baseline = value else if (std.mem.eql(u8, arg, "--modes")) result.modes = value else if (std.mem.eql(u8, arg, "--suites")) result.suites = value else if (std.mem.eql(u8, arg, "--output")) result.output = value else if (std.mem.eql(u8, arg, "--zig")) result.zig = value else if (std.mem.eql(u8, arg, "--repo")) result.repo = value else if (std.mem.eql(u8, arg, "--runs")) {
                result.runs = std.fmt.parseInt(u8, value, 10) catch return error.InvalidRuns;
                if (result.runs < 3 or result.runs > max_runs or result.runs % 2 == 0) return error.InvalidRuns;
            } else if (std.mem.eql(u8, arg, "--threshold")) {
                result.threshold = std.fmt.parseFloat(f64, value) catch return error.InvalidThreshold;
                if (!std.math.isFinite(result.threshold) or result.threshold < 0) return error.InvalidThreshold;
            } else return error.UnknownOption;
        }
        try validList(result.modes, &.{ "ReleaseFast", "ReleaseSafe", "ReleaseSmall" });
        try validList(result.suites, &.{ "native", "sessions", "integration", "host-defaults" });
        if (result.baseline.len == 0) return error.EmptyBaseline;
        return result;
    }
};

fn validList(list: []const u8, allowed: []const []const u8) !void {
    var seen: u32 = 0;
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |part| {
        const index = for (allowed, 0..) |item, i| {
            if (std.mem.eql(u8, part, item)) break i;
        } else return error.InvalidSelection;
        const bit = @as(u32, 1) << @intCast(index);
        if (seen & bit != 0) return error.DuplicateSelection;
        seen |= bit;
    }
}

fn outputParent(output: []const u8) error{InvalidOutputPath}![]const u8 {
    return std.fs.path.dirname(output) orelse if (std.fs.path.isAbsolute(output)) error.InvalidOutputPath else ".";
}

const Row = struct {
    id: []const u8,
    bytes: u64,
    ns: f64,
    state: u64,
    credits: u64,
    polls: u64,

    fn parse(line: []const u8) !Row {
        var fields = std.mem.splitScalar(u8, line, ',');
        const id = fields.next() orelse return error.InvalidRow;
        if (id.len == 0 or std.mem.indexOfAny(u8, id, "\r\n| ") != null) return error.InvalidRow;
        const bytes = try number(fields.next());
        const ns = std.fmt.parseFloat(f64, fields.next() orelse return error.InvalidRow) catch return error.InvalidRow;
        const state = try number(fields.next());
        const credits = try number(fields.next());
        const polls = try number(fields.next());
        if (fields.next() != null or bytes == 0 or !std.math.isFinite(ns) or ns <= 0) return error.InvalidRow;
        return .{ .id = id, .bytes = bytes, .ns = ns, .state = state, .credits = credits, .polls = polls };
    }
    fn number(text: ?[]const u8) !u64 {
        return std.fmt.parseInt(u64, text orelse return error.InvalidRow, 10) catch return error.InvalidRow;
    }
};

const Samples = struct {
    times: [max_runs]f64 = undefined,
    count: u8 = 0,
    row: Row = undefined,
    fn add(self: *Samples, row: Row) !void {
        if (self.count == max_runs) return error.TooManySamples;
        if (self.count != 0 and (self.row.bytes != row.bytes or self.row.state != row.state or self.row.credits != row.credits or self.row.polls != row.polls)) return error.UnstableCounters;
        self.row = row;
        self.times[self.count] = row.ns;
        self.count += 1;
    }
    fn stats(self: Samples) struct { median: f64, min: f64, max: f64 } {
        var copy = self.times;
        const sorted = copy[0..self.count];
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
        return .{ .median = sorted[sorted.len / 2], .min = sorted[0], .max = sorted[sorted.len - 1] };
    }
};
const Entry = struct { key: []const u8, mode: []const u8, suite: []const u8, samples: [2]Samples = .{ .{}, .{} } };
const Verdict = enum { new, removed, within_threshold, slower, faster, inconclusive };
fn verdict(before: Samples, after: Samples, threshold: f64) Verdict {
    if (before.count == 0) return .new;
    if (after.count == 0) return .removed;
    const b = before.stats();
    const a = after.stats();
    const delta = (a.median / b.median - 1) * 100;
    if (@abs(delta) <= threshold) return .within_threshold;
    if (a.min > b.max) return .slower;
    if (a.max < b.min) return .faster;
    return .inconclusive;
}

const Runner = struct {
    gpa: Allocator,
    io: Io,
    options: Options,
    output: []const u8,
    entries: std.StringHashMap(Entry),

    fn path(self: *Runner, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(self.gpa, parts);
    }
    fn fmt(self: *Runner, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, format, args);
    }
    fn save(self: *Runner, name: []const u8, data: []const u8) !void {
        const dest = try self.path(&.{ self.output, name });
        if (std.fs.path.dirname(dest)) |dir| try Io.Dir.cwd().createDirPath(self.io, dir);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dest, .data = data });
    }
    fn command(self: *Runner, argv: []const []const u8) ![]const u8 {
        const result = try std.process.run(self.gpa, self.io, .{ .argv = argv, .cwd = .{ .path = self.options.repo }, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(16 * 1024 * 1024) });
        if (result.term != .exited or result.term.exited != 0) {
            try self.save("failed-command.txt", try self.fmt("{s}\n\n{s}\n{s}", .{ try std.mem.join(self.gpa, " ", argv), result.stdout, result.stderr }));
            std.debug.print("Command failed: {s}\n{s}\nDetails: {s}/failed-command.txt\n", .{ argv[0], result.stderr, self.output });
            return error.CommandFailed;
        }
        return result.stdout;
    }
    fn snapshot(self: *Runner, commit: ?[]const u8, name: []const u8) ![]const u8 {
        const root = try self.path(&.{ self.output, name });
        const prefix = std.mem.trimEnd(u8, try self.command(&.{ "git", "rev-parse", "--show-prefix" }), "\r\n");
        const list = if (commit) |sha|
            try self.command(&.{ "git", "ls-tree", "-rz", "--full-tree", sha, "--", try self.fmt("{s}src", .{prefix}) })
        else
            try self.command(&.{ "git", "ls-files", "-co", "--exclude-standard", "-z", "--", "src" });
        var records = std.mem.splitScalar(u8, list, 0);
        var count: usize = 0;
        var manifest: Io.Writer.Allocating = .init(self.gpa);
        while (records.next()) |record| {
            if (record.len == 0) continue;
            var file = record;
            var git_file = record;
            if (commit != null) {
                const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidGitTree;
                if (!std.mem.startsWith(u8, record, "100644 blob ") and !std.mem.startsWith(u8, record, "100755 blob ")) return error.NonRegularSourceFile;
                git_file = record[tab + 1 ..];
                if (!std.mem.startsWith(u8, git_file, prefix)) return error.InvalidSourcePath;
                file = git_file[prefix.len..];
            }
            if (!sourcePath(file)) return error.InvalidSourcePath;
            const contents = if (commit) |sha|
                try self.command(&.{ "git", "show", "--no-ext-diff", "--no-textconv", try self.fmt("{s}:{s}", .{ sha, git_file }) })
            else blk: {
                const current = try self.path(&.{ self.options.repo, file });
                // Tracked deletions remain in ls-files. Do not resurrect them
                // in the candidate snapshot; required missing imports fail at
                // compilation just as they would in the working tree.
                const stat = Io.Dir.cwd().statFile(self.io, current, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                if (stat.kind != .file) return error.NonRegularSourceFile;
                break :blk try Io.Dir.cwd().readFileAlloc(self.io, current, self.gpa, .limited(16 * 1024 * 1024));
            };
            try self.save(try self.path(&.{ name, file }), contents);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
            try manifest.writer.print("{s} {s}\n", .{ std.fmt.bytesToHex(digest, .lower), file });
            count += 1;
        }
        if (count == 0) return error.EmptySourceSnapshot;
        try self.save(try self.fmt("{s}-sha256.txt", .{name}), manifest.written());
        return root;
    }
    fn binary(self: *Runner, mode: []const u8, suite: []const u8, variant: []const u8) ![]const u8 {
        return self.path(&.{ self.output, "bin", try self.fmt("{s}-{s}-{s}{s}", .{ suite, mode, variant, if (builtin.os.tag == .windows) ".exe" else "" }) });
    }
    fn buildAll(self: *Runner, roots: [2][]const u8) !void {
        var sizes: Io.Writer.Allocating = .init(self.gpa);
        try sizes.writer.writeAll("mode,suite,side,executable_bytes\n");
        try Io.Dir.cwd().createDirPath(self.io, try self.path(&.{ self.output, "bin" }));
        // Freeze the harness too: a later working-tree edit cannot change one
        // side of a comparison halfway through compilation.
        for ([_][]const u8{ "string.zig", "string_sessions.zig", "string_integration.zig", "report.zig" }) |file| {
            const bytes = try Io.Dir.cwd().readFileAlloc(self.io, try self.path(&.{ self.options.repo, "bench", file }), self.gpa, .limited(1024 * 1024));
            try self.save(try self.path(&.{ "harness", file }), bytes);
        }
        try self.save("harness/default_only.zig", "pub const default_only = true;\n");
        try self.save("harness/all_routes.zig", "pub const default_only = false;\n");
        var modes = std.mem.splitScalar(u8, self.options.modes, ',');
        while (modes.next()) |mode| {
            var suites = std.mem.splitScalar(u8, self.options.suites, ',');
            while (suites.next()) |suite| {
                for (roots, [_][]const u8{ "before", "after" }) |root, variant| {
                    std.debug.print("Building {s} / {s} / {s}\n", .{ mode, suite, variant });
                    const harness = if (std.mem.eql(u8, suite, "native")) "string.zig" else if (std.mem.eql(u8, suite, "sessions")) "string_sessions.zig" else "string_integration.zig";
                    const integration_config = if (std.mem.eql(u8, suite, "host-defaults")) "default_only.zig" else "all_routes.zig";
                    _ = try self.command(&.{ self.options.zig, "build-exe", "-O", mode, "-fstrip", "--dep", "string_processor", "--dep", "dot_parser", "--dep", "markup_parser", "--dep", "integration_options", try self.fmt("-Mroot={s}", .{try self.path(&.{ self.output, "harness", harness })}), "--dep", "parser_support", try self.fmt("-Mstring_processor={s}/src/string.zig", .{root}), "--dep", "parser_support", try self.fmt("-Mdot_parser={s}/src/root.zig", .{root}), "--dep", "parser_support", try self.fmt("-Mmarkup_parser={s}/src/markup.zig", .{root}), try self.fmt("-Mparser_support={s}/src/support.zig", .{root}), try self.fmt("-Mintegration_options={s}", .{try self.path(&.{ self.output, "harness", integration_config })}), try self.fmt("-femit-bin={s}", .{try self.binary(mode, suite, variant)}) });
                    const stat = try Io.Dir.cwd().statFile(self.io, try self.binary(mode, suite, variant), .{});
                    try sizes.writer.print("{s},{s},{s},{d}\n", .{ mode, suite, variant, stat.size });
                }
            }
        }
        try self.save("binaries.csv", sizes.written());
    }
    fn ingest(self: *Runner, mode: []const u8, suite: []const u8, side: usize, text: []const u8, repeat: usize) !void {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.MissingHeader, csv_header)) return error.InvalidHeader;
        var seen: std.StringHashMap(void) = .init(self.gpa);
        while (lines.next()) |line| {
            const row = try Row.parse(line);
            if ((try seen.getOrPut(row.id)).found_existing) return error.DuplicateCase;
            const key = try self.fmt("{s}/{s}/{s}", .{ mode, suite, row.id });
            const entry = try self.entries.getOrPut(key);
            if (!entry.found_existing) entry.value_ptr.* = .{ .key = key, .mode = mode, .suite = suite };
            const samples = &entry.value_ptr.samples[side];
            if (samples.count != repeat) return error.MissingCaseInEarlierRun;
            if (entry.value_ptr.samples[1 - side].count != 0 and entry.value_ptr.samples[1 - side].row.bytes != row.bytes) return error.ChangedFixture;
            try samples.add(row);
        }
        if (seen.count() == 0) return error.EmptyBenchmark;
    }
    fn measureAll(self: *Runner) !void {
        var modes = std.mem.splitScalar(u8, self.options.modes, ',');
        while (modes.next()) |mode| {
            var suites = std.mem.splitScalar(u8, self.options.suites, ',');
            while (suites.next()) |suite| {
                for (0..self.options.runs) |repeat| {
                    for (0..2) |turn| {
                        const side = (turn + repeat) % 2;
                        const variant = if (side == 0) "before" else "after";
                        std.debug.print("Timing {s} / {s} / {s} ({d}/{d})\n", .{ mode, suite, variant, repeat + 1, self.options.runs });
                        const raw = try self.command(&.{ try self.binary(mode, suite, variant), "--csv" });
                        try self.save(try self.fmt("raw/{s}-{s}-{s}-{d}.csv", .{ mode, suite, variant, repeat + 1 }), raw);
                        try self.ingest(mode, suite, side, raw, repeat);
                    }
                }
            }
        }
    }
    fn reports(self: *Runner) !void {
        const entries = try self.gpa.alloc(Entry, self.entries.count());
        var it = self.entries.valueIterator();
        var n: usize = 0;
        while (it.next()) |entry| : (n += 1) entries[n] = entry.*;
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.less);
        var csv: Io.Writer.Allocating = .init(self.gpa);
        var md: Io.Writer.Allocating = .init(self.gpa);
        try csv.writer.writeAll("case,status,before_ns,after_ns,time_change_percent,before_MBps,after_MBps,before_min_ns,before_max_ns,after_min_ns,after_max_ns,before_session_bytes,after_session_bytes,before_credits,after_credits,before_polls,after_polls\n");
        try md.writer.print("# String performance comparison\n\nBaseline: `{s}`; candidate: captured working tree.\n\n{d} process runs per side. Native/session harnesses use seven timed batches after two warmups; integration uses nine after three warmups. Compilation and input construction are outside timing. Integration includes host parsing, validation, allocation and disposal. Positive changes mean **more time / slower**, not throughput gain. Threshold: {d:.1}%.\n\n", .{ self.options.baseline, self.options.runs, self.options.threshold });
        try md.writer.writeAll("`slower` means the medians exceed the threshold and the observed run ranges do not overlap; it is a candidate regression, not statistical proof. `inconclusive` means a threshold crossing with overlapping ranges. `within_threshold` is not a guarantee of no regression. New/removed cases are excluded from aggregate changes.\n\nStandalone string processor heap allocations are zero for these discard-sink fixtures. Integration allocates host pools; its separate accounting probe verifies that routed checks add no allocator requests or cumulative requested bytes over the same host parse. This is not process RSS or a peak-memory measurement. Session bytes are caller-owned session size, not total stack; zero means a one-shot call without a reported session size. Integration counters are zero because the composed operation is not metered. Credits and polls for session fixtures are factual counters, not elapsed-time estimates.\n\n## Summary\n\n| Mode / suite | Matched | Geometric mean time change | Slower | Inconclusive | New / removed | State/counter changes |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n");
        var modes = std.mem.splitScalar(u8, self.options.modes, ',');
        while (modes.next()) |mode| {
            var suites = std.mem.splitScalar(u8, self.options.suites, ',');
            while (suites.next()) |suite| {
                var matched: usize = 0;
                var log_ratio: f64 = 0;
                var slower: usize = 0;
                var noisy: usize = 0;
                var added: usize = 0;
                var removed: usize = 0;
                var counters: usize = 0;
                for (entries) |entry| {
                    if (!std.mem.eql(u8, entry.mode, mode) or !std.mem.eql(u8, entry.suite, suite)) continue;
                    const b = entry.samples[0];
                    const a = entry.samples[1];
                    for (entry.samples) |samples| if (samples.count != 0 and samples.count != self.options.runs) return error.MissingCaseInLaterRun;
                    const status = verdict(b, a, self.options.threshold);
                    switch (status) {
                        .new => added += 1,
                        .removed => removed += 1,
                        .slower => slower += 1,
                        .inconclusive => noisy += 1,
                        else => {},
                    }
                    if (b.count == 0 or a.count == 0) continue;
                    matched += 1;
                    log_ratio += @log(a.stats().median / b.stats().median);
                    if (a.row.state != b.row.state or a.row.credits != b.row.credits or a.row.polls != b.row.polls) counters += 1;
                }
                if (matched == 0) return error.NoMatchedCases;
                try md.writer.print("| {s} / {s} | {d} | {d:.2}% | {d} | {d} | {d} / {d} | {d} |\n", .{ mode, suite, matched, (@exp(log_ratio / @as(f64, @floatFromInt(matched))) - 1) * 100, slower, noisy, added, removed, counters });
            }
        }
        try md.writer.writeAll("\n## Cases\n\nAll times are ns/value; an integration value is one complete document (2,000 selected attributes), not one string. MB/s uses physical source bytes and decimal MB. Wide encodings must be compared by time as well as bytes/s. Raw per-run medians and full counters are retained in `results.csv` and `raw/`.\n\n| Case | Status | Before ns | After ns | Time change | Before MB/s | After MB/s |\n| --- | --- | ---: | ---: | ---: | ---: | ---: |\n");
        for (entries) |entry| {
            const b = entry.samples[0];
            const a = entry.samples[1];
            const status = @tagName(verdict(b, a, self.options.threshold));
            try writeCsvEntry(&csv.writer, entry, status);
            if (b.count == 0 or a.count == 0) {
                const s = if (a.count != 0) a else b;
                const ns = s.stats().median;
                if (a.count != 0)
                    try md.writer.print("| {s} | {s} | — | {d:.2} | — | — | {d:.2} |\n", .{ entry.key, status, ns, @as(f64, @floatFromInt(s.row.bytes)) * 1000 / ns })
                else
                    try md.writer.print("| {s} | {s} | {d:.2} | — | — | {d:.2} | — |\n", .{ entry.key, status, ns, @as(f64, @floatFromInt(s.row.bytes)) * 1000 / ns });
                continue;
            }
            const bs = b.stats();
            const as = a.stats();
            const delta = (as.median / bs.median - 1) * 100;
            const bm = @as(f64, @floatFromInt(b.row.bytes)) * 1000 / bs.median;
            const am = @as(f64, @floatFromInt(a.row.bytes)) * 1000 / as.median;
            try md.writer.print("| {s} | {s} | {d:.2} | {d:.2} | {d:.2}% | {d:.2} | {d:.2} |\n", .{ entry.key, status, bs.median, as.median, delta, bm, am });
        }
        try self.save("results.csv", csv.written());
        try self.save("summary.md", md.written());
        std.debug.print("Report: {s}/summary.md\nRaw data: {s}/results.csv\n", .{ self.output, self.output });
    }
};

fn floatCell(writer: *Io.Writer, value: ?f64) !void {
    try writer.writeByte(',');
    if (value) |number| try writer.print("{d:.4}", .{number});
}
fn intCell(writer: *Io.Writer, value: ?u64) !void {
    try writer.writeByte(',');
    if (value) |number| try writer.print("{d}", .{number});
}
fn writeCsvEntry(writer: *Io.Writer, entry: Entry, status: []const u8) !void {
    const b = entry.samples[0];
    const a = entry.samples[1];
    try writer.print("{s},{s}", .{ entry.key, status });
    for (entry.samples) |s| try floatCell(writer, if (s.count != 0) s.stats().median else null);
    try floatCell(writer, if (b.count != 0 and a.count != 0) (a.stats().median / b.stats().median - 1) * 100 else null);
    for (entry.samples) |s| try floatCell(writer, if (s.count != 0) @as(f64, @floatFromInt(s.row.bytes)) * 1000 / s.stats().median else null);
    for (entry.samples) |s| {
        try floatCell(writer, if (s.count != 0) s.stats().min else null);
        try floatCell(writer, if (s.count != 0) s.stats().max else null);
    }
    for (entry.samples) |s| try intCell(writer, if (s.count != 0) s.row.state else null);
    for (entry.samples) |s| try intCell(writer, if (s.count != 0) s.row.credits else null);
    for (entry.samples) |s| try intCell(writer, if (s.count != 0) s.row.polls else null);
    try writer.writeByte('\n');
}

fn sourcePath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/") or std.mem.indexOfAny(u8, path, "\\\r\n") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const options = Options.parse(args[1..]) catch |err| {
        std.debug.print("{s}\n{s}", .{ @errorName(err), help });
        return err;
    };
    if (options.show_help) {
        std.debug.print("{s}", .{help});
        return;
    }
    const output_name = options.output orelse try std.fmt.allocPrint(gpa, "zig-out/perf-string/{d}", .{Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds});
    const output = try std.fs.path.resolve(gpa, &.{ options.repo, output_name });
    const parent = try outputParent(output);
    try Io.Dir.cwd().createDirPath(init.io, parent);
    // Refuse reuse: never overwrite earlier evidence or unrelated user files.
    try Io.Dir.cwd().createDir(init.io, output, .default_dir);
    var runner: Runner = .{ .gpa = gpa, .io = init.io, .options = options, .output = output, .entries = .init(gpa) };
    const version = std.mem.trim(u8, try runner.command(&.{ options.zig, "version" }), "\r\n");
    const commit = std.mem.trim(u8, try runner.command(&.{ "git", "rev-parse", "--verify", "--end-of-options", try runner.fmt("{s}^{{commit}}", .{options.baseline}) }), "\r\n");
    const head = std.mem.trim(u8, try runner.command(&.{ "git", "rev-parse", "HEAD" }), "\r\n");
    const status = try runner.command(&.{ "git", "status", "--porcelain", "--", "src", "bench" });
    try runner.save("metadata.txt", try runner.fmt("schema=1\nzig={s}\ncompiler={s}\nhost={s}-{s}\nbaseline={s}\nhead={s}\nmodes={s}\nsuites={s}\nruns={d}\nthreshold_time_percent={d}\nworking_tree_status:\n{s}", .{ version, options.zig, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), commit, head, options.modes, options.suites, options.runs, options.threshold, status }));
    const before = try runner.snapshot(commit, "before");
    const after = try runner.snapshot(null, "after");
    try runner.buildAll(.{ before, after });
    std.debug.print("All builds finished. Starting serial measurements; avoid other heavy work.\n", .{});
    try runner.measureAll();
    try runner.reports();
}

test "report options reject ambiguous or unbounded configurations" {
    const t = std.testing;
    const o = try Options.parse(&.{ "--baseline", "v0.5.0", "--runs", "5", "--modes", "ReleaseSmall", "--suites", "sessions" });
    try t.expectEqual(@as(u8, 5), o.runs);
    const hosts = try Options.parse(&.{ "--suites", "host-defaults,integration" });
    try t.expectEqualStrings("host-defaults,integration", hosts.suites);
    try t.expectError(error.InvalidRuns, Options.parse(&.{ "--runs", "2" }));
    try t.expectError(error.InvalidRuns, Options.parse(&.{ "--runs", "255" }));
    try t.expectError(error.MissingOptionValue, Options.parse(&.{"--baseline"}));
    try t.expectError(error.UnknownOption, Options.parse(&.{"--unknown"}));
    try t.expectError(error.DuplicateSelection, Options.parse(&.{ "--modes", "ReleaseFast,ReleaseFast" }));
    try t.expectError(error.InvalidSelection, Options.parse(&.{ "--suites", "native," }));
    try t.expectError(error.InvalidThreshold, Options.parse(&.{ "--threshold", "nan" }));
    try t.expectError(error.InvalidOutputPath, outputParent("/"));
    try t.expectEqualStrings(".", try outputParent("report"));
    try t.expectEqualStrings("reports", try outputParent("reports/run"));
}

test "CSV rejects malformed samples and changed work counters" {
    const t = std.testing;
    const row = try Row.parse("long_ascii/budget1,4200,123.45,128,12610,0");
    try t.expectEqual(@as(u64, 4200), row.bytes);
    try t.expectError(error.InvalidRow, Row.parse("x,1,nan,0,0,0"));
    try t.expectError(error.InvalidRow, Row.parse("x,1,0,0,0,0"));
    try t.expectError(error.InvalidRow, Row.parse("x,1,2,0,0,0,extra"));
    var samples: Samples = .{};
    try samples.add(row);
    var changed = row;
    changed.credits += 1;
    try t.expectError(error.UnstableCounters, samples.add(changed));
}

test "noise is not a regression verdict and new cases have no baseline" {
    const t = std.testing;
    var b: Samples = .{};
    var a: Samples = .{};
    for ([_]f64{ 100, 101, 102 }) |ns| try b.add(.{ .id = "x", .bytes = 1, .ns = ns, .state = 0, .credits = 0, .polls = 0 });
    for ([_]f64{ 100, 120, 121 }) |ns| try a.add(.{ .id = "x", .bytes = 1, .ns = ns, .state = 0, .credits = 0, .polls = 0 });
    try t.expectEqual(.inconclusive, verdict(b, a, 5));
    a.times[0] = 119;
    try t.expectEqual(.slower, verdict(b, a, 5));
    try t.expectEqual(.faster, verdict(a, b, 5));
    try t.expectEqual(.new, verdict(.{}, a, 5));
    try t.expectEqual(.removed, verdict(a, .{}, 5));
    try t.expectEqual(.within_threshold, verdict(b, b, 5));
}

test "snapshot paths cannot escape their source root" {
    try std.testing.expect(sourcePath("src/string/profile.zig"));
    for ([_][]const u8{ "src/../secret", "/src/test", "src//x", "src/x/./y", "src/x\\y", "src/x\ny" }) |path| try std.testing.expect(!sourcePath(path));
}

test "CSV includes consistent columns and counters even for new cases" {
    var after: Samples = .{};
    try after.add(try Row.parse("ascii,10,20,128,30,2"));
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeCsvEntry(&output.writer, .{ .key = "new", .mode = "Fast", .suite = "native", .samples = .{ .{}, after } }, "new");
    try std.testing.expectEqualStrings("new,new,,20.0000,,,500.0000,,,20.0000,20.0000,,128,,30,,2\n", output.written());
}

test "ingestion refuses duplicate cases, missing earlier cases and changed fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var r: Runner = .{ .gpa = gpa, .io = undefined, .options = .{}, .output = "unused", .entries = .init(gpa) };
    try r.ingest("Fast", "native", 0, csv_header ++ "\nx,10,20,0,0,0\n", 0);
    try std.testing.expectError(error.ChangedFixture, r.ingest("Fast", "native", 1, csv_header ++ "\nx,11,20,0,0,0\n", 0));
    try std.testing.expectError(error.DuplicateCase, r.ingest("Safe", "native", 0, csv_header ++ "\nx,10,20,0,0,0\nx,10,20,0,0,0\n", 0));
    try std.testing.expectError(error.MissingCaseInEarlierRun, r.ingest("Small", "native", 0, csv_header ++ "\nx,10,20,0,0,0\n", 1));
    try std.testing.expectError(error.EmptyBenchmark, r.ingest("Fast", "native", 0, csv_header ++ "\n", 0));
}

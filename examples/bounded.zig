//! Fixed storage, cooperative work budgets, and caller-controlled cancellation.
const std = @import("std");
const dot = @import("dot_parser");

const Request = struct {
    // Single-threaded example. An ISR/thread adapter must use appropriate
    // synchronization; plain shared flags are not made safe by the parser.
    requested: bool = false,
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.requested;
    }
};

pub fn main(init: std.process.Init) !void {
    var storage: dot.FixedDocumentStorage(.{ .statements = 2, .nodes = 1, .edges = 1, .attributes = 1 }) = .{};
    var bag: dot.FixedDiagnosticBag(2) = .{};
    var session = dot.BoundedSession.init("graph {a[x=1] a--b}", storage.storage(), bag.sink(), .{});
    defer session.deinit(); // Cancels only if still unfinished; never frees caller pools.
    var calls: usize = 0;
    var work: usize = 0;
    while (true) {
        const progress = session.advance(8);
        calls += 1;
        work += progress.work_used;
        if (progress.outcome != null) break;
        // The caller can do other work here. No partial Document is published.
    }
    const parsed = session.result().?;
    if (parsed.outcome != .success) return error.ParseFailed;
    const count = parsed.document.?.statementCount();

    // Reuse pools only after all earlier document views are no longer used.
    var request: Request = .{};
    const Cancellable = dot.FixedSession(.{ .cancellation = true });
    var cancellable = Cancellable.init("graph {a[x=1] a--b}", storage.storage(), bag.sink(), .{
        .cancellation = .{ .context = &request, .is_requested = Request.poll },
    });
    defer cancellable.deinit();
    _ = cancellable.advance(8);
    request.requested = true;
    const stopped = cancellable.advance(0);
    if (stopped.outcome.? != .cancelled) return error.ExpectedCancellation;
    if (cancellable.result().?.document != null) return error.PartialDocument;

    var buffer: [256]u8 = undefined;
    var file: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try file.interface.print("bounded: {d} statements, {d} credits in {d} calls; cancellation: {s}\n", .{
        count, work, calls, @tagName(stopped.outcome.?),
    });
    try file.interface.flush();
}

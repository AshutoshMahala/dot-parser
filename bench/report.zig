//! Stable, machine-readable output for the performance runner. Timing stays
//! inside each benchmark; this module never times printing or allocates inputs.
const std = @import("std");
pub const header = "case,bytes,ns_per_value,session_bytes,credits,polls\n";

pub fn csvMode(init: std.process.Init) !bool {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 1) return false;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--csv")) return true;
    return error.InvalidBenchmarkArguments;
}

pub fn row(writer: *std.Io.Writer, id: []const u8, bytes: usize, ns: f64, session: usize, credits: u64, polls: u64) !void {
    try writer.print("{s},{d},{d:.4},{d},{d},{d}\n", .{ id, bytes, ns, session, credits, polls });
}

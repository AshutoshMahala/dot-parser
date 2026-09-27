//! Language-independent primitives shared by independently importable parsers.
//! No grammar, retained document, renderer or OS dependency.
pub const location = @import("location.zig");
pub const reporting = @import("reporting.zig");
pub const execution = @import("execution.zig");
pub const wdp = @import("wdp.zig");

test {
    _ = location;
    _ = reporting;
    _ = execution;
    _ = wdp;
}

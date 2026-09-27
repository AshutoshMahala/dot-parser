//! Language-independent primitives shared by independently importable parsers.
//! No grammar, retained document, renderer or OS dependency.
pub const location = @import("common/location.zig");
pub const reporting = @import("common/reporting.zig");
pub const execution = @import("common/execution.zig");
pub const processor = @import("common/processor.zig");
pub const stack = @import("common/stack.zig");
pub const utf8 = @import("common/utf8.zig");
pub const wdp = @import("common/wdp.zig");

test {
    _ = location;
    _ = reporting;
    _ = execution;
    _ = wdp;
    _ = processor;
    _ = stack;
    _ = utf8;
}

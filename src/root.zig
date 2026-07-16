//! Public surface of the dot-parser package.
//!
//! Everything exported here is experimental `0.x` API: usable, tested, and
//! subject to change (R-ARCH-009). Internal storage layouts
//! are not exported.

const std = @import("std");

pub const location = @import("location.zig");
pub const diagnostic = @import("diagnostic.zig");

/// Default console presentation for diagnostics — one way to render, shipped
/// out of the box. Consumers bring their own reporting by implementing
/// `DiagnosticSink`; the core never renders anything itself.
pub const console = @import("console.zig");

// Source positions.
pub const Location = location.Location;
pub const Span = location.Span;

// WDP diagnostics.
pub const wdp_namespace = diagnostic.namespace;
pub const Severity = diagnostic.Severity;
pub const Code = diagnostic.Code;
pub const Details = diagnostic.Details;
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagnosticSink = diagnostic.Sink;
pub const DiagnosticSinkError = diagnostic.SinkError;
pub const FixedDiagnosticBag = diagnostic.FixedBag;

test {
    std.testing.refAllDecls(@This());
}

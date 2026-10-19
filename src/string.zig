//! Standalone, allocation-free string-content validation. No DOT or markup imports.
pub const support = @import("parser_support");
pub const Fragment = support.processor.Fragment;
pub const Encoding = support.encoding.Encoding;
pub const ActualEncoding = support.encoding.Actual;
pub const Cancellation = support.execution.Cancellation;
pub const reporting = support.reporting;
pub const Span = support.location.Span;
pub const Profile = @import("string/profile.zig").Profile;
pub const Comparison = @import("string/policy.zig").Comparison;
pub const RuleSeverity = @import("string/policy.zig").Severity;
pub const validators = @import("string/validators.zig");
pub const Outcome = validators.Outcome;
pub const Step = validators.Step;
pub const Value = @import("string/value.zig").Value;
pub const Result = @import("string/result.zig").Result;
pub const Completion = @import("string/result.zig").Completion;
pub const Progress = @import("string/result.zig").Progress;
pub const Stage = @import("string/result.zig").Stage;
pub const Code = @import("string/diagnostic.zig").Code;
pub const Fix = @import("string/diagnostic.zig").Fix;
const Default = Profile(.{});
pub const Policy = Default.Policy;
pub const Diagnostic = Default.Diagnostic;
pub const FixedDiagnosticBag = Default.FixedDiagnosticBag;
pub const GrowableDiagnosticBag = Default.GrowableDiagnosticBag;
pub const Sink = Default.Sink;
pub const console = Default.console;
pub const parseAndValidate = Default.parseAndValidate;
pub const validatePolicy = Default.validatePolicy;
pub const Session = Default.Session;
pub const BoundedSession = Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Session;

test {
    _ = @import("string/casefold.zig");
}

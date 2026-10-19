const support = @import("parser_support");
pub const CheckState = enum { disabled, not_run, incomplete, complete, unavailable };
pub const Completion = union(enum) {
    complete,
    fail_fast,
    cancelled,
    diagnostic_stop: support.reporting.StopReason,
    invalid_validator,
};
pub const Stage = enum { encoding, equals, one_of, custom, done };
pub const Progress = struct {
    outcome: ?Completion,
    work_used: u32,
    /// Bytes classified by the encoding pass, relative to the fragment.
    source_frontier: u32,
    stage: Stage,
};
pub const Result = struct {
    completion: Completion = .complete,
    checks: struct {
        encoding: CheckState = .not_run,
        equals: CheckState = .disabled,
        one_of: CheckState = .disabled,
        custom: CheckState = .disabled,
    } = .{},
    errors: u64 = 0,
    warnings: u64 = 0,
    delivery: support.reporting.Delivery = .complete,
    /// Acceptance under the selected checks, never inferred from bag contents.
    pub fn valid(self: @This()) bool {
        if (self.completion != .complete or self.errors != 0 or self.delivery != .complete or self.checks.encoding != .complete) return false;
        inline for (.{ "equals", "one_of", "custom" }) |field| {
            const state = @field(self.checks, field);
            if (state != .complete and state != .disabled) return false;
        }
        return true;
    }
};

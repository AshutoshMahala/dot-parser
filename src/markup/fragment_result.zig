//! Independent inner results: no aggregate DOT validity or per-identifier state.
pub fn Result(comptime api: type, comptime fixed: bool) type {
    return struct {
        parse: if (fixed) api.FixedParseResult else api.ParseResult,
        /// Null after an operational stop, unsupported input, per-fragment limit,
        /// or a fail-fast syntax error. Independent validation remains available.
        /// Diagnostics and incomplete coverage offsets use original coordinates;
        /// retained document records still index document.source (fragment-local).
        validation: ?api.ValidationResult,
        /// Error classification under the child's policy, independent of sink
        /// filtering. False is NOT proof of validity/completeness.
        has_errors: bool,

        pub fn documentValid(self: *const @This()) bool {
            const checked = self.validation orelse return false;
            return self.parse.outcome == .success and self.parse.completion == .complete and
                checked.completion == .complete and checked.validity == .valid;
        }

        /// Operational stop shared with the caller. Content rejection, local
        /// policy limits and the child's own fail-fast stop do not end a batch.
        pub fn stopped(self: *const @This()) bool {
            if (self.parse.diagnostic_stop != null or self.parse.diagnostic_delivery == .failed) return true;
            switch (self.parse.outcome) {
                .success, .invalid_syntax, .unsupported_feature, .resource_limit => {},
                else => return true,
            }
            const checked = self.validation orelse return false;
            return switch (checked.completion) {
                .complete, .incomplete, .error_stopped, .source_limit => false,
                else => true,
            };
        }

        /// Call after the child returns. Parent fail-fast treats the entire
        /// child operation as one encounter, preserving all its findings.
        pub fn shouldStop(self: *const @This(), parent_on_error: api.OnError) bool {
            return self.stopped() or (parent_on_error == .fail_fast and self.has_errors);
        }

        pub fn deinit(self: *@This()) void {
            if (!fixed) self.parse.deinit();
        }
    };
}

//! Independent inner results: no aggregate DOT validity or per-identifier state.
pub fn Result(comptime api: type, comptime fixed: bool) type {
    return struct {
        parse: if (fixed) api.FixedParseResult else api.ParseResult,
        /// Null only when parsing stopped operationally or was unsupported.
        /// Diagnostics and incomplete coverage offsets use original coordinates;
        /// retained document records still index document.source (fragment-local).
        validation: ?api.ValidationResult,

        pub fn documentValid(self: *const @This()) bool {
            const checked = self.validation orelse return false;
            return self.parse.outcome == .success and self.parse.completion == .complete and
                checked.completion == .complete and checked.validity == .valid;
        }

        /// A caller driving several fragments must stop its requested batch on
        /// true. Ordinary syntax/validation findings alone return false.
        pub fn stopped(self: *const @This()) bool {
            switch (self.parse.outcome) {
                .success, .invalid_syntax => {},
                else => return true,
            }
            const checked = self.validation orelse return true;
            return switch (checked.completion) {
                .complete, .incomplete => false,
                else => true,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (!fixed) self.parse.deinit();
        }
    };
}

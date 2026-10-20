const support = @import("parser_support");
const wdp = support.wdp;
pub const namespace = "string_processor";
pub const namespace_hash = wdp.computeNamespaceHash(namespace);
pub const Component = enum {
    validation,
    pub fn name(_: @This()) []const u8 {
        return "Validation";
    }
};
pub const Primary = enum {
    encoding,
    equality,
    membership,
    custom,
    pub fn name(self: @This()) []const u8 {
        return switch (self) {
            .encoding => "Encoding",
            .equality => "Equality",
            .membership => "Membership",
            .custom => "Custom",
        };
    }
};
const Catalog = wdp.Catalog(Component, Primary);
pub const Code = enum {
    invalid_encoding,
    unequal,
    unequal_warning,
    not_one_of,
    not_one_of_warning,
    custom_check_failed,
    custom_check_warning,
    pub fn info(self: @This()) Catalog.Info {
        const definition: Catalog.Definition = .{
            .severity = switch (self) {
                .unequal_warning, .not_one_of_warning, .custom_check_warning => .warning,
                else => .err,
            },
            .component = .validation,
            .primary = switch (self) {
                .invalid_encoding => .encoding,
                .unequal, .unequal_warning => .equality,
                .not_one_of, .not_one_of_warning => .membership,
                .custom_check_failed, .custom_check_warning => .custom,
            },
            .sequence = wdp.Sequence.invalid,
            .summary = switch (self) {
                .invalid_encoding => "invalid string encoding",
                .unequal, .unequal_warning => "string does not equal the expected value",
                .not_one_of, .not_one_of_warning => "string is not one of the allowed values",
                .custom_check_failed, .custom_check_warning => "string does not satisfy the custom check",
            },
            .hint = switch (self) {
                .invalid_encoding => "supply well-formed contents in the selected encoding",
                .unequal, .unequal_warning => "use the expected string value",
                .not_one_of, .not_one_of_warning => "choose a value from the configured set",
                .custom_check_failed, .custom_check_warning => "satisfy the configured validator's requirements",
            },
        };
        return definition.info();
    }
    const Identity = wdp.Registry(@This(), namespace);
    pub const severity = Identity.severity;
    pub const structured = Identity.structured;
    pub const compactId = Identity.compactId;
    pub const qualifiedCompactId = Identity.qualifiedCompactId;
};
comptime {
    wdp.Registry(Code, namespace).validate();
}

/// Replacement text is borrowed UTF-8, like the other processors' fix text.
/// Applying to a native-encoded source requires encoding it for that source.
/// Rendering is only a description; applying an edit is a consumer action.
pub const Replacement = struct {
    bytes: []const u8,
    pub fn text(self: @This()) []const u8 {
        return self.bytes;
    }
};
pub const Fix = support.reporting.Fix(Replacement);
pub fn For(comptime Custom: type) type {
    return struct {
        pub const Detail = if (@hasDecl(Custom, "Detail")) Custom.Detail else void;
        pub const Diagnostic = struct {
            code: Code,
            span: support.location.Span,
            related: ?support.location.Span = null,
            detail: ?Detail = null,
            fix: ?Fix = null,
        };
        /// Local spans are checked/rebased once; at/related_at are already in
        /// original-source coordinates. Bound readers require the latter and
        /// reject raw edits until host-aware fix materialization is available.
        pub const Finding = struct {
            /// Original-source locations from value.location()/readStep().
            /// Do not combine these with their local-coordinate counterparts.
            at: ?support.logical.SourceLocation = null,
            related_at: ?support.logical.SourceLocation = null,
            span: ?support.location.Span = null,
            related: ?support.location.Span = null,
            detail: ?Detail = null,
            fix: ?Fix = null,
        };
        pub const Sink = support.reporting.Sink(Diagnostic);
        pub const GrowableBag = support.reporting.GrowableBag(Diagnostic);
        pub fn FixedBag(comptime capacity: usize) type {
            return support.reporting.FixedBag(Diagnostic, capacity, .stop);
        }
    };
}

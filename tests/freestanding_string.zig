const strings = @import("string_processor");
const features = @import("string_features");
const predicate = @hasDecl(features, "predicate") and features.predicate;
const Nonempty = strings.validators.Predicate(void, {}, struct {
    fn check(value: anytype, _: void) bool {
        return value.bytes.len != 0;
    }
}.check);
const Checker = strings.Profile(.{
    .unicode_case_folding = features.folding,
    .custom = if (predicate) Nonempty else strings.validators.None,
    .policy = .{
        .comparison = if (features.folding and !predicate) .case_insensitive else .case_sensitive,
        .validation = .{ .equals = .{ .expected = "Seattle", .severity = if (predicate) .off else .err }, .custom = if (predicate) .err else .off },
    },
});

export fn check_value(source: [*]const u8, length: u32) u32 {
    const result = Checker.parseAndValidate(.{ .bytes = source[0..length], .origin = 0 }, Checker.Sink.discard, .{}) catch return 2;
    return if (result.valid()) 0 else 1;
}

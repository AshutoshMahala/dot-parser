const std = @import("std");
const m = @import("markup_parser");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

test "Graphviz complete labels accept documented content, references and values" {
    const valid = [_][]const u8{
        "hello &nbsp; &copy; &alpha; &euro; &apos;",
        "<b>bold</B><BR/><I>italic</I><SUB>2</SUB><SUP>3</SUP><S>x</S><O>y</O>",
        "<BR></BR>",
        "<TABLE CELLSPACING='-128' STYLE='rounded,\tradial'><TR><TD/></TR><HR> \t\n</HR><TR><TD/><VR> </VR><TD/></TR></TABLE>",
        " <!-- before --> <TABLE><TR><TD/></TR></TABLE> ",
        "<FONT FACE='sans' POINT-SIZE='24.0'><TABLE BORDER='255' CELLBORDER='127' CELLPADDING='255' CELLSPACING='127' ROWS='*' COLUMNS='*' STYLE='rounded, radial'><TR><TD ALIGN='TEXT' BALIGN='left' VALIGN='top' ROWSPAN='65535' COLSPAN='1' SIDES='ltRB'>a</TD><VR/><TD/></TR><HR/><TR><TD/></TR></TABLE></FONT>",
        "<TABLE WIDTH='10' HEIGHT='20' FIXEDSIZE='true'><TR><TD><IMG SRC='not-opened.png' SCALE='both'/></TD></TR></TABLE>",
        "<TABLE><TR><TD><TABLE><TR><TD>x</TD></TR></TABLE></TD></TR></TABLE>",
        "<B> <TABLE><TR><TD>x</TD></TR></TABLE> </B>",
        "&#32;<TABLE><TR><TD/></TR></TABLE>&#x20;",
        "<BR ALIGN='&#76;EFT'/>",
        "<FONT POINT-SIZE='1.25e2'>x</FONT>",
        "<FONT POINT-SIZE='2.55e2'>x</FONT><FONT POINT-SIZE=' -0.0 '>x</FONT>",
        "<FONT POINT-SIZE='000000000000000000000000000000000000000000000001'>x</FONT>",
    };
    inline for (.{ m.ScannerBackend.scalar, .block }) |backend| {
        const P = m.Profile(.{ .policy = .{ .scanner = backend } });
        for (valid) |source| {
            errdefer std.debug.print("valid label rejected: {s}\n", .{source});
            var bag: m.FixedDiagnosticBag(16) = .{};
            var result = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, bag.sink(), .{});
            defer result.deinit();
            try expect(result.documentValid());
            try equal(@as(usize, 0), bag.items().len);
            try equal(.complete, result.validation.?.checks.graphviz_content);
            try equal(.complete, result.validation.?.checks.graphviz_values);
            try equal(.complete, result.validation.?.checks.references);
        }
    }
}

test "accepted malformed references are literal text not Graphviz coverage gaps" {
    const P = m.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .accept } } });
    const source = "<TABLE><TR><TD>&a#b; &#X20; &#5; &amp</TD></TR></TABLE>";
    var result = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, P.DiagnosticSink.discard, .{});
    defer result.deinit();
    try expect(result.documentValid());
    try equal(.complete, result.validation.?.checks.graphviz_content);
}

test "Graphviz attribute reference catalog has document source and runtime parity" {
    const source = "<TABLE TOOLTIP='&nbsp;'><TR><TD>&nbsp;</TD></TR></TABLE>";
    const P = m.Profile(.{ .runtime_policy = true });
    var result = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, P.DiagnosticSink.discard, .{});
    defer result.deinit();
    try equal(@as(u64, 1), result.validation.?.errors);
    const local = try P.validateSource(std.testing.allocator, source, P.DiagnosticSink.discard, .{});
    try equal(@as(u64, 1), local.errors);
    const override = try P.validate(std.testing.allocator, &result.parse.document.?, P.DiagnosticSink.discard, .{ .policy = .{ .validation = .{ .references = .{ .severity = .err, .catalog = .graphviz } } } });
    try equal(@as(u64, 0), override.errors);
}

test "Graphviz content and value rejections stay independent of syntax acceptance" {
    const invalid = [_][]const u8{
        "<FONT POINT-SIZE='255.000000000000000000000000000001'>x</FONT>",
        "",
        "<B/>",
        "<TABLE/>",
        "<TABLE><TD>x</TD></TABLE>",
        "<TABLE><TR/></TABLE>",
        "<TD>x</TD>",
        "<HR/>",
        "<IMG SRC='x'/>",
        "<BR>x</BR>",
        "x<TABLE><TR><TD/></TR></TABLE>",
        "<TABLE><TR><TD/></TR><HR/></TABLE>",
        "<TABLE><HR/><TR><TD/></TR></TABLE>",
        "<TABLE><TR><TD/><VR/><VR/><TD/></TR></TABLE>",
        " <B><TABLE><TR><TD/></TR></TABLE></B>",
        "<FONT><B><TABLE><TR><TD/></TR></TABLE></B></FONT>",
        "<SUB><TABLE><TR><TD/></TR></TABLE></SUB>",
        "<TABLE><TR><TD> <IMG SRC='x'/></TD></TR></TABLE>",
        "<TABLE><TR><TD><IMG/></TD></TR></TABLE>",
        "<BR ALIGN='TEXT'/>",
        "<FONT POINT-SIZE='nan'>x</FONT>",
        "<FONT POINT-SIZE='1e999999'>x</FONT>",
        "<FONT POINT-SIZE='-2'>x</FONT>",
        "<TABLE BORDER='256'><TR><TD/></TR></TABLE>",
        "<TABLE CELLBORDER='128'><TR><TD/></TR></TABLE>",
        "<TABLE CELLSPACING='-129'><TR><TD/></TR></TABLE>",
        "<TABLE CELLSPACING='128'><TR><TD/></TR></TABLE>",
        "<TABLE CELLBORDER='-1'><TR><TD/></TR></TABLE>",
        "<TABLE STYLE='rounded,&#9;radial'><TR><TD/></TR></TABLE>",
        "<TABLE TOOLTIP='&nbsp;'><TR><TD/></TR></TABLE>",
        "<TABLE ROWS='1'><TR><TD/></TR></TABLE>",
        "<TABLE FIXEDSIZE='TRUE'><TR><TD/></TR></TABLE>",
        "<TABLE STYLE='dotted'><TR><TD/></TR></TABLE>",
        "<TABLE><TR><TD COLSPAN='0'/></TR></TABLE>",
        "<TABLE><TR><TD STYLE='rounded'/></TR></TABLE>",
        "<TABLE><TR><TD SIDES='X'/></TR></TABLE>",
        "&notAnEntity;",
        "&NBSP;",
    };
    for (invalid) |source| {
        errdefer std.debug.print("invalid label accepted: {s}\n", .{source});
        var result = try m.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, m.diagnostic.discard, .{});
        defer result.deinit();
        try equal(m.Outcome.success, result.parse.outcome);
        try expect(!result.documentValid());
        try expect(result.validation.?.errors != 0);
    }
}

test "Graphviz value checks have local source and runtime parity without duplicate scratch" {
    const Runtime = m.Profile(.{ .runtime_policy = true });
    const source = "<TABLE BORDER='256' FIXEDSIZE='TRUE'><TR><TD><IMG SCALE='huge'/></TD></TR></TABLE>";
    inline for (.{ m.RuleSeverity.err, .warning, .off }) |severity| {
        const p: m.Policy = .{ .validation = .{ .duplicate_attribute = .off, .graphviz = .{ .invalid_content = .off, .invalid_value = severity } } };
        const P = m.Profile(.{ .policy = p });
        var bag: m.FixedDiagnosticBag(16) = .{};
        var result = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, bag.sink(), .{});
        defer result.deinit();
        try equal(result.validation.?, P.validateSourceIn(source, .{}, m.diagnostic.discard, .{}));
        try equal(result.validation.?, Runtime.validate(std.testing.allocator, &result.parse.document.?, m.diagnostic.discard, .{ .policy = p }));
        try equal(@as(u64, if (severity == .err) 4 else 0), result.validation.?.errors);
        try equal(@as(u64, if (severity == .warning) 4 else 0), result.validation.?.warnings);
        try equal(severity != .err, result.documentValid());
    }
}

test "Graphviz content coverage and local-only scopes do not manufacture completeness" {
    const P = m.Profile(.{ .runtime_policy = true, .policy = .{ .retention = .{ .partial = true }, .validation = .{ .graphviz = .{ .unknown_element = .off } } } });
    var unknown = try P.parseAndValidate(std.testing.allocator, .{ .bytes = "<custom><BR/></custom>", .origin = 0 }, m.diagnostic.discard, .{});
    defer unknown.deinit();
    try equal(.incomplete, unknown.validation.?.checks.graphviz_content);
    try expect(!unknown.documentValid());
    const local = try P.validateSourceIn("<TABLE/>", .{}, m.diagnostic.discard, .{});
    try equal(.not_run, local.checks.graphviz_content);
    try equal(.valid, local.validity); // Local facts only, not a complete label.
    var partial = try P.parseAndValidate(std.testing.allocator, .{ .bytes = "<TABLE><TR><TD>", .origin = 0 }, m.diagnostic.discard, .{});
    defer partial.deinit();
    const checked = try P.validate(std.testing.allocator, &partial.parse.document.?, m.diagnostic.discard, .{});
    try equal(.incomplete, checked.checks.graphviz_content);
    try equal(@as(u64, 0), checked.errors); // No invented missing-child cascade.
}

test "Graphviz content fail-fast, sink capacity and warning override" {
    const P = m.Profile(.{ .runtime_policy = true });
    const source = "<TD/><TD/>";
    var fail = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, m.diagnostic.discard, .{ .policy = .{ .on_error = .fail_fast } });
    defer fail.deinit();
    try equal(.error_stopped, fail.validation.?.completion);
    try equal(@as(u64, 1), fail.validation.?.errors);
    var bag: m.FixedDiagnosticBag(0) = .{};
    var stopped = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, bag.sink(), .{});
    defer stopped.deinit();
    try expect(stopped.validation.?.completion == .diagnostic_stopped);
    var warned = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, m.diagnostic.discard, .{ .policy = .{ .validation = .{ .graphviz = .{ .invalid_content = .warning } } } });
    defer warned.deinit();
    try expect(warned.documentValid());
    try equal(@as(u64, 2), warned.validation.?.warnings);
}

test "Graphviz label values and references preserve native encoding spans" {
    const P = m.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |encoding| {
        const wide = encoding == .utf32le or encoding == .utf32be;
        const little = encoding == .utf16le or encoding == .utf32le;
        const Unit = if (wide) u32 else u16;
        const width = @sizeOf(Unit);
        const source = "<BR ALIGN='wrong'/>";
        var bytes: [(source.len + 1) * width]u8 = undefined;
        std.mem.writeInt(Unit, bytes[0..width], 0xfeff, if (little) .little else .big);
        for (source, 1..) |byte, i| std.mem.writeInt(Unit, bytes[i * width ..][0..width], byte, if (little) .little else .big);
        var bag: m.FixedDiagnosticBag(4) = .{};
        var result = try P.parseAndValidate(std.testing.allocator, .{ .bytes = &bytes, .origin = 20 }, bag.sink(), .{});
        defer result.deinit();
        try equal(m.Outcome.success, result.parse.outcome);
        try expect(!result.documentValid());
        try equal(@as(usize, 1), bag.items().len);
        try equal(m.diagnostic.Code.invalid_value, bag.items()[0].code);
        try equal(@as(u32, 20 + 11 * width), bag.items()[0].span.start);
        try equal(@as(u32, 7 * width), bag.items()[0].span.len);
    }
}

test "Graphviz coverage gaps do not taint independent checks or duplicate value errors" {
    const source = "<BR bad='x'/>";
    var result = try m.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, m.diagnostic.discard, .{});
    defer result.deinit();
    try equal(.complete, result.validation.?.checks.graphviz_attributes);
    try equal(.incomplete, result.validation.?.checks.graphviz_values);
    try equal(.complete, result.validation.?.checks.graphviz_content);
    const local = m.validateSource(std.testing.allocator, source, m.diagnostic.discard, .{});
    try equal(.complete, local.checks.graphviz_attributes);
    try equal(.incomplete, local.checks.graphviz_values);
    var bad_width = try m.parseAndValidate(std.testing.allocator, .{ .bytes = "<TABLE FIXEDSIZE='TRUE' WIDTH='bad' HEIGHT='10'><TR><TD/></TR></TABLE>", .origin = 0 }, m.diagnostic.discard, .{});
    defer bad_width.deinit();
    try equal(@as(u64, 1), bad_width.validation.?.errors);
}

test "Graphviz value scans stop at cancellation and malformed-reference acceptance stays literal" {
    const source = "<TABLE BORDER='" ++ &@as([4096]u8, @splat('0')) ++ "'><TR><TD/></TR></TABLE>";
    var parsed = m.parseBorrowed(std.testing.allocator, source, m.diagnostic.discard, .{});
    defer parsed.deinit();
    const Probe = struct {
        calls: u32 = 0,
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls == 5;
        }
    };
    const P = m.Profile(.{ .policy = .{ .execution = .{ .cancellation = true } } });
    var probe: Probe = .{};
    const checked = P.validateIn(&parsed.document.?, .{}, m.diagnostic.discard, .{ .cancellation = .{ .context = &probe, .is_requested = Probe.poll } });
    try equal(.cancelled, checked.completion);
    try equal(@as(u32, 5), probe.calls);
    const Tolerant = m.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .accept } } });
    var result = try Tolerant.parseAndValidate(std.testing.allocator, .{ .bytes = "fish & chips &#0;", .origin = 0 }, m.diagnostic.discard, .{});
    defer result.deinit();
    try expect(result.documentValid());
}

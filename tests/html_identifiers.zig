//! DOT envelope recognition only; none of these operations invoke markup.
const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;

test "passthrough is the default and all ID positions preserve their spelling" {
    const source = "digraph <G> { subgraph <S> { <a>:<p>:<n> -> <b> [<k>=<<B>x</B>>]; } <x>=<y>; node [<z>=<>]; }";
    inline for (.{ .scalar, .block }) |backend| {
        const P = dot.Profile(.{ .policy = .{ .scanner = backend } });
        var bag: dot.FixedDiagnosticBag(8) = .{};
        var result = P.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
        defer result.deinit(std.testing.allocator);
        try expect(result.documentValid());
        try equal(@as(usize, 0), bag.items().len);
        const doc = &result.document.?;
        try strings("<G>", doc.text(doc.name.?));
        try strings("<k>", doc.text(doc.attributes[0].key));
        try strings("<<B>x</B>>", doc.text(doc.attributes[0].value));
        var storage: dot.FixedDocumentStorage(.{ .statements = 8, .subgraphs = 2, .edges = 2, .nodes = 2, .ported_references = 2, .attributes = 4, .assignments = 2, .attribute_statements = 2 }) = .{};
        var scratch: dot.FixedParseScratch(.{ .nesting = 2 }) = .{};
        const fixed = P.parseBorrowedIn(source, .{ .document = storage.storage(), .scratch = scratch.storage() }, bag.sink(), .{});
        try equal(.success, fixed.outcome);
        try std.testing.expectEqualSlices(dot.Attribute, doc.attributes, fixed.document.?.attributes);
    }
}

test "none rejects whole mixed expressions at either binding time" {
    inline for (.{ .scalar, .block }) |backend| {
        const Fixed = dot.Profile(.{ .policy = .{ .scanner = backend, .markup = .none } });
        const Dynamic = dot.Profile(.{ .runtime_policy = true, .policy = .{ .scanner = backend, .markup = .none } });
        inline for (.{ "<x>", "\"x\" + /*glue*/ <y>", "<x>+\"y\"", "<>+<>" }) |raw| {
            const source = "graph { " ++ raw ++ "; }";
            var a: dot.FixedDiagnosticBag(4) = .{};
            var b: dot.FixedDiagnosticBag(4) = .{};
            var fixed = Fixed.parseBorrowed(std.testing.allocator, source, a.sink(), .{});
            defer fixed.deinit(std.testing.allocator);
            var dynamic = try Dynamic.parseBorrowed(std.testing.allocator, source, b.sink(), .{});
            defer dynamic.deinit(std.testing.allocator);
            try equal(.unsupported_feature, fixed.outcome);
            try equal(.unsupported_feature, dynamic.outcome);
            try std.testing.expectEqualSlices(dot.Diagnostic, a.items(), b.items());
            try strings(raw, a.items()[0].span.slice(source));
            var enabled = try Dynamic.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{ .policy = .{ .markup = .passthrough } });
            defer enabled.deinit(std.testing.allocator);
            try equal(.success, enabled.outcome);
        }
    }
}

test "none recovery continues through statements without publishing partial syntax" {
    inline for (.{ .scalar, .block }) |backend| {
        const P = dot.Profile(.{ .policy = .{ .scanner = backend, .markup = .none, .recovery = .statements } });
        const source = "graph { <a> -- { <skipped> }; b -- ; <c>; }";
        var bag: dot.FixedDiagnosticBag(8) = .{};
        var result = P.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
        defer result.deinit(std.testing.allocator);
        try equal(.invalid_syntax, result.outcome);
        try expect(result.document == null);
        try equal(@as(usize, 3), bag.items().len);
        try strings("<a>", bag.items()[0].span.slice(source));
        try equal(dot.Code.syntax_unexpected_token, bag.items()[1].code);
        try strings("<c>", bag.items()[2].span.slice(source));
    }
}

test "unterminated envelopes offer only a depth-one maybe fix" {
    inline for (.{ .scalar, .block }) |backend| {
        const P = dot.Profile(.{ .policy = .{ .scanner = backend } });
        inline for (.{ "graph { <a", "graph { <<a", "graph { \"x\" + <a" }) |source| {
            var bag: dot.FixedDiagnosticBag(4) = .{};
            var result = P.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
            defer result.deinit(std.testing.allocator);
            try equal(.invalid_syntax, result.outcome);
            const d = bag.items()[0];
            try equal(dot.diagnostic.UnterminatedConstruct.html_identifier, d.details.unterminated);
            try strings("<", d.span.slice(source));
            if (std.mem.indexOf(u8, source, "<<") != null) {
                try expect(d.fix == null);
            } else {
                try equal(dot.diagnostic.Applicability.maybe, d.fix.?.applicability);
                try equal(dot.diagnostic.Replacement.html_close, d.fix.?.edit.insert_before);
                try equal(source.len, d.fix.?.span.start);
                try equal(@as(u32, 0), d.fix.?.span.len);
            }
        }
    }
}

test "fix policy filters parse and validation offers without changing validity" {
    inline for (.{ dot.Fixes.all, .machine_applicable, .off }) |fixes| {
        const Fixed = dot.Profile(.{ .policy = .{ .diagnostics = .{ .fixes = fixes } } });
        const Dynamic = dot.Profile(.{ .runtime_policy = true });
        inline for (.{
            .{ "graph { a -- <x", false }, // scanner maybe
            .{ "graph { \"x", false }, // parser maybe
            .{ "graph { a --> b }", true }, // scanner machine applicable
            .{ "graph { a -- node }", true }, // grammar machine applicable
            .{ "graph { a -> b }", false }, // validator
        }) |case| {
            var a: dot.FixedDiagnosticBag(4) = .{};
            var b: dot.FixedDiagnosticBag(4) = .{};
            var fixed = Fixed.parseAndValidate(std.testing.allocator, case[0], a.sink(), .{});
            defer fixed.deinit(std.testing.allocator);
            var dynamic = try Dynamic.parseAndValidate(std.testing.allocator, case[0], b.sink(), .{ .policy = .{ .diagnostics = .{ .fixes = fixes } } });
            defer dynamic.deinit(std.testing.allocator);
            try expect(!fixed.documentValid() and !dynamic.documentValid());
            try std.testing.expectEqualSlices(dot.Diagnostic, a.items(), b.items());
            try equal(fixes == .all or (fixes == .machine_applicable and case[1]), a.items()[0].fix != null);
        }
    }
}

test "identifier forms and decoding preserve HTML bytes and join only on request" {
    const cases = .{
        .{ "abc", dot.identifier.Form.bare, "abc" },
        .{ "-.5", dot.identifier.Form.numeral, "-.5" },
        .{ "\"abc\"", dot.identifier.Form.quoted, "abc" },
        .{ "<>", dot.identifier.Form.html, "" },
        .{ "<<b> &amp; \\n\x00\xff </b>>", dot.identifier.Form.html, "<b> &amp; \\n\x00\xff </b>" },
        .{ "\"a\"/**/+<>+<b>+\"c\"", dot.identifier.Form.concatenation, "abc" },
        .{ "<a> + #glue\n \"b\"", dot.identifier.Form.concatenation, "ab" },
        .{ "<>+<>+\"\"", dot.identifier.Form.concatenation, "" },
    };
    inline for (cases) |case| {
        try equal(case[1], try dot.identifier.form(case[0]));
        var output: [128]u8 = undefined;
        try equal(case[2].len, try dot.identifier.decodedLen(case[0]));
        try strings(case[2], try dot.identifier.decodeInto(case[0], &output));
        var writer = std.Io.Writer.fixed(&output);
        try dot.identifier.writeDecoded(case[0], &writer);
        try strings(case[2], writer.buffered());
    }
    inline for (.{ "<", "<<>", "<a>+b", "<a>+", "<a> ", " <a>", "<a>>", "graph", "" }) |raw| {
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.form(raw));
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.decodedLen(raw));
    }
}

test "duplicate keys use decoded HTML operands including empty parts" {
    const P = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .err } } });
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var keys: [3]dot.AttributeKeyScratch = undefined;
    var result = P.parseAndValidate(std.testing.allocator, "graph { a [x=1 <>+<x>=2 \"\"+<x>=3] }", bag.sink(), .{ .validation = .{ .attribute_keys = &keys } });
    defer result.deinit(std.testing.allocator);
    try equal(.success, result.outcome);
    try expect(!result.documentValid());
    try equal(@as(usize, 2), bag.items().len);
}

test "bounded sessions preserve HTML continuation and reset runtime patches" {
    const source = "graph { \"x\" + <<b>" ++ "x" ** 150 ++ "</b>>; }";
    inline for (.{ .scalar, .block }) |backend| {
        const P = dot.Profile(.{ .runtime_policy = true, .policy = .{ .scanner = backend, .execution = .{ .metering = true } } });
        var storage: dot.FixedDocumentStorage(.{ .statements = 2, .nodes = 2 }) = .{};
        var bag: dot.FixedDiagnosticBag(4) = .{};
        var session = try P.Session.init(source, .{ .document = storage.storage() }, bag.sink(), .{ .policy = .{ .markup = .none } });
        defer session.deinit();
        while ((try session.advance(1)).outcome == null) {}
        try equal(.unsupported_feature, session.result().?.outcome);
        try session.reset(source, dot.diagnostic.discard, .{});
        var work: usize = 0;
        while (true) {
            const progress = try session.advance(1);
            try expect(progress.work_used <= 1);
            try expect(progress.source_frontier <= source.len);
            work += progress.work_used;
            try expect(work < source.len * 8);
            if (progress.outcome != null) break;
        }
        try equal(.success, session.result().?.outcome);
        try equal(@as(usize, 1), session.result().?.document.?.nodes.len);
    }
}

test "stopping diagnostic destinations abort none-policy recovery promptly" {
    const P = dot.Profile(.{ .policy = .{ .markup = .none, .recovery = .statements } });
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var result = P.parseBorrowed(std.testing.allocator, "graph { <a>; <b>; }", bag.sink(), .{});
    defer result.deinit(std.testing.allocator);
    try expect(result.outcome == .diagnostic_stopped);
    try expect(result.document == null);
    try equal(@as(usize, 1), bag.items().len);
}

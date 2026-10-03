# Standalone structural markup

Current development implementation, after 0.3.0: import `markup_parser` without
importing `dot_parser`. This is an experimental XML-like **fragment** parser,
not browser HTML, complete XML, or Graphviz label validation. DOT independently
supports [passthrough HTML-like identifiers](SUPPORTED_SYNTAX.md#passthrough-html-like-identifiers),
but does not yet invoke this parser automatically.

## Delayed processing inside DOT

Import both modules and select preserved identifiers explicitly. Ordinary DOT
calls do not invoke markup. See the runnable
[delayed markup example](../examples/delayed_markup.zig).

```zig
const Reader = markup.Profile(.{ .policy = markup.presets.untrusted });
const ready = Reader.prepare(.{}); // once, reusable across selected operands
const parent_on_error: markup.OnError = .collect;
var parts = try dot.identifier.parts(dot_document.source, attribute.value);
while (parts.next()) |part| {
    if (part.form != .html) continue;
    var checked = try ready.parseAndValidateFragment(
        allocator, try part.fragment(dot_document.source), bag.sink(), .{},
    );
    defer checked.deinit();
    // Consume checked.parse.document here if present; it borrows source bytes.
    if (checked.shouldStop(parent_on_error)) break; // also end surrounding loops
}
```

Selection is application-owned: any DOT identifier position can be selected, not
just `label`. `identifier.parts(source, range)` checks one complete expression,
then returns a borrowed iterator of `Part { form, raw, inner }`. Forms are `bare`,
`numeral`, `quoted`, `html`; spans use original-source bytes. `inner` removes
exactly one surrounding quote/angle pair, without decoding or joining operands.
Thus `<<b/>> + <text>` supplies separate `<b/>` and `text` fragments. Empty
operands remain present; quoted `<...>` text is not automatically markup.
Invalid metadata/expression returns `InvalidSpan`/`InvalidIdentifier` before
iteration. Source must remain alive and unchanged while using views.

| API/result | Behavior |
| --- | --- |
| `Reader.prepare(options)` | No allocation/scan/callbacks; resolve once into reusable `Prepared` |
| `ready.parseAndValidateFragment(allocator, fragment, sink, resources)` | Explicit allocation; optional `resources.scratch_allocator` for parsing scratch |
| `ready.parseAndValidateFragmentIn(fragment, memory, scratch, sink)` | Allocation-free; `ParseMemory` and `SourceValidationScratch`; key scratch reused for document validation |
| `checked.parse` | Ordinary parse result; no partial tree on syntax failure |
| `checked.validation` | Document validation on success; source-scope validation on `invalid_syntax` only with child `.on_error = .collect`; null after fail-fast syntax rejection, unsupported input or operational stops |
| `checked.documentValid()` | Successful complete parsing AND complete valid validation |
| `checked.has_errors` | Discovered syntax/validation errors, a child policy-limit failure, or unsupported input classified as error; false does not imply validity/completeness |
| `checked.stopped()` | Operational stop: cancellation, storage/allocation/delivery failure or explicit sink stop; not ordinary errors, unsupported input or child policy limits |
| `checked.shouldStop(parent_on_error)` | Operational stop, or child errors when the parent's policy is `.fail_fast` |

Both operations also exist directly on `markup` and configured profiles, taking
their normal policy options last. Growing results require `deinit()`; fixed
results own neither source nor pools. Validation failure preserves a successful
inner tree. Outer and inner validity remain independent. Do not start child work
after an outer operational stop or an outer fail-fast error.

The parent checks its policy **after the child returns**; it never overrides the
child's error handling. There is no runtime processor replacement.

| Parent `on_error` | Child `on_error` | Behavior after a child error |
| --- | --- | --- |
| `collect` | `fail_fast` | Child ends at its first error; visit the next child |
| `collect` | `collect` | Child collects safely; visit the next child |
| `fail_fast` | `fail_fast` | Child ends at its first error; no next child |
| `fail_fast` | `collect` | Child finishes collecting; retain all findings, then no next child |

Unsupported reporting follows the child's `diagnostics.unsupported` policy:
`err` (default), `warning`, or `silent`. It never creates a successful document
or certifies unprocessed content. Warning/silence alone do not trigger parent
fail-fast. An unsupported boundary can still prevent that child from proceeding.
A child policy limit remains an enforced failure; parent `.collect` may process
other fragments. Shared sink stops, allocation/storage failure and cancellation
end the batch regardless of either `on_error` setting.

`Fragment.init(bytes, origin)` checks the u32 coordinate domain;
`Fragment.fromSource(source, span)` additionally checks source bounds before
slicing. `fragment.child(local_span)` composes origins for another raw nested
input, such as a markup attribute value passed to a consumer string processor.
Decoded/concatenated/transcoded input requires a different source map.

All emitted primary/related/fix spans and validation `incomplete` offsets map to
the original file. Resource capacities/limits are counts and are not rebased.
**Tree spans stay local to the retained markup `document.source`.** Render mapped
diagnostics against the original DOT source. Custom parse-only, validation-only
or bounded-session workflows can use `markup.diagnostic.OriginSink.init(fragment,
destination)`; keep this adapter at a stable address while its `.sink()` is used.
Do not wrap already mapped fragment operations in another origin adapter.

Costs: operand selection validates then traverses the selected expression (two
linear scans, no allocation), not the entire DOT file. Selected markup is parsed
and validated; rejected syntax can require a source-scope rescan. Mapping adds
constant bounds checks per diagnostic, not per byte/node. No per-identifier fields
or mandatory child-result array are added. These operations are run-to-completion;
parse metering does not bound validation, enumeration, sorting or callbacks.

Delivery order is syntax findings, validation findings, then the next selected
operand. No global source sorting or universal diagnostic union is added.
During-DOT scheduling, a shared resumable budget, Graphviz vocabulary validation
and a built-in string processor remain unimplemented. See
[nested policies](POLICIES.md#composing-processor-policies) for consumer schemas.

## Supported input

| Input | Behavior |
| --- | --- |
| Empty input, plain text, multiple root elements | Supported |
| `<a>text<b/></a>` | Supported; exact case-sensitive closing names |
| `<a></a>` and `<a/>` | Both supported; raw spelling preserved |
| Non-ASCII names/text, including invalid UTF-8 bytes | Preserved; optional independent UTF-8 check, off by default |
| Quoted attributes: `<a x='1' y="2"/>` | Preserved in source order, including duplicates |
| Duplicate attribute names on one element | Parsing retains all; independent validation defaults to error |
| Named, decimal and hexadecimal references | Syntax checked and spelling preserved; optional independent named-reference catalog check, no expansion |
| `<!--comment-->`, `<![CDATA[text]]>` | Retained as distinct leaf nodes, including empty bodies |
| Processing instructions, declarations | Unsupported |
| Unclosed, mismatched or unexpected closing tags | Invalid syntax; structural recovery collects further findings by default, never publishes a partial document |
| Leading UTF-16/32 byte-order markers | Unsupported encoding; no automatic conversion |

Names start with `[A-Za-z_:]` or a byte `0x80..0xFF`; subsequent bytes may also
include digits, `-`, and `.`. There is no namespace interpretation. Whitespace in
text stays intact. Space/tab/CR/LF are allowed around tag endings, but not between
`/` and `>` in a self-closing tag. Control bytes below `0x20` other than tab/CR/LF
are invalid. Ordinary text ends at `<`; references remain in the same text run. No XML-conformance claim is made
for its other character-data restrictions. A leading UTF-8 BOM is skipped as
content without changing physical offsets. UTF-16/32 must be converted explicitly;
offsets then refer to the converted buffer. BOM detection does not identify every
wrong or mixed encoding.

Attribute names use the same byte grammar as element names. Values require single
or double quotes; whitespace around `=` is allowed and attributes must be separated
by whitespace. Empty values, `>`, opposite quotes and backslashes are ordinary
content; backslashes do not escape quotes. Raw `<` and forbidden control bytes are
invalid in values. References use the same grammar in text and quoted values.
Closing tags cannot have attributes. No boolean/unquoted attributes, whitespace
normalization, namespace resolution or attribute decoding is implied.

The standalone `lexer.Lexer` uses the same scanner without a tree or allocation.
It defaults to scalar; `lexer.For(.block)` selects vector run scanning explicitly.
Attribute-free tags are whole `open`/`close`/`empty` tokens. Attribute-bearing tags
yield `open_head`, `attribute` tokens, then `head_end` or `empty_end`. On an attribute
token, `name` is the name span and `span` is the quoted value span. Header-end tokens
cover only `>` or `/>`; retained element spans still cover the entire element.
Comments and CDATA produce whole `comment`/`cdata` tokens with raw delimiters.
The public lexer is strict: a malformed reference returns a latched syntax problem;
tolerance and diagnostics-only recovery are available through policy-bound parsing,
not a second lexical dialect.

### References, comments and CDATA

References require a semicolon: `&name;`, `&#decimal;`, or `&#xhex;` (lowercase `x`,
either-case hex digits). Named references use this parser's byte-oriented name
grammar; parsing does not require or look up their definitions. Numeric values must be
tab/LF/CR or in `U+0020–D7FF`, `U+E000–FFFD`, or `U+10000–10FFFF`. Arbitrarily long
digit sequences are handled without integer overflow, allocation or decoding.
These spellings and numeric ranges follow [XML 1.0 references](https://www.w3.org/TR/xml/#sec-references),
but the broader fragment/name/encoding contract is deliberately not full XML.

Comments close at `-->`; `--` cannot occur in their bodies, including a final
body hyphen immediately before the terminator. CDATA starts with the exact
case-sensitive `<![CDATA[` and ends at the first `]]>`. Neither construct nests
or interprets tags/references inside its body. They work at top level or within
element content, not inside tag headers/attribute values. All original bytes,
including whitespace, remain unchanged; the ordinary forbidden-control-byte
rule still applies. An incomplete supported opener such as `<!`, `<!-` or `<![C`
is invalid syntax, not unsupported. Other declaration families and processing
instructions remain unsupported; no DTD/external-entity processing is performed.

`syntax.malformed_reference` is `reject` by default. `warn` or `accept` treats
the offending `&` as literal and resumes ordinary scanning. There is no inserted
semicolon, replacement character or expanded value. The candidate prefix already
examined is literal-safe and is not rescanned; the stopping `<`, another `&`, or
matching attribute quote remains unconsumed. For a complete numeric reference
with an invalid value, its semicolon is included in the candidate. Tolerance
does not repair an unclosed attribute or permit a literal `<` inside its value.

```zig
const Tolerant = markup.Profile(.{
    .policy = .{ .syntax = .{ .malformed_reference = .warn } },
});
// With a continuing sink: one unchanged text node is counted, with
// one accepted deviation and one warning. measureIn does not retain a tree.
const report = Tolerant.measureIn("a & b", .{}, sink, .{});
```

Malformed-reference diagnostics cover the consumed candidate beginning at `&`,
excluding the byte that stopped recognition. Typed reasons distinguish missing
name, digits, semicolon, and an invalid numeric character. A following `&` starts
its own reference; `&&valid;` has one deviation. This is a documented syntax
assumption, not a claim that tolerated input is XML-conformant. Syntax policy is
applied during parsing; changing it later requires reparsing, not duplicate validation.

Tolerance does not override a sink's stop request. `FixedDiagnosticBag(N)`
requests stopping when it accepts its Nth item, even if no diagnostic was lost.
For example, a one-entry bag stops the example above with
`diagnostic_stopped.requested`, not success. Use a growable or streaming sink
that continues when complete parsing is required, or explicitly choose
`reporting.FixedBag(Diagnostic, N, .omit)` to retain a prefix and count omissions.
Growable sinks default to 1,024 entries, stop at that limit, and can fail allocation.
An explicit u16 limit or `.unlimited` is available; see [diagnostic destinations](REPORTING.md).

## Import and parse

Use the same package dependency as DOT, but select its independent module:

```zig
const dep = b.dependency("dot_parser", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("markup_parser", dep.module("markup_parser"));
```

```zig
const markup = @import("markup_parser");
var bag = markup.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var parsed = markup.parseBorrowed(allocator, "Hello <widget>world</widget>!", bag.sink(), .{});
defer parsed.deinit();

if (parsed.document) |document| {
    var roots = document.roots();
    while (roots.next()) |node| {
        _ = node.raw();      // borrowed full spelling, including element contents
        _ = node.name();     // null for leaves; borrowed bytes for an element
        _ = node.content();  // leaf body without comment/CDATA delimiters; null for elements
        _ = node.children();// allocation-free direct-child iterator
        var attributes = node.attributes();
        while (attributes.next()) |attribute| {
            _ = attribute.name();    // original name bytes
            _ = attribute.rawValue();// includes original quotes
            _ = attribute.value();   // strips only quotes; does not decode
        }
    }
}
```

[Runnable example](../examples/markup.zig). `Document.records` is a source-order
preorder forest of compact `Node` records; `Document.node(id)` bounds-checks IDs.
`NodeView.span()` is an original byte range. Empty-element spelling is recoverable
from source; no implicit text/name copying or normalization occurs.
`Document.attributes` is a separate source-order pool. Each `Attribute` stores an
owner `NodeId`, name span and quoted value span. `NodeView.attributes()` finds the
owner's range in O(log A), then iterates in O(1) per entry; it never merges duplicate
names. `AttributeView.raw()` preserves the whole pair, including whitespace around
`=`. Text/comment/CDATA leaves return empty child and attribute iterators.
References do not create extra nodes or a per-reference side table. Comments and
CDATA each count as one node, even with an empty body; they do not increase element
depth. `NodeKind` distinguishes `element`, `text`, `comment`, and `cdata`.

The compact `Node.name` field is an element-name span only when `name.len != 0`.
For leaves, `name.len == 0` and `name.start` stores the leaf `NodeKind` discriminator,
not a source offset. Prefer `kind()`, `raw()`, `name()` and `content()` over interpreting
the storage encoding. This keeps all nodes at 20 bytes without a new side pool.

`Document` is a trusted completed-parser representation, not an arbitrary document
builder. Public fields do not remove its preconditions: spans must refer to the
live source, leaves must have valid kind encodings and matching raw delimiters,
nodes must have valid preorder/subtree intervals, and attributes must
be in source order with nondecreasing owner IDs that refer to elements. Each
owner's attributes form one contiguous range; names and quoted values lie inside
that element's source span. Hand-built views must uphold the same invariants.
For example, owners `[0, 1, 0]` are an invalid representation, not a supported
alternate arrangement. Validation checks policy findings on valid syntax records;
it does not repair or certify arbitrary pools. Debug/ReleaseSafe scratch sizing
asserts attribute metadata/order during its existing sizing pass. Name/reference
validation also checks consumed node metadata (including leaf discriminators),
checks attributes when duplicate sizing is off, and asserts full attribute-cursor
coverage before marking those checks complete. These checks are folded into
existing walks, not a separate audit. Encoding-only validation checks source
length without inspecting unused pools; an all-off policy inspects nothing.
Fast/small builds rely on the contract; attribute lookup does not add a
whole-pool audit to every O(log A) lookup. Delayed validation of unchanged
parser-produced documents is unaffected.

The source must stay alive and unchanged while any view uses it. An owning
`ParseResult` frees its records with `deinit()`, never its source or diagnostic
bag; do not independently dispose copies of an owning result. `Document` is a
non-owning view and has no disposal operation. Optional `scratch_allocator` in
parse options separates temporary nesting storage from retained output.

Successful growable parsing attempts to trim unused node/attribute capacity in place.
If the allocator refuses, the result keeps that capacity; finalization never
allocates/copies merely to shrink or turns success into an allocation failure.
`parsed.retainedBytes()` reports reserved node and attribute bytes in the allocator's native
`usize` domain, including remaining growth slack. It excludes source, temporary
scratch, diagnostics, allocator-internal overhead and process RSS. A 20-byte node
does not imply an exactly packed growing
allocation. Use measurement and fixed storage when exact node capacity is needed.

## Fixed memory and measurement

```zig
var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 32 }) = .{};
var frames: markup.FixedParseScratch(8) = .{};
const parsed = markup.parseBorrowedIn(source, .{
    .document = nodes.storage(),
    .scratch = frames.storage(),
}, markup.diagnostic.discard, .{});
```

This path allocates nothing. Source, both output pools and any views must obey their
lifetimes; scratch may be reused after completion. Both fixed types expose
`byte_size`. Each retained node and each attribute is 20 bytes; each nesting frame is 12 bytes
on the tested native/32-bit layouts. Source, bag and session memory are additional.
Self-closing elements count toward element depth but need no persistent frame.

`measureIn(source, scratch, sink, options)` uses the same grammar without retained
records. `measure(allocator, source, sink, options)` allocates only nesting scratch.
On success, `counts.nodes` and `counts.attributes` are exact pool capacities; `counts.max_depth` is
a safe scratch-frame capacity (possibly larger than needed for self-closing tags).
Measurement followed by parsing is two explicit passes, not caching.

## Independent validation

Parsing checks structure; it does **not** run duplicate, encoding, name-rule or
reference-catalog validation.
Validate a completed document immediately or later, under the same or a different
profile. Alternatively, validate local scopes without a document (below).
Validation never changes retained records or discards occurrences.

```zig
const document = parsed.document.?;
const checked = markup.validate(allocator, &document, bag.sink(), .{});
// Accept only if checked.completion == .complete and checked.validity == .valid.

// Optional encoding check, in addition to the default duplicate check:
const Checked = markup.Profile(.{
    .policy = .{ .validation = .{ .invalid_utf8 = .err } },
});
const encoded = Checked.validate(allocator, &document, bag.sink(), .{});
```

For allocation-free validation, use
`validateIn(&document, scratch, sink, options)`. `FixedValidationScratch(n).storage()`
supplies scratch, or allocate `AttributeKeyScratch` entries explicitly.
`requiredValidationScratch(&document)` reports the largest attribute count on any
one element, or zero if all have fewer than two. Each scratch entry is 8 bytes.
Scratch cannot alias source, document pools or diagnostic storage; it is reusable
after the call. The allocator-backed `validate` frees its temporary scratch before
returning. With duplicate checking off, validation needs no scratch allocation.
Name/reference checks still traverse nodes and attributes. UTF-8-only validation
does not inspect either pool and needs no allocation or scratch;
pass `.{}` as scratch to `validateIn`. The sink may allocate independently.
With all checks off, source and pools are not inspected.

Duplicate checking compares attribute names byte-for-byte and case-sensitively,
scoped to a single element. Each occurrence after the first produces one finding
whose related span identifies the first. In document validation, findings from all enabled checks are merged in document order by primary
span start. At equal starts the order is encoding, duplicate attribute, name rule,
then reference catalog. Error findings make
validity invalid but do not stop further checks; warning findings do not invalidate.
A discarded diagnostic still affects counters and validity.

`validation.invalid_utf8` checks the entire source, including names, quoted values,
comments, CDATA and BOM bytes. A valid sequence consumes 1–4 bytes. At a byte that
cannot start a valid sequence, it emits a one-byte finding and advances one byte;
remaining invalid continuation bytes may produce further findings. Overlong,
truncated, surrogate and out-of-range encodings are invalid. The error/warning
codes are `E.Validation.Encoding.003` / `W.Validation.Encoding.003`, with the raw
byte in `details.byte`. No replacement, transcoding, normalization, entity
expansion, XML character/name validation or source mutation occurs. Valid UTF-8
does not imply XML or Graphviz conformance, and cannot weaken parsing's control-byte
or unsupported-encoding rules.

### Local scopes, including rejected documents

Local validation does not require a valid enclosing element or a published tree.
These entry points use the **same validation policies and rule implementations**:

| Entry points on `markup` or a configured `Profile` | Input and responsibility |
| --- | --- |
| `validate` / `validateIn` | Completed `Document`; checks retained content, not parsing again |
| `validateScope` / `validateScopeIn` | One caller-described `ValidationScope` in the original source; bounds-checked local checks |
| `validateSource` / `validateSourceIn` | Recognizes local scopes directly from source, even if element matching fails; no tree or nesting stack |

`ValidationScope` has `opening_header`, `opening_name`, `closing_name`,
`attribute_name`, `attribute_value`, `text` and `bytes` alternatives. Name scopes
run name/encoding checks; text and attribute values run reference/name/encoding
checks; `bytes` runs encoding only. Header scopes also check duplicate keys.
Attribute-value scopes contain the content **without quotes**. No generic string
dialect, decoding, normalization or custom string processor is added here.

```zig
// This region can be checked even when a later closing tag is wrong.
const checked_value = Checked.validateScopeIn(
    source, .{ .attribute_value = content_span }, .{}, bag.sink(), .{},
);

// After parsing returns success OR invalid_syntax, local validation need not
// depend on parsed.document. Do not automatically continue after cancellation,
// resource exhaustion or a diagnostic stop/failure.
const checked_source = Checked.validateSource(allocator, source, bag.sink(), .{});
```

`validateSource` emits **validation findings only**, not a second copy of syntax
diagnostics. `<x a='1' a='2'></wrong>` reports the duplicate independently of
the mismatched closer. `<x a='1' a='2'` can still report the known duplicate,
but reports incomplete coverage. Recognized names and completed references in an
unfinished quoted-value prefix are checkable too. Missing delimiters are never
invented. This explicit validation operation synchronizes selected malformed
headers using the parser's quote-aware boundary rules regardless of `on_error`;
skipped bytes are not certified. `.fail_fast` stops at its first validation error,
not a syntax error already reported by another operation. Uncertain boundaries
still stop the scope walk. Combined fragment calls do not start this fallback
after a fail-fast syntax error; callers can request it independently.
Like document validation, the automatic source walk checks element names at their
opening occurrence, not again at the closer. Tag matching remains parsing's job;
explicit `closing_name` scope validation is still available. Whole-source encoding
validation still covers closing-tag bytes. When cancellation is enabled, the source
walk and local checks share one 64-work-unit polling countdown instead of polling
on each scope entry. Units include scanner steps, examined bytes and record steps;
revisited bytes count again, so this is not one callback per 64 source bytes.

**A complete, valid source-validation result is not proof of well-formed markup.**
It describes the selected local checks, not tag balance or syntax acceptance.
Acceptance still requires successful parsing and completed, valid validation.
`completion = .{ .incomplete = offset }` identifies the earliest loss of requested
scope coverage, as a zero-based offset in the original source. Already observed
errors keep `validity = .invalid`, otherwise validity is unknown. The source walk
uses the first lexical problem's location (EOF is `source.len`, an unsupported
construct points to its opening). Recovery never advances this offset past an
earlier gap. Later regions may still be checked, and whole-source encoding may
already be complete: this is **not a resume cursor or a last-validated offset**.
Operational stops retain their own completion cause instead of returning a gap.
Individual `validateScope` results stay independent of their enclosing document.
No partial tree is published or constructed for validation.

`HeaderScope` contains its raw `span`, `name`, ordered `ScopeAttribute` slice and
`complete` flag. Attributes retain quoted-value spans; `value.len == 0` means an
unavailable value in an incomplete header (an empty quoted value has length 2).
Names and duplicates remain checkable in that case. For an incomplete supplied
header, the offset is the end of the first attribute name whose value is
unavailable; otherwise it is the end of the supplied header prefix. Unlike the
source walk, this call cannot check value prefixes the caller did not describe.

Public scope calls check metadata **in every build mode**, even with all content
checks disabled: source/index range, span containment, nonempty names, attribute
ordering and matching quote framing for present values. Invalid metadata returns
`completion = .invalid_scope`, unknown validity, zero findings and all checks
`not_run`. It is a caller-input failure, not a document error: no source diagnostic
is emitted and no scratch allocation occurs. Checking is O(1) for a leaf and O(A)
for a header with A attributes; enabled cancellation is polled during that audit.
Scanner-produced scopes use a separate internal trusted path without this audit.

These checks do not reparse the supplied scope or discover omitted attributes.
Callers remain responsible for faithful regions and valid borrowed slices:
source, attributes and scratch must remain alive and unmodified during the call;
scratch must not alias source, scope data or diagnostics. Diagnostics keep original
source coordinates. The existing retained-`Document` contract is unchanged.

`validateScopeIn(source, scope, scratch, sink, options)` reuses `ValidationScratch`;
only a header with duplicate checking and at least two attributes needs keys.
`validateScope(allocator, source, scope, sink, options)` allocates those keys only
when needed, and releases them before returning.

`validateSourceIn(source, scratch, sink, options)` uses `SourceValidationScratch`
with `attributes` and `attribute_keys` slices. `FixedSourceValidationScratch(n)`
provides both: **24 bytes per attribute slot**, reused for the largest header,
including recognized names whose values are unfinished. The allocator-backed
form grows/reuses these two buffers and frees them on return; growth can transiently
hold old and new allocations. Duplicate checking off needs neither buffer and
works with a failing allocator. No per-element scope objects are allocated.
`storage_exhausted` reports required entries (a lower bound when scanning stopped
at a full buffer); the resource diagnostic distinguishes header attributes from
sorting keys. `source_limit` reports the enforced `limits.max_source_bytes`.
Other parse limits still belong to parsing, not this tree-free validation pass.
Use fixed scratch to bound header memory explicitly.

The source form is an **additional lexical pass**, not a free extension of parsing.
Do not also run document validation into the same bag unless repeating findings
is intentional. Standalone scope validation avoids that source pass when a caller
already has trustworthy boundaries. Existing parse-only calls do no new work.
Source validation checks enabled whole-source UTF-8 first, then local scopes in
encounter order; each phase is source ordered, not globally interleaved. A closing
name is independently checked even when it differs from its opener; on valid
documents, the retained validator still checks identical matched names once.
Encoding can complete even if later scope recognition cannot. All forms honor
sink stop/failure and enabled cancellation. As with document validation, sorting,
allocation and validation calls are **not work-credit metered**.

### Optional name rules and reference catalogs

These are independently selected checks, not restrictions on the structural
grammar or a promise of a complete XML/HTML/Graphviz dialect. Both default to off:

```zig
const CheckedNames = markup.Profile(.{ .policy = .{ .validation = .{
    .names = .{ .rule = .xml_1_0, .severity = .err },
    .references = .{ .catalog = .xml_predefined, .severity = .warning },
} } });
const checked_names = CheckedNames.validate(allocator, &document, bag.sink(), .{});
```

`names.rule = .xml_1_0` follows [XML 1.0 Fifth Edition NameStartChar/NameChar](https://www.w3.org/TR/xml/#sec-common-syn).
It checks each element name once at its opening occurrence, every attribute name,
and every syntactically complete named-reference name. Matching closing names are
already byte-identical; they do not produce a second name finding. It does not
resolve namespaces, fold case, normalize Unicode, restrict tag vocabulary or
enable whole-source UTF-8 validation. Colons remain ordinary allowed name characters.

Name checking decodes only examined names. One finding per invalid name identifies
its first disallowed code point; malformed UTF-8 uses a one-byte primary span.
`related` covers the full name. `details.name.context` is `element`, `attribute`
or `reference`; `.problem` is `invalid_start`, `invalid_character` or `invalid_utf8`.
Codes are `E.Validation.Name.003` / `W.Validation.Name.003`. Other content is not
encoding-checked by this rule. When whole-source UTF-8 checking is also enabled,
the same name may produce independent encoding and name findings, each with its
own severity and retained entry. Counts are findings, not unique bad positions.

`references.catalog = .xml_predefined` recognizes exactly `amp`, `lt`, `gt`, `quot`
and `apos`, case-sensitively. Unknown means absent from this selected catalog, not
invalid in every dialect. Each unknown reference produces one whole-reference
span (`&name;`) with `E.Validation.Reference.003` / `W.Validation.Reference.003`.
Only references in text and quoted attribute values are checked, not comments or
CDATA. Numeric references need no name lookup. `&amp;unknown;` is a known `amp`
reference followed by literal text, not recursive expansion. Malformed candidates
accepted as literal text stay literal during validation. Neither check changes
source bytes, invents values, reads external resources or performs DTD processing.

Rules and catalogs have separate typed selections and severity; enabling either
does not enable the other. Only the above rule/catalog is currently supplied;
there is no runtime extension registry. In a runtime-enabled profile, nested
patches inherit unspecified leaves. Complete `standard`/`untrusted` presets reset
both checks to off. Other catalogs and dialect semantics are not yet implemented.

### Outcomes and costs

`ValidationResult` separates `completion`, `validity`, per-check statuses
(`checks.duplicate_attribute`, `checks.invalid_utf8`, `checks.names`,
`checks.references`), u64 `errors`/`warnings` and
`diagnostic_delivery`. Offsets, capacities and parsing counters remain u32;
validation totals use u64 for independently counted checks, as in DOT.
Check status is `not_run` when off, `incomplete` until finished, or `complete`.
A completed check stays complete if a later check is interrupted. A complete
off-policy result is valid under the selected policy, **not** proof of uniqueness
or validity under any disabled name, encoding or reference rule. Interrupted results are `invalid` if an error was already
found, otherwise `unknown`. A sink's accepted
stop ends the pass immediately with complete delivery of the discovered prefix;
rejection ends it with failed delivery. Neither implies all findings were discovered.
With `.on_error = .fail_fast`, the first error finding ends validation with
`completion = .error_stopped`, invalid validity and truthful per-check statuses.
This is not a sink stop: the same bag can receive findings from a later operation.
Warnings and discarded/filtered delivery do not change error classification.
Actual sink stop/failure takes precedence if it occurs while reporting the error.
Insufficient scratch reports `storage_exhausted` with the required entry count;
allocator failure reports `out_of_memory`. Duplicate scratch is preflighted before
any enabled check runs; a resource failure leaves enabled checks incomplete and counts
zero. Resource diagnostics do not replace those causes, even if the diagnostic
destination fails.
Both resource diagnostics use the name span of the first element with the largest
attribute list. For allocation failure this identifies the allocation's context,
not malformed syntax or proof that this element alone caused memory exhaustion.

This is a separate run-to-completion pass. Parsing's `execution.metering` does not
bound validation, sorting, scratch sizing or allocations. Enabled cancellation is
polled at entry and through one shared 64-unit work countdown: examined bytes in
UTF-8, name and reference scans, plus element/attribute traversal steps. Short
scans share the remainder instead of polling again at each name/value. Bytes
revisited by another check count again, so this is not one callback per 64 unique
source bytes or an exact callback-count API. Completing a UTF-8 scalar or reference
delimiter can cross a threshold by at most three bytes; scans do not split scalars.
Reference-free text uses chunked delimiter search when cancellation is enabled.
Diagnostic sink stops remain immediate, without waiting for the next poll.
The countdown is one temporary u32, with no per-node storage. Fixed-disabled
cancellation has no polling state or callback branches.
Scratch sizing/grouping, duplicate sorting and duplicate-name comparisons are not
internally cancellable. This is not bounded validation.
UTF-8 checking is O(source bytes), using one u32 cursor with no finding buffer.
Fixed profiles with encoding off omit this cursor and the scan; runtime off skips
the scan. Heap sorting uses O(A log A) comparisons per attribute group with
bytewise name comparisons, followed by linear mapping/emission in source order;
there is no second sort. Allocator-backed validation sizes scratch only once and
reuses that requirement during checking. Temporary memory is O(max attributes on one element).
Source and document pools must stay alive and unchanged, as with parsing views.

Name/reference checking adds a linear forest/attribute walk, name decoding and
context-aware rescanning of text/value spans to locate references. Even names-only
checking scans those spans because reference names are in scope; their positions
are not retained separately. No decoded strings, node metadata, reference pool or
finding queue is allocated. New checks without duplicate checking can use a failing
allocator successfully. Combined UTF-8 validation may examine the same bytes again.
When both new checks are off, validation uses the original attribute-only/encoding
path and does not walk the forest. Fixed-disabled code can be excluded; runtime-off
skips work but runtime-selectable code can remain linked. Enabled latency and
decimal MB/s are reported separately by the benchmark below.

## Untrusted input

For untrusted fragments, start with `presets.untrusted` and a bounded diagnostic
destination, then tailor the budgets to your application:

```zig
const Reader = markup.Profile(.{ .policy = markup.presets.untrusted });
var bag = markup.GrowableDiagnosticBag.init(allocator, .{}); // 1024 entries
defer bag.deinit();
// Bound acquisition BEFORE allocating/reading source, not only after it arrives.
var parsed = Reader.parseBorrowed(allocator, source, bag.sink(), .{});
defer parsed.deinit();
if (parsed.document) |document| {
    const checked = Reader.validate(allocator, &document, bag.sink(), .{});
    // Accept only with checked.completion == .complete and validity == .valid.
}
```

| Parsing budget | `presets.untrusted` |
| --- | ---: |
| Source bytes | 8 MiB (8,388,608 bytes) |
| Nodes | 100,000 |
| Attributes | 200,000 |
| Element nesting depth | 256 |

These are finite starting budgets, **not a universal safe size or total-memory
guarantee**. The preset is a complete copy of `standard` with only those limits
changed: syntax stays rejecting, UTF-8 checking stays off, and metering/cancellation
stay off. Raw bytes do not become invalid merely because their source is untrusted.
All leaves retain compile-time/runtime parity; runtime overrides explicitly can
raise or lower budgets. A complete preset resets all baseline leaves; use its
`.limits` subtree alone when other configured behavior must remain unchanged.

Limits are enforced during parsing/measurement, not retroactively by `validate`
on an already-created document. Parsing can allocate output before finding an
error; validation sizes/sorts duplicate scratch before reporting findings. The
bag cap therefore cannot replace source/output/scratch limits. For strict heap
budgets, use fixed pools or a bounded allocator covering all relevant allocations,
including diagnostic storage, temporary growth buffers and request concurrency.
Merely counting final records does not bound an allocator's peak usage.

For cooperative scheduling, explicitly enable metering/cancellation and use fixed
sessions with an application-owned total work/deadline budget. `advance(n)` bounds
one call, not total work if called indefinitely. Validation is still unmetered;
scratch sizing, heapsort and name comparisons do not poll cancellation internally.
Use input/attribute limits and, where required, external worker isolation/timeouts.

Prefer `ReleaseSafe` as a defense-in-depth default at hostile-input boundaries.
`ReleaseFast` and `ReleaseSmall` disable compiler runtime safety checks by default;
they do not remove the library's explicit policy/capacity checks. An undiscovered
illegal operation may have arbitrary effects without safety checks; `ReleaseSafe`
can catch additional violations with a panic, not a recoverable parser result.
Neither mode proves memory safety or prevents resource exhaustion. Keep adversarial
tests and fuzzing in the validation process regardless of build mode. See the
[Zig build-mode and illegal-behavior documentation](https://ziglang.org/documentation/0.16.0/#Illegal-Behavior).

## Policies and sessions

```zig
const Reader = markup.Profile(.{
    .policy = .{
        .scanner = .block, // opt-in; scalar is the library default
        .limits = .{ .max_nesting = 64, .max_nodes = 10_000 },
    },
    .runtime_policy = true, // optional; defaults to false
});
const parsed = Reader.parseBorrowedIn(source, memory, sink, .{
    .policy = .{ .limits = .{ .max_nodes = 20_000 } },
});
```

| Policy leaf | Values/default |
| --- | --- |
| `scanner` | `scalar` (default), `block`; same syntax and output, different work granularity |
| `on_error` | `collect` (default), `fail_fast`; continue independent checks/safe syntax recovery, or end the operation at its first error. Selects error handling, not the grammar |
| `diagnostics.fixes` | `all` (default), `machine_applicable`, `off`; filters repair offers only |
| `diagnostics.unsupported` | `err` (default), `warning`, `silent`; reporting/classification for unsupported input, not permission to accept or interpret it |
| `limits.max_source_bytes` | u32; default `2^32 - 1` |
| `limits.max_nodes` | u32; default `2^32 - 1`; elements, nonempty text runs, comments and CDATA sections |
| `limits.max_attributes` | u32; default `2^32 - 1`; every occurrence counts |
| `limits.max_nesting` | u32; default `2^32 - 1`; top-level elements have depth 1 |
| `validation.duplicate_attribute` | `err` (default), `warning`, `off`; affects validation, not parsing |
| `validation.invalid_utf8` | `off` (default), `warning`, `err`; checks raw source encoding during validation only |
| `validation.names.rule` | `xml_1_0`; optional XML 1.0 Fifth Edition name-character rule |
| `validation.names.severity` | `off` (default), `warning`, `err`; independent of whole-source encoding and vocabulary |
| `validation.references.catalog` | `xml_predefined`; five predefined XML reference names |
| `validation.references.severity` | `off` (default), `warning`, `err`; no expansion or external lookup |
| `syntax.malformed_reference` | `reject` (default), `warn`, `accept`; tolerant cases keep the `&` literal |
| `execution.metering` | boolean; default false |
| `execution.cancellation` | boolean; default false |

Zero limits are valid. Limits do not supply storage. A runtime patch inherits all
unspecified baseline leaves. `presets.standard` supplies the complete defaults.
`validatePolicy` is compile-time-only in fixed profiles and callable at runtime
when overrides are enabled. Every typed combination in this slice is valid, so
it returns `.valid`; parsing therefore has no policy-error union. This does not
guarantee valid input or sufficient storage. No mode/backend/check is exposed
before its implementation exists.

`Profile.Policies` exposes the shared policy binding, with an empty error set for
this currently infallible schema. Policy preparation does not compose parsing or
schedule another processor; standalone use needs neither DOT nor a `PolicySet`.

`Profile.Session.init(source, memory, sink, options)` borrows fixed resources and
does not scan, allocate or call consumers. `run()` completes; when metering is
enabled, `advance(budget: u32)` returns `Progress` with optional terminal outcome,
work used, source frontier and accepted-prefix counts. `BoundedSession` is the
fixed metered convenience. Runtime `advance` returns `error.MeteringDisabled`
without work when disabled; calling it in a fixed unmetered build is a compile
error. Settings are latched until `reset(source, sink, options)`.

Fixed profiles compile in their selected scanner. Runtime-enabled profiles select
a specialized scanner/execution engine once per operation or session reset, not
per byte. Both scanners share the same token and grammar state machines; no
source-sized masks, token ring or additional retained records are allocated.
Plain parsing (both metering and cancellation disabled) scans to the next token
or finding in tight loops. Its vector runs are not capped at 64 bytes; the
short-run probe runs once per run, not once per window. Enabling either execution
option restores bounded steps and the block scanner's 64-byte window limit.

One scalar credit performs at most one source-byte/EOF examination, one bounded
grammar transition, or one event attempt. A block scanning credit can classify
a run in a window of up to 64 source bytes using native-width vectors, or handle
a scalar boundary transition. The first byte may be reexamined when a run stops
immediately; a nonempty run yields before its boundary is processed. Short tails
are read scalarly, never beyond the source. Closing-name comparison remains
byte-stepped for both backends, including rereads. A recovery search credit probes
one ancestor length or compares one pair of name bytes. The initial four-byte encoding
probe also remains byte-stepped. Frontier includes vector lookahead, not just
consumed bytes.

A four-byte short-run probe can overlap the vector classification; all lookahead
still stays within that 64-byte window during bounded execution. In plain mode,
when no complete vector fits, the scalar tail continues after the successful
probe instead of rereading it. The bounded probe/tail path is unchanged. No promise
of exactly one physical read per byte is made for block scanning.

One credit always permits progress, and budget partitioning does not change total
work within a backend. Credit totals and intermediate frontiers need not agree
between backends. Zero budget does no normal work, though it can observe
cancellation. Hooks are checked before each bounded step. Credits exclude callback
time and are not wall-clock, instruction or byte-progress units.

Cancellation hooks are borrowed `Cancellation` values in options; enabling the
policy does not supply a hook. A runtime policy with cancellation disabled never
polls a supplied hook, just as in DOT. Supplying a hook does not implicitly enable
the policy; enable `execution.cancellation` in the baseline or runtime patch.
An enabled policy without a hook is valid. Explicit `cancel()`/`deinit()` terminate
unfinished work regardless of whether polling is enabled.
Terminal calls do not repeat scanning, polling, diagnostics or output. Reset
invalidates earlier views and reuses the caller storage, but does not clear bags.
Only one active owner may drive a session; callbacks must not reenter it. Sessions
can move between calls without retaining pointers into their former location.

## Results and diagnostics

Results keep `outcome`, `completion`, `syntax_errors`, `diagnostic_delivery`,
`diagnostic_stop`, and factual `counts` separate. Only `.success` publishes a document.
`completion = .complete` means EOF and all pending structural checks were reached;
recovery can complete with `invalid_syntax`. Every other stop is `.incomplete`.
The u32 `syntax_errors` total counts rejected syntax findings, even if delivery
fails or a later cancellation/resource/unsupported outcome stops the operation.
It excludes warnings and resource/unsupported findings. Session progress exposes
the same running total. Counts on failure describe recognized constructs, including
those reached during recovery, not retained records or a sizing guarantee.
Parse results, measurement reports and session progress also expose u32
`accepted_deviations` and `warnings`. Each tolerated ampersand increments the former;
`warn` also increments the latter before delivery. Discarding/filtering diagnostics
does not alter counts; `accept` produces no warning or diagnostic call. Warning
counts also include unsupported-feature warnings (without an accepted deviation).
Counts survive later failure, cancellation and sink stopping. They are source-bounded
summaries, not a retained per-reference history or validation's separate totals.

| Outcome | Meaning |
| --- | --- |
| `success` | Whole fragment parsed under the selected syntax policy |
| `invalid_syntax` | Rejected structural syntax |
| `unsupported_feature` | Recognized construct is not processed; contents unvalidated |
| `resource_limit` | Source/node/attribute/nesting policy or recovery ancestor-search ceiling reached |
| `storage_exhausted` | Fixed node/attribute pool or nesting frames exhausted |
| `out_of_memory` | Explicit allocator failed |
| `cancelled` | Caller stopped unfinished work |
| `sink_failure` | Private syntax consumer failed |
| `diagnostic_stopped` | A warning or recoverable-error sink requested stopping or rejected delivery; contains the stop reason |

Parsing can emit multiple warnings and recoverable errors before completion or a
terminal failure. An already-terminal cause (such as an unterminated quoted value)
survives a diagnostic destination that stops or rejects it; rejection sets
`diagnostic_delivery = .failed`. Parse results and measurement/session reports
also carry `diagnostic_stop: ?reporting.StopReason`: null means no destination stop;
`.requested` means the last finding was accepted with `.stop`; rejection records
its failure reason. This preserves both the original terminal outcome and the
destination acknowledgment. Composed callers must not begin another phase after
this field is set or delivery failed; fragment helpers enforce that rule.
Cancellation emits no diagnostic.
A warning or recoverable error followed by sink `.stop` aborts unfinished parsing with
`diagnostic_stopped.requested` and complete delivery of the emitted prefix. Sink
errors produce the corresponding reason and failed delivery. Neither case publishes
a document, sends another diagnostic into the stopped sink, or continues scanning.
A missing reference semicolon can carry a
possible repair if terminating the candidate makes it syntactically valid;
forbidden/out-of-range numeric values (for example `&#5` or `&#x110000`) have no
such offer. The parser never applies it. `Diagnostic.fix` is a compact offer,
and `Diagnostic.suggestedFix()` returns its full typed edit on demand. This offer
is `maybe` because literal text may have been intended. `diagnostics.fixes`
filters offers at compile time or runtime without hiding findings or changing
outcomes; `machine_applicable` currently suppresses every markup offer. Other
repairs, including choosing between duplicate attributes, are not guessed.

Diagnostics use the `markup_parser` WDP namespace, with processor-owned typed
details and optional related opener/first-attribute spans. `code.structured()`, `compactId()` and
`qualifiedCompactId()` need no runtime hashing. The authoritative current registry
is [diagnostic.zig](../src/markup/diagnostic.zig); fixed/growable/streaming bags use
the same [shared reporting contracts](REPORTING.md) as DOT without sharing payloads.

`Code.info()` provides decomposed component/primary/sequence metadata, sequence
aliases, summaries and hints. Code text and compact identities are derived and
validated at compile time, not manually assembled at runtime. `markup.console`
uses the same optional console engine as DOT: compact or boxed output, related
source annotations, ASCII/Unicode frames, opt-in ANSI colors and list summaries.
See [metadata and presentation](REPORTING.md#metadata-and-console-presentation)
and the runnable [example](../examples/markup.zig). Rendering is allocation-free,
caller-driven, and absent from parser execution; markup diagnostics remain 36 bytes.

## Diagnostics-only structural recovery

`on_error = .collect` is the standard/untrusted default. Choose `.fail_fast`
explicitly to stop the requested operation at its first error. Recovery is the
internal mechanism for reaching safe boundaries, not another public policy.
Rejected input stays rejected under either setting. Validation uses the same
error-handling choice; explicitly invoked validation is a new operation.
Tree-dependent checks still require a successfully parsed `Document`. The local
checks described above can instead run through `validateSource` or `validateScope`
without a partial tree; they are not implicitly run by parsing/recovery.

| Rejected construct | Structural recovery action |
| --- | --- |
| Closing tag with no open element | Report and discard that closing tag |
| Closing tag mismatches the current element | Report once; find the nearest byte-exact matching open ancestor and unwind through it. If none matches, discard the closer and keep the open stack |
| Open elements left at EOF | Report each unclosed element, innermost first |
| Malformed reference with `syntax.malformed_reference = .reject` | Report and resume using the scanner's known text/quoted-value boundary; do not count it as an accepted deviation |
| Attribute error in a recognized opening header: missing `=`, missing/unquoted value, missing separator, or invalid attribute-tail byte | Report the first error; scan forward to an explicit `>` or `/>` using the rules below, then resume content |
| Other malformed headers, errors inside quoted values, unterminated quote/comment/CDATA, invalid control byte, unsupported feature | Stop the fragment; no guessed synchronization or extra missing-close cascade |

Opening-header recovery is diagnostics-only, not acceptance of unquoted/boolean
attributes. It requires an already recognized element name and attribute-bearing
opening header. After reporting the triggering attribute error, the remaining
header bytes are skipped, not validated or retained. Earlier findings from the
same header remain reported; its skipped attributes/references do not increase
attribute, warning or accepted-deviation counts. Normal syntax checks resume
after the header. Independent source/scope validation can inspect recognized
attributes even when parsing cannot publish a document.

Single and double quotes shelter `>` and `/` during synchronization. A raw `<`
(even inside quotes), forbidden control byte, EOF before a boundary, or unquoted
slash not immediately followed by `>` stops with `.incomplete`; no additional
parent/unclosed-element cascade is emitted for this abandoned region. Invalid
element names, malformed closing tags, and errors within normally scanned quoted
values remain terminal. This is a conservative continuation rule, not an inference
of the author's intended correction.

An explicit `>` pushes the pending element's original name onto the traversal
stack; `/>` adds no frame. The opening element was already counted and checked
against node/depth limits, so it is not counted again. Scratch exhaustion still
stops execution. A fully recovered fragment remains `invalid_syntax` with
`.complete` completion; it never publishes a repaired or partial document.
Synchronization performs at most one byte examination per parser step, uses no
header buffer, and honors normal cancellation, metering and diagnostic stops.

At the first rejection, staged output is aborted exactly once. No further output
events or pool growth occur; only scanning, grammar, counters, diagnostics and
nesting scratch continue. Policy limits still apply after rejection. No synthetic
tags, repaired tree or partial document are produced. One mismatch covers frames
unwound to an ancestor; it does not produce an additional missing-close finding
for each abandoned frame. Findings are emitted in encounter order (EOF findings
can have earlier related opener spans), without a sorting buffer.

To prevent repeated unmatched closers from causing quadratic ancestor searches,
all searches share **`source.len` work units**: one per ancestor-length probe and
one per compared byte pair. Exhaustion returns `resource_limit` with resource
`recovery_work`, that ceiling in `limit`, and incomplete completion. This built-in
complexity ceiling is not configurable in this slice. Normal scanning/comparison
is already linear; metering/cancellation also apply during recovery. Caller
callbacks and allocation costs remain outside parser credits.

The fixed fail-fast machine excludes recovery search/count state and continuation
paths. Recovery adds constant session state, no retained-record or per-frame
fields. Finding storage and nesting scratch can grow while collecting errors;
use bounded diagnostics, limits and allocator budgets for untrusted input.

## Verification and costs

- `zig build test-markup`: standalone unit/consumer/compile-fail tests, no DOT build.
- `zig build test`: includes coexistence with DOT and shared primitive tests.
- `zig build check-freestanding`: consumed RISC-V32/Wasm32 fixed/runtime profiles.
- `zig build examples`: includes the standalone example.
- `zig build bench-markup -Doptimize=ReleaseFast`: flat, mixed, text, deep, attribute,
  reference, comment, CDATA, prose, long-name and long-value fixtures; both backends
  with fixed/runtime/count-only/cancellable latency and decimal MB/s, record/scratch
  and session sizes. Duplicate validation and opt-in UTF-8 checks (ASCII, Unicode,
  malformed bytes, combined checks), name rules (ASCII/Unicode), reference catalogs,
  plain text and tolerated reference candidates are timed separately with a discard sink and
  preallocated scratch, if needed. Storage figures are not allocator overhead or
  process RSS.
- `zig build bench-markup -Doptimize=ReleaseFast -- --rules-only`: just the new
  optional name/reference validation costs, without the parsing benchmark matrix.
- `zig build bench-markup -Doptimize=ReleaseFast -- --validation-only`: name/reference
  and encoding costs, plus fixed/runtime cancellation latency and callback counts
  on 100 KB text/name scans. The callback counter is observable; parsing and source
  construction are outside the timer.
- `zig build bench-markup -Doptimize=ReleaseFast -- --scopes-only`: independent
  source validation of complete headers, bad closers and malformed headers;
  scalar/block and fixed/runtime policies, with explicit reusable scratch.

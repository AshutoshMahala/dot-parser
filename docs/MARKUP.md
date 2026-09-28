# Standalone structural markup

Current development implementation, after 0.3.0: import `markup_parser` without
importing `dot_parser`. This is an experimental XML-like **fragment** parser,
not browser HTML, complete XML, or Graphviz label validation. DOT HTML-like
identifiers are still unsupported by the DOT parser.

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
| Unclosed, mismatched or unexpected closing tags | Invalid syntax; no partial document |
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
tolerance is available through policy-bound parsing, not a second lexical dialect.

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
and enabled validation assert attribute metadata/order during their existing sizing
pass. Fast/small builds rely on the contract; attribute lookup does not add a
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
profile. Validation never changes the retained records or discards occurrences.

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
whose related span identifies the first. Findings from all enabled checks are merged in document order by primary
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
polled at entry, between elements, before duplicate findings and before each
UTF-8 sequence (at most four bytes), and inside name decoding/reference scans.
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
byte-stepped for both backends, including rereads. The initial four-byte encoding
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

Results keep `outcome`, `diagnostic_delivery`, and factual `counts` separate.
Only `.success` publishes a document. Counts on failure describe accepted prefix
events, not a usable partial tree or completed validation.
Parse results, measurement reports and session progress also expose u32
`accepted_deviations` and `warnings`. Each tolerated ampersand increments the former;
`warn` also increments the latter before delivery. Discarding/filtering diagnostics
does not alter counts; `accept` produces no warning or diagnostic call. Counts
survive later failure, cancellation and sink stopping. They are source-bounded
summaries, not a retained per-reference history or validation's separate totals.

| Outcome | Meaning |
| --- | --- |
| `success` | Whole fragment parsed under the selected syntax policy |
| `invalid_syntax` | Rejected structural syntax |
| `unsupported_feature` | Recognized construct is not processed; contents unvalidated |
| `resource_limit` | Source/node/attribute/nesting policy reached |
| `storage_exhausted` | Fixed node/attribute pool or nesting frames exhausted |
| `out_of_memory` | Explicit allocator failed |
| `cancelled` | Caller stopped unfinished work |
| `sink_failure` | Private syntax consumer failed |
| `diagnostic_stopped` | Warning sink requested stopping or rejected delivery; contains the stop reason |

Parsing can emit multiple accepted-reference warnings before at most one terminal failure diagnostic.
Its original cause survives a diagnostic destination that stops or rejects it;
rejection sets `diagnostic_delivery = .failed`. Cancellation emits no diagnostic.
An accepted warning followed by sink `.stop` aborts unfinished parsing with
`diagnostic_stopped.requested` and complete delivery of the emitted prefix. Sink
errors produce the corresponding reason and failed delivery. Neither case publishes
a document, sends another diagnostic into the stopped sink, or continues scanning.
No markup fix suggestions or syntax recovery are implemented in this slice.

Diagnostics use the `markup_parser` WDP namespace, with processor-owned typed
details and optional related opener/first-attribute spans. `code.structured()`, `compactId()` and
`qualifiedCompactId()` need no runtime hashing. The authoritative current registry
is [diagnostic.zig](../src/markup/diagnostic.zig); fixed/growable/streaming bags use
the same [shared reporting contracts](REPORTING.md) as DOT without sharing payloads.

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

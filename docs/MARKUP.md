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
| Non-ASCII names/text, including invalid UTF-8 bytes | Preserved without encoding validation |
| Quoted attributes: `<a x='1' y="2"/>` | Preserved in source order, including duplicates |
| Duplicate attribute names on one element | Parsing retains all; independent validation defaults to error |
| `&` references, comments, CDATA | Recognized as unsupported in this slice |
| Processing instructions, declarations | Unsupported |
| Unclosed, mismatched or unexpected closing tags | Invalid syntax; no partial document |
| Leading UTF-16/32 byte-order markers | Unsupported encoding; no automatic conversion |

Names start with `[A-Za-z_:]` or a byte `0x80..0xFF`; subsequent bytes may also
include digits, `-`, and `.`. There is no namespace interpretation. Whitespace in
text stays intact. Space/tab/CR/LF are allowed around tag endings, but not between
`/` and `>` in a self-closing tag. Control bytes below `0x20` other than tab/CR/LF
are invalid. Ordinary text ends at `<` or `&`; no XML-conformance claim is made
for its other character-data restrictions. A leading UTF-8 BOM is skipped as
content without changing physical offsets. UTF-16/32 must be converted explicitly;
offsets then refer to the converted buffer. BOM detection does not identify every
wrong or mixed encoding.

Attribute names use the same byte grammar as element names. Values require single
or double quotes; whitespace around `=` is allowed and attributes must be separated
by whitespace. Empty values, `>`, opposite quotes and backslashes are ordinary
content; backslashes do not escape quotes. Raw `<` and forbidden control bytes are
invalid in values. `&` remains unsupported there too, pending the references slice.
Closing tags cannot have attributes. No boolean/unquoted attributes, whitespace
normalization, namespace resolution or attribute decoding is implied.

The standalone `lexer.Lexer` uses the same scanner without a tree or allocation.
Attribute-free tags are whole `open`/`close`/`empty` tokens. Attribute-bearing tags
yield `open_head`, `attribute` tokens, then `head_end` or `empty_end`. On an attribute
token, `name` is the name span and `span` is the quoted value span. Header-end tokens
cover only `>` or `/>`; retained element spans still cover the entire element.

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
        _ = node.name();     // null for text; borrowed bytes for an element
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
`=`. Text nodes return an empty attribute iterator.

`Document` is a trusted completed-parser representation, not an arbitrary document
builder. Public fields do not remove its preconditions: spans must refer to the
live source, nodes must have valid preorder/subtree intervals, and attributes must
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

Parsing checks structure; it does **not** run the duplicate-attribute check.
Validate a completed document immediately or later, under the same or a different
profile. Validation never changes the retained records or discards occurrences.

```zig
const document = parsed.document.?;
const checked = markup.validate(allocator, &document, bag.sink(), .{});
// Accept only if checked.completion == .complete and checked.validity == .valid.
```

For allocation-free validation, use
`validateIn(&document, scratch, sink, options)`. `FixedValidationScratch(n).storage()`
supplies scratch, or allocate `AttributeKeyScratch` entries explicitly.
`requiredValidationScratch(&document)` reports the largest attribute count on any
one element, or zero if all have fewer than two. Each scratch entry is 8 bytes.
Scratch cannot alias source, document pools or diagnostic storage; it is reusable
after the call. The allocator-backed `validate` frees its temporary scratch before
returning. With the check off, neither entry point inspects attributes or needs scratch.

Names match byte-for-byte and case-sensitively, scoped to a single element. Each
occurrence after the first produces one finding whose related span identifies the
first. Findings are in document order. Error findings make validity invalid but
do not stop further checks; warning findings do not invalidate. A discarded
diagnostic still affects counters and validity.

`ValidationResult` separates `completion`, `validity`, `checks.duplicate_attribute`,
`errors`/`warnings` and `diagnostic_delivery`. Check status is `not_run` when off,
`incomplete` on interruption, or `complete`. A complete off-policy result is valid
under the selected policy, **not** proof of uniqueness. Interrupted results are
`invalid` if an error was already found, otherwise `unknown`. A sink's accepted
stop ends the pass immediately with complete delivery of the discovered prefix;
rejection ends it with failed delivery. Neither implies all findings were discovered.
Insufficient scratch reports `storage_exhausted` with the required entry count;
allocator failure reports `out_of_memory`. Resource diagnostics do not replace
those causes, even if the diagnostic destination fails.
Both resource diagnostics use the name span of the first element with the largest
attribute list. For allocation failure this identifies the allocation's context,
not malformed syntax or proof that this element alone caused memory exhaustion.

This is a separate run-to-completion pass. Parsing's `execution.metering` does not
bound validation, sorting, scratch sizing or allocations. Enabled cancellation is
polled at entry, between elements and before findings, not within a sort or a name
comparison. Heap sorting uses O(A log A) comparisons per attribute group with
bytewise name comparisons, followed by linear mapping/emission in source order;
there is no second sort. Allocator-backed validation sizes scratch only once and
reuses that requirement during checking. Temporary memory is O(max attributes on one element).
Source and document pools must stay alive and unchanged, as with parsing views.

## Policies and sessions

```zig
const Reader = markup.Profile(.{
    .policy = .{ .limits = .{ .max_nesting = 64, .max_nodes = 10_000 } },
    .runtime_policy = true, // optional; defaults to false
});
const parsed = Reader.parseBorrowedIn(source, memory, sink, .{
    .policy = .{ .limits = .{ .max_nodes = 20_000 } },
});
```

| Policy leaf | Values/default |
| --- | --- |
| `limits.max_source_bytes` | u32; default `2^32 - 1` |
| `limits.max_nodes` | u32; default `2^32 - 1`; elements plus nonempty text runs |
| `limits.max_attributes` | u32; default `2^32 - 1`; every occurrence counts |
| `limits.max_nesting` | u32; default `2^32 - 1`; top-level elements have depth 1 |
| `validation.duplicate_attribute` | `err` (default), `warning`, `off`; affects validation, not parsing |
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

One credit performs at most one source-byte/EOF examination, one bounded grammar
transition, or one event attempt. Closing-name comparison reads one byte per
step, including rereads. A constant-size prefix probe can examine up to the first
four bytes across separate steps; the frontier includes lookahead. Zero budget
does no normal work, though it can observe cancellation. Credits exclude callback
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

| Outcome | Meaning |
| --- | --- |
| `success` | Whole fragment parsed under the implemented grammar |
| `invalid_syntax` | Rejected structural syntax |
| `unsupported_feature` | Recognized construct is not processed; contents unvalidated |
| `resource_limit` | Source/node/attribute/nesting policy reached |
| `storage_exhausted` | Fixed node/attribute pool or nesting frames exhausted |
| `out_of_memory` | Explicit allocator failed |
| `cancelled` | Caller stopped unfinished work |
| `sink_failure` | Private syntax consumer failed |

Current parsing is fail-fast and emits at most one terminal failure diagnostic.
Its original cause survives a diagnostic destination that stops or rejects it;
rejection sets `diagnostic_delivery = .failed`. Cancellation emits no diagnostic.
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
- `zig build bench-markup -Doptimize=ReleaseFast`: flat, mixed, text, deep and attribute
  fixtures; fixed/runtime/count-only latency and decimal MB/s, record/scratch and
  session sizes. Duplicate validation is timed separately with a discard sink and
  preallocated scratch. Storage figures are not allocator overhead or process RSS.

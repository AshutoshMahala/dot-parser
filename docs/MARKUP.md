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
| Attributes, `&` references, comments, CDATA | Recognized as unsupported in this slice |
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
    }
}
```

[Runnable example](../examples/markup.zig). `Document.records` is a source-order
preorder forest of compact `Node` records; `Document.node(id)` bounds-checks IDs.
`NodeView.span()` is an original byte range. Empty-element spelling is recoverable
from source; no implicit text/name copying or normalization occurs.

The source must stay alive and unchanged while any view uses it. An owning
`ParseResult` frees its records with `deinit()`, never its source or diagnostic
bag; do not independently dispose copies of an owning result. `Document` is a
non-owning view and has no disposal operation. Optional `scratch_allocator` in
parse options separates temporary nesting storage from retained output.

## Fixed memory and measurement

```zig
var nodes: markup.FixedDocumentStorage(16) = .{};
var frames: markup.FixedParseScratch(8) = .{};
const parsed = markup.parseBorrowedIn(source, .{
    .document = nodes.storage(),
    .scratch = frames.storage(),
}, markup.diagnostic.discard, .{});
```

This path allocates nothing. Source, node storage and any views must obey their
lifetimes; scratch may be reused after completion. Both fixed types expose
`byte_size`. Each retained node is 20 bytes and each nesting frame is 12 bytes
on the tested native/32-bit layouts. Source, bag and session memory are additional.
Self-closing elements count toward element depth but need no persistent frame.

`measureIn(source, scratch, sink, options)` uses the same grammar without retained
records. `measure(allocator, source, sink, options)` allocates only nesting scratch.
On success, `counts.nodes` is the exact node-pool capacity; `counts.max_depth` is
a safe scratch-frame capacity (possibly larger than needed for self-closing tags).
Measurement followed by parsing is two explicit passes, not caching.

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
| `limits.max_nesting` | u32; default `2^32 - 1`; top-level elements have depth 1 |
| `execution.metering` | boolean; default false |
| `execution.cancellation` | boolean; default false |

Zero limits are valid. Limits do not supply storage. A runtime patch inherits all
unspecified baseline leaves. `presets.standard` supplies the complete defaults.
`validatePolicy` is compile-time-only in fixed profiles and callable at runtime
when overrides are enabled. Every typed combination in this slice is valid, so
it returns `.valid`; parsing therefore has no policy-error union. This does not
guarantee valid input or sufficient storage. No mode/backend/check is exposed
before its implementation exists.

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
policy does not supply a hook. `cancel()`/`deinit()` terminate unfinished work.
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
| `resource_limit` | Source/node/nesting policy reached |
| `storage_exhausted` | Fixed node pool or nesting frames exhausted |
| `out_of_memory` | Explicit allocator failed |
| `cancelled` | Caller stopped unfinished work |
| `sink_failure` | Private syntax consumer failed |

Current parsing is fail-fast and emits at most one terminal failure diagnostic.
Its original cause survives a diagnostic destination that stops or rejects it;
rejection sets `diagnostic_delivery = .failed`. Cancellation emits no diagnostic.
No markup fix suggestions or independent validation pass exist in this slice.

Diagnostics use the `markup_parser` WDP namespace, with processor-owned typed
details and optional related opener spans. `code.structured()`, `compactId()` and
`qualifiedCompactId()` need no runtime hashing. The authoritative current registry
is [diagnostic.zig](../src/markup/diagnostic.zig); fixed/growable/streaming bags use
the same [shared reporting contracts](REPORTING.md) as DOT without sharing payloads.

## Verification and costs

- `zig build test-markup`: standalone unit/consumer/compile-fail tests, no DOT build.
- `zig build test`: includes coexistence with DOT and shared primitive tests.
- `zig build check-freestanding`: consumed RISC-V32/Wasm32 fixed/runtime profiles.
- `zig build examples`: includes the standalone example.
- `zig build bench-markup -Doptimize=ReleaseFast`: flat, mixed, text and deep
  fixtures; fixed/runtime/count-only latency and decimal MB/s, record/scratch and
  session sizes. Storage figures are not allocator overhead or process RSS.

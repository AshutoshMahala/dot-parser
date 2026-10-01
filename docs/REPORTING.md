# Diagnostic reporting

General-purpose callers can retain diagnostics with an explicit allocator:

```zig
var bag = dot.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = dot.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
// bag.items() is retained in emission order; inspect result for completeness.
```

`init` does not allocate. Growth occurs on demand, **bounded to 1,024 entries by
default**, for DOT, markup and shared typed bags. Choose a different limit explicitly:

```zig
var bounded = dot.GrowableDiagnosticBag.init(allocator, .{
    .max_entries = .{ .limited = 4096 }, // u16: 0 through 65,535
});
defer bounded.deinit();
var unlimited = dot.GrowableDiagnosticBag.init(allocator, .{
    .max_entries = .unlimited, // deliberately opt out of the retention budget
});
defer unlimited.deinit();
```

`reporting.EntryLimit` uses a `u16` payload for `.limited`; neither zero nor 65,535
is a sentinel. Zero rejects the first finding without allocation. Unlimited remains
subject to allocator and representation limits; slice lengths/capacities stay
`usize`, and factual finding/omission counters are not narrowed to u16.

The limit bounds retained entries and reserved array capacity, not total heap or
RSS. A 1,024-entry markup bag reserves at most 36 KiB of entries; DOT or custom
payload sizes differ. During copying growth, old and new buffers may coexist.
An arena may retain abandoned buffers until teardown. A narrower limit field
does not guarantee a smaller bag struct because of alignment/padding.
Accepting the last permitted item requests stopping. Allocation failure rejects
the current item. `reset()` clears entries but retains capacity; `deinit()` frees
the backing allocation. Views returned by `items()` expire on growth/reset/deinit.
The processor never resets or frees the caller's bag. The limit is fixed at init;
do not mutate the bag's configuration/storage fields to reconfigure it.

Sharing a bag across stages shares its remaining budget. Accepting entry 1,024
requests stopping even when it happens to be the final possible finding; callers
must inspect operation completeness, not infer it from diagnostic count. Unlimited
retention is not needed just to finish checking: a streaming or explicit omission
destination can continue without keeping every finding, but still needs a work budget.

For allocation-free use, `dot.FixedDiagnosticBag(N)` retains N entries. Its last
accepted item returns `.stop`; the zero-capacity case rejects the first item.
For explicit prefix-and-count behavior use:

```zig
var bag: dot.reporting.FixedBag(dot.Diagnostic, 8, .omit) = .{};
```

That bag continues after filling and counts omitted entries in `omitted: u64`.
An omission-counter overflow is an explicit sink failure, never wrapped telemetry.

## Streaming and typed processors

DOT's `DiagnosticSink` has a borrowed `context` and `emit_fn` returning
`DiagnosticSinkError!DiagnosticAction`. On accepting an item return `.proceed` or
`.stop`; failures distinguish `DiagnosticCapacityExceeded`, `OutOfMemory` and
`DiagnosticSinkFailure`. Context must outlive every callback. Do not reenter the
active session. `diagnostic.discard` explicitly accepts without retaining.

Shared `reporting.Sink(T)`, `reporting.FixedBag(T, N, overflow)` and
`reporting.GrowableBag(T)` work with processor-owned diagnostic types. They do not
import DOT codes/catalogs. Concrete producers can call `push()` directly; `sink()`
provides an explicit erased destination adapter. Bags copy values, not referenced
data: a custom payload's referenced bytes must outlive its retention. A combined
bag may opt into a tagged union; that cost does not affect plain DOT diagnostics.

## Stopping is not invalid input

Ordinary validation findings continue independent checks. Sink stop/failure ends
unfinished work and is not a validation verdict. Completed DOT output remains
available if validation stops. Accepted-stop can have complete delivery but
incomplete validation. A rejected diagnostic is counted as discovered, and the
delivery status is failed. Source-order merging may already have other pending
findings; those counts are retained without visiting additional input.

Terminal syntax/resource errors retain their original cause even if reporting
fails: there was already no remaining work to continue. During syntax recovery,
however, a stop ends the search for additional findings. There is no recursive
attempt to diagnose a broken sink. Terminal calls do not emit again.
Both parsers preserve `syntax_errors` and report `completion` separately from
the stop reason. Diagnostic delivery failure cannot erase a discovered error;
an incomplete pass with zero errors does not imply valid input.

Growable bags are the default in general examples, not an implicit core allocator.
Fixed-memory and streaming operation remain first-class choices.

For hostile input, also bound input acquisition, parser output/scratch and total
work. A capped bag cannot prevent a large diagnostic-free tree or work done before
the first finding. See the [markup untrusted-input recipe](MARKUP.md#untrusted-input)
and the [DOT policy guide](POLICIES.md#untrusted-input).

## Metadata and console presentation

DOT and standalone markup share the reporting primitives, WDP registry machinery
and optional console renderer. Each processor owns its `Code` enum, typed details,
namespace and wording. Neither parser imports the other; no universal payload
union or runtime registration is required.

| Facility | Shared machinery | Processor-owned part |
| --- | --- | --- |
| Identity | `wdp.Catalog(Component, Primary)` and `wdp.Registry(Code, namespace)` | Typed component/primary enums, paired sequence/alias definitions and code entries |
| Metadata | `Code.info()` shape; compile-time identity/metadata/collision checks | Static summary and hint for every code |
| Delivery | Severity, sink actions, fixed/growable/streaming destinations | Concrete diagnostic payload |
| Presentation | `presentation.Renderer(Adapter)`, options, source excerpts, colors and summaries | Compile-time `console.Adapter` supplies explanations and related-span labels |
| Repairs | `reporting.Fix(Replacement)`, applicability and `reporting.Fixes` filtering | Replacement vocabulary, safe offers and compact storage choices |

Both roots expose `wdp` and `presentation` for reuse. `Code.info()` exposes
`severity`, `component`, `primary`, `sequence`, `alias`, `summary`, and `hint`.
`structured()`, `compactId()` and `qualifiedCompactId()` are derived from that
metadata at compile time. Existing DOT/markup identity strings are unchanged.
Metadata strings are static: they are not copied into diagnostic bag entries.

Both `dot.console` and `markup.console` provide `render`, `renderBoxed` and
`renderBoxedList` with the same `RenderOptions`:

```zig
const locations = try allocator.alloc(markup.location.Location,
    try markup.console.locationCapacity(bag.items()));
defer allocator.free(locations);
try markup.console.renderBoxedList(bag.items(), 0, .{
    .source = source,
    .source_name = "example.markup",
    .style = .unicode, // or .ascii
    .color = .none, // explicit .ansi opt-in; no TTY probing
    .verbose = true, // sequence alias and qualified compact ID
}, locations, writer);
```

The second argument counts **omitted findings**, not unfinished work. Pass zero
for a growable bag, which stops instead of omitting; an explicit omission bag
supplies `bag.omitted`. Still inspect the operation's completion/delivery result.

Rendering allocates nothing and writes only through the supplied writer; writer
failures propagate to the caller. `renderBoxedList` takes caller-owned location
scratch before the writer. `locationCapacity(items)` gives a checked upper bound
in `Location` records (12 bytes each; at most four per DOT diagnostic or three
per markup diagnostic). A fixed array works equally well. Without source bytes,
pass `&.{}`. Too-small scratch returns `error.LocationScratchTooSmall` before
writing anything. Single-diagnostic renderers use bounded local scratch.
Scratch must not alias the source or diagnostics and is not retained after return.

The list renderer sorts location queries, resolves them in one forward source
pass, then preserves the original diagnostic order while formatting. For `k`
location queries and `n` source bytes, built-in location/excerpt work is
`O(n + k log k)` with `O(k)` caller scratch, not a repeated source scan per related
span. Excerpt boundary searches are bounded even on huge physical lines. No
per-line/source-sized index is allocated. Adapter callouts and writer costs are
separate; custom adapters should expose queried positions as primary, related or
fix spans. Calling individual renderers repeatedly does not share a source pass;
use the list renderer for a bag.
Locations are byte-based, including the clickable `source_name:line:column:`
location in compact `render()` output. Excerpts fall back to compact locations
when source spans do not fit. Unicode style shows printable UTF-8; ASCII style
escapes every non-ASCII byte. Both escape invalid bytes, control/format characters
(including bidi controls), line/paragraph separators and noncharacters. Leading
combining marks without a visible base are escaped as well.
File names follow the same escaping rules, with tabs escaped rather than expanded.
Ordinary paths are never truncated. Presenters can reuse
`presentation.writeSourceName(name, style, writer)` for their own summary lines.

Carets use display cells, not UTF-8 byte counts. The optional renderer uses pinned
[Unicode 17.0 width data](https://www.unicode.org/Public/17.0.0/ucd/EastAsianWidth.txt)
and [character categories](https://www.unicode.org/Public/17.0.0/ucd/extracted/DerivedGeneralCategory.txt):
wide/fullwidth scalars occupy two cells, nonspacing/enclosing marks and trailing
Hangul Jamo zero, and other printable scalars one (including ambiguous-width
characters). A finding inside a multi-byte scalar marks the whole displayed
scalar; a combining-mark finding points to its base. Tabs expand to eight-cell
stops relative to the excerpt window, and clipping never splits valid UTF-8.
This is deterministic scalar-width presentation, not grapheme/emoji shaping or
a guarantee about every terminal/font. Canonical locations and fix spans still
index the original bytes.

The cell mapping's two 65-entry `u16` maps use **260 bytes**
of bounded presentation scratch, plus local counters; Unicode tables live only
in the optional renderer. The generator in `tools/generate_console_widths.py`
prints the checked-in tables; ordinary builds require no downloads or Python.
Rendering may scan source bytes to derive locations; that is presentation work,
not parser hot-path work. A list is presented in caller-supplied order, not sorted.
An unused renderer need not be linked into the application.

DOT retains `Diagnostic.fix: ?Fix`. Markup retains a compact optional `Repair`
in `Diagnostic.fix`. Both offer `diagnostic.suggestedFix()` as a common accessor;
markup materializes its `?Fix` on demand without allocation.
The current markup offer inserts a missing reference semicolon only when the
candidate can be terminated successfully. Numeric candidates with forbidden or
out-of-range values receive no offer. An offer is always `maybe`, never proof of
intended meaning or successful later catalog validation. The `diagnostics.fixes`
policy supports `all` (default), `machine_applicable`, and `off` at both binding times. Filtering
does not alter findings, validity, delivery or source text; `.machine_applicable`
currently suppresses every markup repair. Raw low-level lexers have no policy
binding; their findings carry unfiltered offers.

Markup diagnostics remain 36 bytes on the tested native and 32-bit targets; the
offer uses existing padding. Retained trees and scratch pools do not grow.
These are checked layout observations, not a stable ABI. Repairs are suggestions:
apply them to caller-owned output, from highest offset down, then parse again.

Custom renderer adapters receive `*presentation.Positions` in `detail`, `hint`,
`note` and `primaryLabel`. `positions.slice(span)` bounds-checks source access;
`positions.writeSource(bytes, writer)` writes a bounded, escaped inline name in
the selected style. This enables source-aware wording without storing strings
in diagnostic payloads. Markup uses it to name both tags in a mismatch; absent or
truncated source keeps the generic wording. Numeric alternatives for `&nbsp;`,
`&copy;` and `&mdash;` are hints only: no catalog changes or automatic edits.

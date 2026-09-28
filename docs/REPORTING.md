# Diagnostic destinations

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

Growable bags are the default in general examples, not an implicit core allocator.
Fixed-memory and streaming operation remain first-class choices.

For hostile input, also bound input acquisition, parser output/scratch and total
work. A capped bag cannot prevent a large diagnostic-free tree or work done before
the first finding. See the [markup untrusted-input recipe](MARKUP.md#untrusted-input)
and the [DOT policy guide](POLICIES.md#untrusted-input).

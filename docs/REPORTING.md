# Diagnostic destinations

General-purpose callers can retain diagnostics with an explicit allocator:

```zig
var bag = dot.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = dot.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
// bag.items() is retained in emission order; inspect result for completeness.
```

`init` does not allocate. Growth occurs on demand; `.max_entries = N` places an
entry limit on retention and reserved capacity, not allocator overhead or RSS.
Accepting the last permitted item requests stopping. Allocation failure rejects
the current item. `reset()` clears entries but retains capacity; `deinit()` frees
the backing allocation. Views returned by `items()` expire on growth/reset/deinit.
The processor never resets or frees the caller's bag.

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

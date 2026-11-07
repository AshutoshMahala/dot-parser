# Semantic graph (IR)

> **Unreleased.** Not in 0.5.0: the whole `dot.ir` layer is new on `main`.

`dot.ir` is an optional layer above the parser. It turns a parsed DOT file into
a graph, following Graphviz's rules for names, subgraphs and attributes (with
some [known differences](#default-and-update-rules)). You get:

- **one node per name**: `a`, `"a"` and `"a" + ""` are the same node;
- **subgraphs** and the nodes in them, with a reopened named subgraph merged
  into one;
- **effective attributes**: the value each node, edge or graph ends up with
  after defaults, inheritance and later updates, and where that value came from;
- **edge statements as written**: `{a b} -> {c d}` is kept as one connection.
  Its four edges are produced only when you ask for them.

Ordinary parsing never runs this layer or allocates anything for it.

**Words used in this guide**

| Word | Meaning |
| --- | --- |
| IR | "Intermediate representation": the graph this layer builds. `Graph` for complete input, `PartialGraph` for input with errors. |
| Lowering | Building the IR from a parsed `Document`. `dot.ir.parse` does it for you; `lowerComplete` and `lowerPartial` do it for a Document you already have. |
| Connection | One written edge link and its two endpoints. `a -> b -> c` has two connections; `a -> {b c}` has one. An endpoint is a node or a set of nodes (a subgraph). |
| Expanding edges | Turning connections into individual edges (node pairs), one at a time or all at once. |
| Materializing | Expanding every edge into an array the result owns. It can also work out each edge's attributes once ("folding") and build per-node edge lists ("adjacency"). |
| Effective attribute | The final value after defaults, inheritance and later assignments. |
| Scope | The root graph or a subgraph. A named subgraph written twice is one scope. |
| Profile | A type made by `dot.ir.Lowering(config)`: compile-time choices about what the graph keeps and how its operations run. |
| Session | An operation you drive in small steps with `advance(budget)`, so you can pause, resume and cancel it. |

## Start here

```zig
fn printGraph(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const ir = result.ir() orelse return error.GraphUnavailable;

    // a and "a" are one node; x is a node with no edges.
    var nodes = ir.nodeIterator();
    while (nodes.next()) |node| std.debug.print("node {f}\n", .{node.name()});

    // Expand one edge at a time, without storing the whole edge list.
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |edge|
        std.debug.print("edge {f} {s} {f}\n", .{ edge.from().name(), edge.edge.operator.lexeme(), edge.to().name() });
}
```

This is [build_graph.zig](../examples/build_graph.zig). For
`digraph { a -> { b c }; "a" -> d; subgraph s { x } }` it prints:

```text
node a
node b
node c
node d
node x
edge a -> b
edge a -> c
edge a -> d
```

What `dot.ir.parse` does:

- It parses and validates with the default UTF-8 DOT settings, builds the graph
  if the input is accepted, and frees the parsed Document. It doesn't copy the
  source or expand edges.
- The result owns the graph. The graph borrows the source: keep the source
  bytes alive and unchanged until `result.deinit()`.
- `result.ir()` points into the result. Keep the result alive and don't move it
  while you use that pointer.
- Diagnostics go to your sink. Print them on success too: warnings don't stop
  the graph.
- `ir()` is null when DOT checking rejected the input **or stopped** (a limit,
  a stop from the diagnostic sink, a check that didn't finish). `result.checking`
  says which. It keeps the parse outcome and completion, the syntax-error,
  warning and accepted-deviation counts, the validation result, and how
  diagnostics were delivered or why they stopped. A null graph on its own
  doesn't prove the input is invalid.
- A failure while building the graph (a limit, out of memory) is returned as an
  error, and nothing stays allocated. You never get a half-built graph. For
  input with errors, use [`parsePartial`](#partial-graphs-for-editors).

**Find your task**

| I want to… | Read |
| --- | --- |
| Look up nodes and names, list subgraph members | [Nodes, names and subgraphs](#nodes-names-and-subgraphs) |
| Ask whether an edge exists, without expanding edges | [Ask about connections](#ask-about-connections-without-expanding-edges) |
| Get every edge, one at a time or as an array | [Expand edges](#expand-edges) |
| Walk the edges at each node | [Walk the edges at a node](#walk-the-edges-at-a-node) |
| Read attribute values, defaults and ports | [Read effective attributes](#read-effective-attributes) |
| Keep only topology, add indexes, read UTF-16/32 | [Choose what the graph keeps](#choose-what-the-graph-keeps) |
| Build the graph from a Document I already parsed | [Lower a Document you already have](#lower-a-document-you-already-have) |
| Build directly from DOT events without a retained Document | [Build from events](#build-from-events) |
| Show a graph while the user is still typing | [Partial graphs for editors](#partial-graphs-for-editors) |
| Use fixed buffers and no allocator | [Fixed buffers, no allocator](#fixed-buffers-no-allocator) |
| Work in small steps, pause, cancel | [Small steps and cancelling](#small-steps-and-cancelling) |
| Know the limits and what each call costs | [Limits, memory and costs](#limits-memory-and-costs) |
| Look up a call or option | [Reference](#reference) |

## Build from events

`IR.FromEvents(Dot)` is an opt-in construction route. `parse` returns a
complete graph; `parsePartial` can retain facts from broken input. Both return
the same graph types, views and queries as Document lowering.
Ordinary `dot.ir.parse` and `IR.parse` keep their Document-based implementation.

```zig
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{});
const EventIR = IR.FromEvents(Dot);

var result = try EventIR.parse(gpa, source, .{ .diagnostics = bag.sink() });
defer result.deinit();
const graph = result.ir() orelse return error.GraphUnavailable;
var nodes = graph.nodeIterator();
while (nodes.next()) |node| std.debug.print("node {f}\n", .{node.name()});
```

The result owns its graph and borrows the unchanged source. It retains no
Document. Construction stages the active root statement, including nested
subgraphs, then applies it in the same semantic order as Document lowering.
After each completed root statement, staging buffers are cleared and reused.
A giant statement can
therefore require substantial temporary storage; this route does not promise
lower memory or faster execution for every input. Edges remain symbolic.

Node-only chains avoid the nested-scope replay machinery. Large mention and
connection pools grow in pages, then copy into the ordinary contiguous graph
storage before returning; that final copy counts against work and memory limits
and checks cancellation. Growth ceilings use the remaining source length,
without another scan. These choices reduce copying but do not guarantee lower
Arena capacity on every input. See the [measured costs](PERFORMANCE.md#event-construction-versus-document-construction).

| Option | Meaning |
| --- | --- |
| `.diagnostics` | One DOT diagnostic sink, defaulting to discard |
| `.dot` | The bound DOT event parser's options: runtime policy, cancellation and source encoding when compiled in |
| `.lowering` | This IR profile's limits and execution options, independently of DOT |

Both policies are verified before work. The IR must have a reader for the
source encoding selected by DOT; no reader or transcoding is enabled implicitly.
Full/topology-only IR and optional indexes work with this route. Removing IR
attributes does not disable DOT attribute validation. Child-processor profiles
cannot be bound: the event route does not schedule markup or string processors.

`checking` includes the usual parse/validation/delivery summary and a `coverage`
field with the parser's `retained_end` and `root_closed` facts. These facts do not
certify graph validity. Syntax rejection never publishes a complete graph.
On the complete route, validation rejection or a diagnostic stop also leaves
`ir()` null. Construction limits, allocation failures, unsupported IR semantics
and cancellation use the error union; cancellation returns `error.Cancelled`
and publishes no result. Parser resource/storage failures retain their normal
checking outcomes.

### Keep partial graph facts from events

```zig
var result = try EventIR.parsePartial(gpa, source, .{ .diagnostics = bag.sink() });
defer result.deinit();
const graph = result.ir() orelse return error.GraphUnavailable;
const answer = try graph.findNode("b"); // known or unknown, just like partial Document lowering
```

Calling `parsePartial` selects partial retention; no DOT `retention.partial`
setting is required. DOT's `on_error` still controls whether parsing continues.
Under `.collect`, committed later statements survive, as do committed children
of an abandoned parent statement. That parent contributes no invented node,
edge or attributes. Skipped ranges and unfinished input become the same gaps
and qualified query answers as [partial Document lowering](#partial-graphs-for-editors).
On complete input this still returns a `PartialGraph`, with complete coverage
and known answers.
Partial construction adds bookkeeping for staged statements/scopes and retained
gaps. That bookkeeping is compiled out of the complete `parse` route.

An unfinished string or comment can stop parsing; only certified earlier facts
are retained. A rejected graph header may leave no graph at all. Cancellation,
work/memory limits, allocation failure and diagnostic delivery stops never
publish a graph from unfinished construction. Non-strict retained facts may
still have validation errors; strict admission follows the Document route.

Checks also cover certified prefixes of abandoned scoped edges, without turning
them into graph connections. Validation reports incomplete coverage for broken
input and checks encoding only through the retained frontier. The Document
`parseAndValidate` convenience can skip its validation pass after a fail-fast
syntax error; the event route has already checked earlier contributions.

### Execution and accounting

There are intentional execution differences:

- Committed attribute, operator and reference checks run during parsing;
  whole-source encoding and final-kind checks run afterward. Diagnostic order,
  and the first error under `.fail_fast`, can differ from Document checking.
  When both complete validation, applicable findings and acceptance agree.
  A later syntax error may follow validation findings already delivered by this
  route; a Document-only route without partial retention cannot validate that
  rejected Document.
- An early validation error under `.fail_fast` sets `checking.outcome` to
  `.processor_stopped`, with `.validation.outcome = .error_stopped`. It is not
  counted as a syntax error. Diagnostic stop/failure preserves the sink reason.
- IR work and memory limits cover construction, staging, validation scratch and
  indexes. DOT nesting scratch has its own parser limits. Neither limit is a
  process-RSS cap. Different allocation schedules and work totals can reach
  limits at different points.
- Parser credits are unchanged. Semantic/validation work has independent total
  accounting and cancellation checkpoints; a callback credit does not pay for
  arbitrary lowering work. Enabling metering does not make this one-shot call
  pause; use `Session` or `PartialSession` below when you need to yield.

Compare both routes with
`zig build bench-ir-events -Doptimize=fast -- --corpus /path/to/generated`.

### Build an outline alongside the graph

Bind an existing [DOT event consumer](EVENTS.md#writing-a-consumer) at compile
time, then pass its instance with the required `observer` option.

```zig
const EditorIR = IR.FromEvents(Dot).Observe(Outline);
var outline = Outline{};
var result = try EditorIR.parse(gpa, source, .{
    .observer = &outline,
    .diagnostics = bag.sink(),
});
defer result.deinit();
```

The consumer uses the same `onEvent` and `onAbort` methods and declarations as
standalone DOT events. Its observation selection, commit extents, begin
notifications, output recovery and optional scope context apply. Events arrive
before IR work for that event. An editor can retain a provisional node name
from a rejected statement and receive later commits when recovery continues.
Syntax errors still leave `result.ir()` null on this complete-construction route.
Use `EditorIR.parsePartial` to retain qualified graph facts alongside the outline.
Its internal retention is independent of the observer's `recover_statements`:
`false` gives that observer its standalone terminal abort at the first syntax
failure, while IR construction can continue under DOT `.collect`. No later
events or scope-context callbacks reach the terminated observer. Explicit
observer `.stop` or an observer error still ends the whole operation without a
published result. Coverage describes IR retention, even after observer delivery
has ended.

`result.checking.coverage` is always available, with or without `Observe` and
independently of the consumer's `coverage` declaration. Standalone DOT events
still require that declaration to expose their result coverage.

The caller owns the observer and its allocations. Keep it alive and unmoved
through `parse`; retained spans and names borrow the original source. Forwarding
adds no event log. Each forwarded delivery charges one additional IR work unit
and checks cancellation before calling the observer. Callback bodies retain the
standalone caller-owned work contract. The unobserved route uses its ordinary
builder directly.

- Returning `.stop` ends the operation with `error.ObserverStopped`.
- An observer error is returned unchanged. Its declared or inferred error set
  is included in this binding's error set.
- Either stop discards construction storage. The observer keeps what it saw,
  and the diagnostic bag keeps delivered findings.
- A failure while the event stream is active follows the ordinary abort
  lifecycle. A successful `end_document` ends that stream; later IR checking or
  publication failure is reported by `parse`. Consult the operation result
  before claiming whole-pipeline success.

With matching subscriptions and parsing settings, the delivered event and abort
sequence matches standalone DOT events up to any composition-specific stop.
IR limits and validation can stop construction earlier than standalone parsing.
The IR builder also consumes statement-begin dispatches internally even when
the observer disables them; parser credit totals can therefore differ.

### Pause event construction

`EventIR.Session` returns the same result as `parse`; `PartialSession` returns
the same result as `parsePartial`. Both use the existing IR session lifecycle.
This first implementation accepts UTF-8 and ASCII source. UTF-16/32 remain
available through the one-shot event calls, not these sessions.

```zig
const Dot = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } });
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
const EventIR = IR.FromEvents(Dot);
var session = try EventIR.PartialSession.init(gpa, source, .{
    .diagnostics = bag.sink(),
});
defer session.deinit();
while (session.advance(256).outcome == null) {
    // Return to your scheduler here; keep the source and observer alive.
}
var result = try session.takeResult();
defer result.deinit();
const graph = result.ir() orelse return error.GraphUnavailable;
```

A grant covers scanning, event dispatch, staging, validation, semantic replay,
allocation-copying and final indexes. Long names, duplicate-attribute checks and
nested statements have bounded continuations. There is no measuring pass or
hidden Document. Initialization verifies policies and source selection without
scanning the document or allocating pools.

| Member | Meaning |
| --- | --- |
| `advance(budget: u32)` | Consumes at most that many combined credits; metering must be enabled in both profiles |
| `run()` | Runs to a terminal outcome, including with metering disabled |
| `Progress.work_used`, `.total_work` | Work in this call and over the operation; `run().work_used` saturates at `maxInt(u32)` |
| `.phase` | Next work: `parse`, `stage`, `validate`, `replay`, `finalize` or `terminal`; phases can alternate |
| `.source_frontier` | How far scanning reached; not a finalized-graph frontier |
| `.outcome` | `success` (graph available), `rejected` (result available with no graph), or `failure` carrying the binding's typed error |
| `takeResult()` | Transfers the owning result once; `NotReady` before completion, `AlreadyTaken` after transfer, or the operational failure |
| `cancel()` | Stops the entire operation even when hook polling is disabled; terminal outcomes latch |
| `peakBytes()` | Peak live requested allocation bytes, including bounded DOT nesting scratch; excludes source and inline session state |

`success` for a partial session means graph construction succeeded; inspect
`checking` and graph coverage for source validity/completeness. A rejection
retains its checking summary and diagnostics, but an operational failure never
publishes a graph. Fixed profiles without both metering capabilities reject
`advance` at compile time; runtime policies resolve once at initialization and
return `MeteringDisabled` from `advance` if either phase disabled it.

Cancellation stays independently configured in `.dot` and `.lowering`. Supply
the same request to both for whole-job cancellation. Enabled hooks are checked
on every public resume, including zero grants, and at their own intervals during
their phase's work. A hook can call its session's `cancel()` and return false;
no further work follows that cancellation. Other callback reentry into the
session is unsupported. Keep the session unmoved during a call; source, callback
contexts and an optional observer remain borrowed until completion/deinit.

Sessions charge observer delivery through the parser's existing dispatch credit,
then drain the single-event mailbox before stepping the parser again. They do
not add an event log. With `Observe`, forwarding still precedes IR work, and
observer recovery remains independent of partial retention. Pause previews are
queued only at actual `advance` boundaries, and their later delivery costs a
credit. `run()` does not manufacture previews at private scheduling steps.
Diagnostic order and work totals can differ from the one-shot route; semantic
results and source coverage follow the same rules. IR `max_work` covers
construction and validation; it does not silently absorb the parser's credits.
Session `max_bytes` also covers its growing nesting scratch.

One-shot and session paths have different speed and peak-memory costs; final
graph storage is the same. See the [measured session overhead](PERFORMANCE.md#shared-budget-event-construction), or compare them with
`zig build bench-ir-event-sessions -Doptimize=fast`.
Fixed event-construction storage and native-encoding event sessions remain future
work. Existing fixed-storage Document lowering remains available.

## Nodes, names and subgraphs

### One node per name

Nodes are identified by their **logical name**: the value left after DOT's
quoting is undone (quotes, escaped quotes, `+` joins, and the outer `<...>` of
an HTML-like name). `a`, `"a"` and `"a" + ""` are one node. There is no case
folding, Unicode normalization, number normalization (`1` and `1.0` are
different nodes) or HTML entity expansion. If a UTF-8 profile accepted invalid
bytes, the name keeps those bytes.

`try ir.findNode("a b")` takes the logical name as UTF-8 bytes, not a DOT
spelling, and returns `?NodeId`. It finds `"a b"`. Hash matches are always
confirmed by comparing the names.

### Reading names

| Call | Gives |
| --- | --- |
| `node.name()` | A formatter for `{f}` that prints the logical name |
| `try ir.nodeName(id)` | The same formatter for a node ID; checks the ID |
| `try ir.nodeSpelling(id)` | The first written spelling, in the source's encoding, with quotes and `+` |
| `try ir.writeNodeName(id, writer)` | Writes the logical name to a writer |
| `try ir.writeNodeNameWith(id, writer, options)` | The same, with [limits and cancellation](#passing-limits-and-cancellation) |

- UTF-16 and UTF-32 names are written as UTF-8. UTF-8 and ASCII names keep
  their bytes.
- Nothing is escaped for an output format, and HTML entities are not expanded.
- Nothing is allocated or cached. Decoding happens while printing.
- `{f}` and `writeNodeName` follow ordinary writer rules: writer errors pass
  through, there is no IR work budget, and a failed write may have written a
  prefix. Use `writeNodeNameWith` for a limited or cancellable write.

### Order

- **Nodes** are in order of first appearance, including a left endpoint seen
  before a subgraph endpoint. `nodeIterator()` follows this order. It allocates
  nothing and needs no `deinit`.
- **Connections** are in the order DOT runs them: connections inside an
  endpoint subgraph come before the edge statement that contains it. So node
  order and connection order can differ.
- Source ranges are byte offsets in the original source.

### Subgraphs and membership

- Named subgraphs with the same name under the same parent are one scope.
  Anonymous subgraphs are always separate. `ScopeId.root` is the graph itself.
- Each written body `{ ... }` is an **occurrence**. Each occurrence has a
  `Membership` handle: a read-only snapshot of the scope's members at that
  point. Reopening the subgraph later doesn't change an earlier snapshot.
- Edge endpoints are taken after the whole edge statement has run. In
  `subgraph s { a } -> subgraph s { b }`, both ends contain `a` and `b`.
- `try ir.scopeMembership(scope)` gives the final snapshot.
  `try ir.contains(membership, node)` checks one node.

### The stored tables

A `Graph` keeps these arrays. They are read-only, and every ID indexes into
them.

| Field | Holds |
| --- | --- |
| `nodes` | `Node`: name range, first mention, hash |
| `scopes` | `Scope`: parent, optional name range, first occurrence |
| `occurrences` | `Occurrence`: scope, parent occurrence, source range, membership |
| `mentions` | `Mention`: each written node reference, its source range and occurrence |
| `connections` | `Connection`: two `Endpoint`s (membership and `PortId`), written and effective operator, operator range, occurrence, raw attribute range |
| `attributes` | The written attributes, including `key=value` statements |
| `declarations` | Node statements, `node`/`edge`/`graph` defaults and graph assignments, in the order they run |
| `endpoint_ports` | Written edge-endpoint ports, one per ported endpoint; a chain's middle endpoint shares one |
| `strict`, `kind`, `declared_kind`, `name` | The graph header |

- `ir.text(range)` returns the source bytes of a range from this graph, like
  `Document.text`.
- `connection.left.portSyntax(ir)` (or `.right`) returns the written port of an
  endpoint, or null.
- IDs (`NodeId`, `ScopeId`, `ConnectionId`, `Membership`) and `Edge` records
  belong to one graph. Don't make them up or mix graphs. Public calls check that
  a handle is in range (`error.InvalidHandle`), but an in-range ID from another
  graph can't be detected.
- `PartialGraph` doesn't expose these arrays; use its views and counts.

## Ask about connections without expanding edges

`{ a b } -> { x y }` is stored as one connection, not four edges. A set endpoint
points at shared mention ranges and a scope snapshot; a single-node endpoint
holds its node ID. These calls answer questions straight from the connections:

```zig
const from = (try ir.findNode("a")) orelse return error.MissingNode;
const to = (try ir.findNode("c")) orelse return error.MissingNode;
std.debug.print("a -> c: {}\n", .{try ir.hasEdge(from, to)});
```

| Call | Answers | Cost |
| --- | --- | --- |
| `hasEdge(from, to)` | Does any connection cover this pair? Undirected connections count both ways. | Scans the connections, or uses the [connection index](#optional-query-indexes) |
| `hasEdgeWith(from, to, options)` | The same, with limits and cancellation | The same |
| `contains(membership, node)` | Is the node in that snapshot? | Per-node posting list and a binary search per body range |
| `scopeMembership(scope)` | The scope's final snapshot | Scans occurrences from the end, or uses the [scope index](#optional-query-indexes) |

- None of these allocate or build edges. A 50,000 × 50,000 set product is
  searched without making its 2.5 billion edges.
- `contains` and `scopeMembership` take no options; they use the limits the
  graph was built with.
- Asking `scopeMembership` for every scope can be quadratic without the index.
- For a search you want to pause, use a
  [query session](#edge-and-membership-queries-in-small-steps).

## Expand edges

### One edge at a time

`ir.edgeIterator(options)` streams edge views without keeping an edge array.
The [Start here](#start-here) example uses it. An edge view has `.edge` (the
`Edge` record: `from`, `to`, `operator`, `first_connection`), `from()` and
`to()` node views, and attribute access.

- `next()` returns an edge, null at the end, or an error. An error is final:
  later calls return the same error, not null.
- You can `break` early. Always call `deinit()`; it frees the scratch without
  visiting the rest. Don't copy a live iterator.
- Edges already returned stay usable after a failure, but they are only a
  prefix. If you need all or nothing, collect them yourself or use
  [`materialize`](#all-edges-in-an-array).
- One `next()` can do a lot of work before it returns: skip strict duplicates,
  or read a whole endpoint set. It can be stopped between edges, but it is not a
  fixed amount of work per call. For that, use an
  [edge session](#stream-edges-in-small-steps).
- Order: connections in the order they run, endpoint members in first-mention
  order. Streaming and materializing give the same edges in the same order.
- Memory: scratch is allocated on first need. Single-node non-strict endpoints
  need none. Set endpoints reuse two member buffers and one `u32` mark per node,
  sized to the largest endpoint seen, never to the product. Strict graphs also
  remember every emitted pair (two `u32` node IDs each, plus a hash table), so
  strict streaming is **not** constant memory. `edges.peakBytes()` reports the
  peak.

### Strict graphs, parallel edges and orientation

- **Non-strict:** every written occurrence is its own edge, including parallel
  edges between the same nodes.
- **Strict:** one edge per pair. Directed pairs are ordered; undirected pairs
  aren't. The edge keeps the first covering connection's orientation and
  `first_connection`. Later connections still update its attributes.
- Ports don't change edge identity.
- Every written contribution stays in `ir.connections`.
- Lowering rejects, with `error.UnsupportedSemantics`, a strict graph whose kind
  is mixed (generic) or that keeps an operator that doesn't match its kind.
  Non-strict mixed graphs keep both edge kinds.

### All edges in an array

```zig
var graph = try ir.materialize(.{ .attributes = false });
defer graph.deinit();
for (graph.edges) |edge| {
    std.debug.print("{f} -> {f}\n", .{ try ir.nodeName(edge.from), try ir.nodeName(edge.to) });
}
```

- `.attributes = false` gives a `dot.ir.MaterializedTopology` that owns
  `edges: []const Edge`. The IDs refer to `ir`: keep `ir` to read names.
- The default, `materialize(.{})`, also folds every edge's attributes. See
  [read edge attributes in bulk](#read-edge-attributes-in-bulk).
- `.adjacency` adds per-node edge lists. See
  [walk the edges at a node](#walk-the-edges-at-a-node).
- It's all or nothing. Success returns every edge. Any failure frees the output
  and returns the error. A connection whose product is over the pair limit is
  rejected before its edges are allocated.
- Strict deduplication uses a collision-checked pair table that indexes the
  output itself; there is no second edge list.
- `.attributes` and `.adjacency` are compile-time values because they change the
  result type. `.limits` and `.cancellation` are runtime values. Unknown fields
  are compile errors.
- `graph.retainedBytes()` is the output's allocated size. `graph.peak_bytes`
  also counts temporary growth and scratch, but not `ir`.

### Walk the edges at a node

Ask for adjacency when you need the edges at each node. It is off by default,
and parsing and lowering never build it.

```zig
var graph = try ir.materialize(.{ .adjacency = .all });
defer graph.deinit();

var nodes = graph.nodeIterator();
while (nodes.next()) |node| {
    std.debug.print("{f}: {} incident edges\n", .{ node.name(), node.edgeCount(.{}) });
    var edges = node.edges(.{ .direction = .forward });
    while (edges.next()) |entry|
        std.debug.print("  forward to {f}\n", .{entry.neighbor().name()});
}
```

This is [graph_adjacency.zig](../examples/graph_adjacency.zig). Each entry has:

- `entry.neighbor()`: the node at the other end;
- `entry.edge()`: the edge, with its stored `from()`/`to()`, attributes and ports;
- `entry.directions()`: `incoming`, `outgoing` and `undirected` flags relative
  to this node. A directed self-loop is both incoming and outgoing, but appears
  once per walk.

Parallel edges stay separate, and neighbors are not deduplicated.

| `node.edges(.{ .direction = … })` | Includes |
| --- | --- |
| `.all` (default) | Every incident edge |
| `.outgoing` | Directed edges leaving the node |
| `.incoming` | Directed edges entering the node |
| `.undirected` | Undirected edges touching the node |
| `.forward` | Outgoing and undirected edges |
| `.backward` | Incoming and undirected edges |

In an undirected graph, `.forward`, `.backward` and `.all` give the same edges,
and the directed-only filters are empty. `node.edgeCount(options)` uses the same
filters and counts a loop once; it is an edge count, not graph-theory degree.

Choose the storage your queries need. A filter the storage can't answer is a
compile error, including `.all` on forward-only storage.

| `.adjacency =` | Filters you can use |
| --- | --- |
| `.none` (default) | None; the ordinary result types |
| `.forward` | `.outgoing`, `.undirected`, `.forward` |
| `.backward` | `.incoming`, `.undirected`, `.backward` |
| `.all` | All |

- Every node view you reach from the result has adjacency: `nodeIterator()`,
  `nodeView(id)`, `entry.neighbor()` and `edge.from()`/`to()`. With `.all`,
  `entry.edge().to().edges(.{})` keeps walking.
- `Graph.MaterializedFor(.{ .attributes = …, .adjacency = … })` names the result
  type.
- `.attributes` stays independent. With `.attributes = false`, edge attributes
  are read the compact way (if the graph keeps attributes). Attribute sessions
  accept adjacency views.
- **Cost:** building takes O(nodes + edges) work. `next()` and `edgeCount()` do
  O(1) work and allocate nothing; walking keeps materialized-edge order.
- **Memory:** with N nodes, E edges, U undirected non-loop edges and L loops,
  forward or backward storage has E + U entries and `.all` has 2E − L, each a
  `u32` edge index. Offsets take C × (N + 1) `u32`s, where C is the number of
  non-empty edge categories (at most three for one direction, four for `.all`).
  A purely undirected graph shares one table for both directions. Isolated
  nodes still get offsets.
- `max_bytes`, `max_work` and cancellation cover expansion and adjacency
  together; `max_pairs` counts expanded pairs, not adjacency entries.
- The result borrows `ir` and its source, even without attributes, because node
  views need names. Keep it unmoved while its views or iterators are in use.
- On a [partial graph](#partial-graphs-for-editors), adjacency covers the edges
  that were kept. `edgeCount()` returns `Knowledge(u32)`: unknown when input is
  missing, with the kept count as the candidate. A failure returns no result,
  even if expansion finished before adjacency failed.

## Read effective attributes

### One attribute

```zig
// digraph { node[color=red]; a; node[color=blue]; b; a[shape=box] }
const node = try ir.nodeView((try ir.findNode("a")).?);
if (node.attribute("color")) |color| {
    std.debug.print("color={f}\n", .{color}); // red: the default when a was created
}
```

- Get views with `ir.nodeView(id)`, `ir.scopeView(id)` (`.root` is the graph)
  and `ir.edgeView(edge)`. Iterators already return views.
- **Node and scope** `attribute(key)` can't fail. It uses the key index and a
  balanced map: no history scan, no allocation, no work budget. Use
  `attributeWith(key, options)` for limits and cancellation.
- **Edge** `attribute(key)` on a streamed edge needs `try`: it resolves
  contributions across connections. A non-strict edge reads its own connection
  and its creation defaults. A strict edge scans the connections (or uses the
  [connection index](#optional-query-indexes)). Repeated per-edge queries can
  cost edges × connections; for bulk reads, [materialize](#read-edge-attributes-in-bulk).
- Keys are case-sensitive logical UTF-8 names, like `findNode`.
- ID-based calls return the details directly: `nodeAttribute(id, key)`,
  `scopeAttribute(id, key)`, `edgeAttribute(edge, key)` and their `With` forms
  return `?ResolvedAttribute`. `ir.attributeValue(resolved)` gives its value.
  Edge lookups need an `Edge` from iteration or materialization, not just a node
  pair, so they can't pick the wrong parallel edge.
- An attribute view has `.key()` (a formatter), `.value()` (a
  [value view](#values-spelling-operands-and-joined-text)) and `.resolved` (the
  [details](#what-a-result-tells-you)). `{f}` on the view prints the value.
  `{?f}` on an optional view prints `null` when the key is absent and nothing
  for an empty value.

### All attributes of a node, subgraph or edge

```zig
var nodes = ir.nodeIterator();
while (nodes.next()) |node| {
    var attributes = try node.attributes(.{});
    defer attributes.deinit();
    while (try attributes.next()) |attribute|
        std.debug.print("node {f}: {f}=\"{f}\"\n", .{ node.name(), attribute.key(), attribute.value() });
}
```

This is [graph_attributes.zig](../examples/graph_attributes.zig). For
`node [color=red]; a; node [color=blue]; b; a [shape=box]` it prints
`a: color="red"`, `a: shape="box"`, `b: color="blue"` and `b: shape=""`.

- You get **one final value per key**, in the order keys were first written for
  that kind of object (not alphabetical). Inherited defaults and implicit empty
  values are included, even when the key was written on another object. Repeated
  assignments are not; read `ir.attributes` and `ir.declarations` for history.
- For edges, written keys come first, then `tailport` and `headport` if only
  endpoint ports introduced them.
- `next()` returns an entry, null at the end, or an error. Limits and
  cancellation count across the whole iterator; an error is final and repeats.
- Always `deinit()`, also on early exit or error. Don't copy a live iterator.
  Entries borrow the graph and source, not the iterator, so they stay usable
  after `deinit()`.
- Node, scope and non-strict edge iteration allocate nothing. A strict edge
  scans its contributions once before the first entry. If it has explicit
  assignments, it uses a table of 12 bytes per distinct edge key in the graph,
  bounded by `max_bytes` and reported by `peakBytes()`. Endpoint sets are never
  expanded.
- Root graph attributes: `(try ir.scopeView(.root)).attributes(.{})`.

### What a result tells you

On a view, these fields live under `.resolved`; the ID-based calls return the
`ResolvedAttribute` itself.

| Result | Meaning |
| --- | --- |
| `null` | The key was never introduced for that kind of object (graph, node or edge) |
| `.kind = .explicit` | An explicit assignment supplies the final value |
| `.kind = .inherited` | A creation-time default or the parent graph's snapshot supplies it |
| `.kind = .derived` | An endpoint port supplies an effective `tailport` or `headport` |
| `.kind = .empty` | The key exists, but DOT gives this object an implicit empty value |

- `.value` is `.written` (a source range), `.port` (a reference to an
  endpoint's port syntax) or `.empty`. An explicit `color=""` is `.explicit` with
  `.value = .written`. A language-defined empty is `.value = .empty`; no source
  range is made up.
- `.attribute` is an index into `ir.attributes`. It is null for port-derived
  values and the empties they introduce; `.port_key` names those.
- `.origin` is the declaration, the connection, or the written left/right port
  endpoint (`.written_left_port`, `.written_right_port`) that supplied the
  value. Port sides name the written statement; tail and head follow the stored
  edge. `.scope` is that origin's scope.
- For an implicit empty, these name the assignment that first introduced the
  key (or the first port that did), not an assignment of an empty string.
- A chain shares one written attribute list, but an explicit edge result names
  the link that applies.
- Key and value ranges keep quotes and HTML-like delimiters, as source byte
  offsets.
- No Graphviz renderer defaults (such as a default `shape`) are added.

### Default and update rules

- Node and edge defaults apply when the object is created. Changing a default
  later doesn't change existing objects. Introducing a new key gives existing
  objects without it an implicit empty value.
- A later explicit assignment updates only the keys it names. Within one list,
  the last value of a repeated key wins.
- A subgraph takes a snapshot of its parent's **graph attributes** when it is
  first created; reopening it doesn't refresh that snapshot. Node and edge
  defaults are different: a subgraph sees the parent's current defaults unless it
  overrides them, and new objects use those current defaults. Existing objects
  keep their creation-time values.
- A strict edge uses the first covering connection's defaults, then applies
  explicit contributions in the order they run, including overlapping endpoint
  sets and reversed undirected statements. There is no priority by specificity.
- Non-strict parallel edges are independent.

These rules are compared with Graphviz on focused cases; this is not full cgraph
compatibility. Graphviz 16.1.0 differs in these known cases:

| Case | This IR | Graphviz 16.1.0 |
| --- | --- | --- |
| Edge `key` | An ordinary attribute | cgraph treats `key` as part of edge identity: repeated non-strict keys, a strict statement with a different key (dropped by cgraph) and `edge [key=x]` (ignored by cgraph) all differ |
| Undirected set products after earlier node declarations | First-mention endpoint order sets the stored orientation | Node creation order can pick the opposite orientation and port side |
| New grandchild of a reopened subgraph | Inherits its parent's stored graph-attribute snapshot | Can see a later ancestor value despite the parent's older one |
| `<a>` versus `a` or `"a"` as a node or subgraph name | Merged by logical contents | HTML-like and text names can be distinct |

The IR keeps spellings, contributions and origins, so you can apply these cgraph
rules yourself if you need them.

### Values: spelling, operands and joined text

```zig
var nodes = ir.nodeIterator();
while (nodes.next()) |node| {
    const label = node.attribute("label") orelse continue;
    const value = label.value();
    // raw() is the original spelling, in the source's encoding (UTF-8 here).
    std.debug.print("kind: {t}\nraw: {s}\njoined: {f}\n", .{
        value.kind(), value.raw() orelse "(implicit empty)", value,
    });
    var parts = value.parts();
    while (parts.next()) |part|
        std.debug.print("{t} operand: \"{f}\"\n", .{ part.kind(), part });
}
```

This is [graph_values.zig](../examples/graph_values.zig). For
`a [label="first " + "second"]` it prints kind `concatenation`, the raw
spelling, the joined text `first second` and two string operands. For
`b [label=<<b><i>bee</i></b>>]` it prints kind `markup` and one markup operand.

A value has one or more **operands**: the quoted, bare, numeral or HTML-like
pieces that `+` joins. Reading or printing a value never rewrites its spelling
or parses its markup.

| Value call | Gives |
| --- | --- |
| `kind()` | `.string` (numerals too), `.markup` or `.concatenation`; reads only the first operand, nothing stored |
| `raw()` / `span()` | The whole original spelling or byte range, with wrappers and `+`; null for an implicit empty |
| `encoding()` | The source's encoding and byte order, including ASCII |
| `parts()` | An operand iterator; `next()` can't fail, nothing allocated |
| `{f}` / `writeLogical(writer)` | The joined logical text; only writer errors |
| `toString(allocator)` | The joined text as owned bytes; you free them |
| `kindWith`, `partsWith`, `writeLogicalWith`, `toStringWith` | The same with [limits and cancellation](#passing-limits-and-cancellation) |

**Operands.** Each operand has `kind()` (`.string` or `.markup`), `raw()`,
`span()`, `innerSpan()`, `encoding()`, `form()` (bare, numeral, quoted or html),
`{f}` and `writeLogical[With]`. A value that isn't a concatenation has one
operand. An implicit empty value has one string operand with null spans and
form. Written `""` and `<>` have real spans and different kinds. Concatenation
keeps every operand, including empty ones and mixed forms.

**Markup operands.** `part.fragment()` is null for strings. For a markup operand
it returns `EncodedFragment { input, encoding }`: the inside of the `<...>`
(exactly one DOT angle pair removed), with its original file offset. Pass it to
a compatible [markup profile](MARKUP.md) yourself (with `.encoding` for UTF-16
or UTF-32 input) to read the tags. Nothing is processed automatically.

**Joined text** removes DOT operand wrappers, `+`, quoted line continuations and
quote escapes. It keeps markup tags, entity spellings, unknown DOT escapes and
number spellings: DOT `"a&amp;b"` stays `a&amp;b`. There is no text extraction,
HTML escaping, rendering or `\N` substitution. UTF-16 and UTF-32 are written as
UTF-8; UTF-8 and ASCII bytes are kept.

**Costs.** Ordinary access is unmetered, not constant time. The `With` forms
charge the source bytes they read or skip (including repeated look-ahead) and the
bytes they write, before doing the work, and check cancellation inside long
operands: a hook can be called as often as once per source code unit, so keep it
cheap. Writer calls and allocation can't be interrupted. A `partsWith` budget
covers the iterator's whole life; its errors are final and repeat, and it needs
no `deinit()`. `toString` makes two passes (count, then write) and one exact
allocation; both passes share the budget, and on failure nothing is returned.
Writer-based calls may have written a prefix when they fail.

### Endpoint ports

Endpoint ports (`a:p:n`) count as effective `tailport` and `headport` edge
attributes. The written syntax is kept, and no fake assignments are added to
`ir.attributes`.

| Input | Effective result |
| --- | --- |
| `a:p:n -> b:q` | `tailport = "p:n"`, `headport = "q"` |
| `a:p -> b [tailport=q]` | The explicit `tailport=q` wins over the port |
| `strict digraph { a:p -> b:q; a -> b:r }` | Tail stays `p`; head becomes `r` |
| `strict graph { a:p -- b:q; b:r -- a:s }` | In the first edge's `a`–`b` orientation: tail `s`, head `r` |
| `strict graph { a:p -- b:q; b:r -- a:s [tailport=x] }` | Tail `x`, head `r`; explicit attribute names are not swapped |
| `a:p -> {}` | No edge, so no port attribute is introduced |

- Order: creation defaults, then ports, then the contribution's explicit
  attributes. Strict updates keep values they don't mention.
- Only ports are mapped to the first edge's orientation. On a self-loop, the left
  and right ports stay tail and head.
- In a chain, a middle endpoint's port applies to both links next to it.
- Port names are case-sensitive logical DOT names. They aren't parsed as markup
  or checked as compass points. A lone `:n` stays the string `n`.
- A port-derived value has `.kind() == .string`, `.value = .port` and one string
  operand. `raw()`/`span()` cover from the first port name through the second,
  including quotes, `+`, comments and the colon between, but not the node or the
  leading colon. `{f}`, `writeLogical` and `toString` join the parts with `:`.
  Its operand has null `form()`, `innerSpan()` and `fragment()`, even for `a:<p>`.

`edge.tailPort()` and `edge.headPort()` return small views of the **same
winners** as `attribute("tailport")` and `attribute("headport")`. Tail belongs to
`edge.from()` and head to `edge.to()`. They need `try` on streamed edges and
can't fail on materialized ones; `tailPortWith(options)` and
`headPortWith(options)` add limits. `null` means the key is absent; an empty
value is a view. The view's `.resolved` keeps the kind and origin, and `.value()`
gives the value view.

There are two readings of a port:

| Call | Gives |
| --- | --- |
| `port.syntax()` | The winning endpoint's written port, or `null` for an attribute, default or implicit empty |
| `syntax.first()` / `syntax.second()` | The first name and the optional second name, each kept whole |
| `syntax.spans`, `syntax.raw()`, `syntax.span()` | Source byte ranges, and the whole written port with everything between |
| `syntax.compass()` | `.absent`, `.recognized` (a `dot.ir.Compass`) or `.unrecognized` (the text) for the second name |
| `port.graphvizParts()` | The effective value split at its **first** colon, the way Graphviz reads it |
| `parts.name()` / `parts.compassText()` | The text before the colon, and the optional text after it; an empty suffix is not an absent one |
| `parts.compass()` | Compass status of the text after the colon |
| `syntax.first().asCompass()` / `parts.asCompass()` | A compass candidate, **not** layout resolution; `parts.asCompass()` only when there is no colon |

For `a:"x:y":n`, the syntax keeps `x:y` and `n`; the Graphviz reading gives
`x` and the unrecognized suffix `y:n`. For `tailport="x:y:n"` only the Graphviz
reading exists, because there is no written endpoint port.

```zig
if (try edge.tailPort()) |port| {
    if (port.syntax()) |syntax|
        std.debug.print("written first name: {f}\n", .{syntax.first()});
    const parts = port.graphvizParts();
    std.debug.print("name: {f}, compass text: {?f}\n", .{ parts.name(), parts.compassText() });
}
```

- Compass names are case-sensitive: `n`, `ne`, `e`, `se`, `s`, `sw`, `w`, `nw`,
  `c` and `_` (`.automatic`). Graphviz prefers a shape-defined port named `n`
  over the compass point; these helpers don't look at shapes. A missing second
  part stays missing.
- `<p>` in a port is the name `p`, not markup.
- Text views have `{f}`, `writeLogical(writer)` and
  `writeLogicalWith(writer, options)`. They re-read the value each time; their
  positions are not source spans. Nothing is allocated or cached.
- Splitting and compass checks read one value, can't fail by default, and have
  `graphvizPartsWith`, `compassWith` and `asCompassWith` for limits. Each `With`
  call has its own budget.
- Every way of reading agrees: compact queries, iteration and materialization.
  A port-only key introduced on one edge gives other edges an implicit empty.
  Compact lookups that find these empties may inspect other ported connections
  under the same limits; they don't allocate or expand products.
- This resolves endpoint values only. It doesn't parse labels, check that a
  named port exists, or compute geometry. Every connection keeps its written
  ports even when an explicit attribute overrides them.

### Read edge attributes in bulk

`materialize(.{})` expands every edge and works out each edge's attributes once,
in one forward pass:

```zig
var graph = try ir.materialize(.{});
defer graph.deinit(); // Before releasing ir or its source.
var edges = graph.edgeIterator();
while (edges.next()) |edge| {
    std.debug.print("{f} -> {f}: color={?f}, label=\"{?f}\"\n", .{
        edge.from().name(), edge.to().name(), edge.attribute("color"), edge.attribute("label"),
    });
}
```

This is [materialized_attributes.zig](../examples/materialized_attributes.zig).

- Building can fail; reading can't. `edge.attribute(key)`, `tailPort()`,
  `headPort()` and `edge.attributes()` are indexed lookups that never scan
  history or expand sets. The attribute iterator allocates nothing and needs no
  `deinit`. `attributeWith(key, options)` and `attributesWith(options)` add
  limits; the latter counts across all `next()` calls and repeats its error.
- Results are the same as compact queries: the same `edges` records, order,
  orientation, values, ranges and origins as `.attributes = false`, and the same
  key order with implicit empties.
- The pass applies every connection's explicit assignments to the pairs it
  covers, strict duplicates included. An existing strict edge keeps its creation
  defaults.
- The result owns its edge array and its per-edge winners. It borrows the
  default snapshots, keys, values and origins from `ir`: keep `ir` and its source
  alive, unchanged and unmoved, and the result unmoved while its views are in
  use. Attribute and value views borrow only `ir`.
- Only materialization builds these maps; parsing, lowering and streaming don't.
  Folding costs time and memory up front. If you only need connectivity, or a
  few reads, `.attributes = false` with compact queries can be cheaper.
- Defaults are shared. Each edge stores only its explicit or port-derived
  winners, and repeated updates to a key reuse its cell. `max_attribute_states`
  bounds those winner cells.
- `.attributes` defaults to what the graph keeps (`true` on the default profile).
  `true` returns `IR.Graph.Materialized`; `false` returns
  `dot.ir.MaterializedTopology` and adds no folding code. Requesting attributes
  the graph doesn't keep is a compile error.

## Choose what the graph keeps

`dot.ir.Lowering(config)` makes a profile. `dot.ir.parse` uses
`dot.ir.Lowering(.{})`.

| `dot.ir.Config` field | Default | Effect |
| --- | --- | --- |
| `capabilities.attributes` | `true` | Keep attributes, defaults and effective values. `false` keeps only topology. |
| `indexes.connections` | `false` | Build an index that speeds up `hasEdge` and strict edge attribute queries |
| `indexes.scope_memberships` | `false` | Store each scope's final membership |
| `source_encodings` | `null` (UTF-8) | Readers to compile in; see [other source encodings](#other-source-encodings) |
| `limits` | `dot.ir.Limits{}` | Baseline [limits](#limits) for this profile's lowering |
| `policy.execution.metering` | `false` | Allow `advance(budget)` on this profile's sessions; see [small steps](#small-steps-and-cancelling) |
| `policy.execution.cancellation` | `false` | Honor a cancellation hook |
| `policy.execution.cancellation_interval` | `1` | Most work steps between hook calls; must be positive |
| `runtime_policy` | `false` | Let each call override `policy` with a `.policy` option |

- `capabilities`, `indexes` and `source_encodings` change the graph type.
  Policies and limits don't: graphs from profiles that differ only in those are
  the same type. So a graph from `dot.ir.parse` works with a metering profile's
  sessions, as in [resumable_attributes.zig](../examples/resumable_attributes.zig).
  `IR.capabilities`, `IR.Graph.capabilities` and `IR.Graph.indexes` report the
  choice. `IR.Node` and `IR.Connection` are this profile's record types;
  `dot.ir.Node` and `dot.ir.Connection` describe the default profile.
- Every profile has its own `IR.parse` and `IR.parsePartial`. They work like the
  module calls, with this profile's representation, limits and policy. The
  profile's `source_encodings` also picks the DOT reader; other DOT settings are
  the defaults. For other DOT settings, [lower the Document
  yourself](#lower-a-document-you-already-have).
- Options for `IR.parse`: `.diagnostics` (default: discard), `.dot` (the DOT
  `CheckOptions`, including `.encoding` for native-encoding profiles) and
  `.lowering` (`.limits`, plus `.cancellation` when the profile enables
  cancellation and `.policy` when it allows runtime overrides). Parsing and
  lowering have separate limits; there is no shared budget.
- A hook never turns cancellation on by itself. On a profile, enable
  `policy.execution.cancellation` first. Without it, passing a hook is a compile
  error; with `runtime_policy` and cancellation turned off, the hook is ignored.
  The module-level `dot.ir.parse` and `parsePartial` are the exception: their
  `.lowering.cancellation` hook is always honored.

### Topology only

```zig
const Topology = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
var result = try Topology.parse(gpa, source, .{ .diagnostics = sink });
defer result.deinit();
const graph = result.ir() orelse return error.GraphUnavailable;
var edges = try graph.edgeIterator(.{});
defer edges.deinit();
while (try edges.next()) |edge|
    std.debug.print("{f} -> {f}\n", .{ edge.from().name(), edge.to().name() });
```

The graph keeps nodes, scopes, mentions, connections, written ports and partial
coverage, and drops attributes, declarations, keys, defaults and effective maps.
Disabled record fields are zero-sized `void`, not empty allocations.

| Operation | With attributes off |
| --- | --- |
| Node and scope views, names, mentions, membership, `hasEdge` | Same as the full profile |
| `edgeIterator`, `IR.edgeSession`, and their `In` forms | Same order, strict merging and orientation; no attribute folding |
| `materialize(.{})`, `materializationSession(.{})` | Topology output: plain `Edge` records |
| Attribute lookup and iteration, attribute sessions and scratch, `tailPort()`/`headPort()`, materializing with `.attributes = true` | Compile error |

- Input is still fully validated; only what is kept changes.
- Written ports remain readable with `connection.left.portSyntax(graph)`. They
  never stand in for effective port values.
- Partial topology graphs still show gaps and unknown answers, and partial
  materialization keeps its `Knowledge` answers.
- Fixed storage works too; keep `declarations`, `attributes`, `attribute_keys`
  and `attribute_states` at zero (see [fixed buffers](#fixed-buffers-no-allocator)).
- `max_attributes` and `max_attribute_states` don't apply; other limits do.
- Dropped attributes can't be recovered from the graph. Keep the Document and
  lower it again with a full profile if you need them later.
- Savings depend on the input; attribute-heavy files gain most. Smaller pools
  don't guarantee lower process memory (RSS).

### Optional query indexes

```zig
const Indexed = dot.ir.Lowering(.{
    .indexes = .{ .connections = true, .scope_memberships = true },
});
var result = try Indexed.parse(gpa, source, .{ .diagnostics = sink });
defer result.deinit();
const graph = result.ir() orelse return error.InvalidInput;
const from = (try graph.findNode("a")) orelse return error.MissingNode;
const to = (try graph.findNode("b")) orelse return error.MissingNode;
const members = try graph.scopeMembership(.root);
std.debug.print("a -> b: {}, a in the graph: {}\n", .{
    try graph.hasEdge(from, to), try graph.contains(members, from),
});
```

Both are off by default. Turn them on when repeated queries are worth extra
build work and memory. The query calls stay the same.

| Index | Speeds up | Array size |
| --- | --- | --- |
| `connections` | `hasEdge`, strict edge attribute lookup and iteration, and their sessions | `4 × (nodes + 1 + connections)` bytes per endpoint side that has single-node endpoints |
| `scope_memberships` | `scopeMembership` | `4 × scopes` bytes |

- The connection index stores connection IDs only, never endpoint sets or node
  pairs. A query takes the shorter candidate list for its two nodes, adds
  connections with set endpoints, and checks candidates in order. Undirected
  queries look both ways. When the index wouldn't narrow the search, the
  ordinary scan runs under the same budget.
- Small graphs (fewer than 8 connections) and sides with no single-node
  endpoints get no connection-index arrays.
- Non-strict edge lookups and materialized attributes keep their direct paths.
- The scope index stores only each scope's final membership handle; occurrence
  snapshots are unchanged.
- Indexes never change answers. On a partial graph, coverage still decides
  whether an answer is known. Queries never build or change an index.
- Building counts against lowering's memory and work limits, and sessions build
  it in charged steps. A failure returns no graph. Disabled indexes add no
  arrays, work or branches. Sizes exclude descriptors and allocator overhead.

### Other source encodings

UTF-8 is the default; ASCII files are read by it too. To lower UTF-16 or UTF-32
Documents, compile those readers in:

```zig
const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
```

- The Document supplies the actual encoding, and ranges stay in its original
  bytes. Readers you don't list are left out of the program. `&.{}` means
  ASCII only. A Document in an encoding the profile doesn't read gives
  `error.UnsupportedEncoding`.
- UTF-8 and ASCII profiles keep a name's or value's bytes as they are.
- For UTF-16 and UTF-32, names and values are decoded while lowering, before
  you can print them. Malformed code units give `error.InvalidIdentifier`. This
  can happen with the DOT `invalid_encoding` check off (the default), and
  **also with `invalid_encoding = .err`**, because that check skips the inside
  of HTML-like `<...>` strings. See [ENCODINGS.md](ENCODINGS.md#checking-that-the-text-is-valid).

## Lower a Document you already have

Use this when you parse with your own DOT settings, or want to keep the Document.

```zig
const Dot = dot.Profile(.{}); // The profile that accepts the Document.
const IR = dot.ir.Lowering(.{});

var parsed = Dot.parseAndValidate(gpa, source, sink, .{});
defer parsed.deinit(gpa);
if (!parsed.documentValid()) return error.InvalidInput;
const doc = &parsed.document.?;

var ir = try IR.lowerComplete(gpa, doc, .{
    .interpretation = Dot.interpretation(doc, .{}),
});
defer ir.deinit();
```

- `.interpretation` is required. Take it from the **same profile and runtime
  options** that accepted the Document (with `try` on runtime-policy DOT
  profiles), so settings like conforming operators can't silently change the
  meaning.
- The Document must be complete, accepted and built by the parser, unchanged.
  Lowering doesn't repeat DOT syntax or validation checks. A partial Document
  gives `error.IncompleteDocument`. Building or editing Document records by hand
  is outside this contract: the range checks are a safety net, not full
  validation.
- Whether optional label (child-processor) checks must pass is your decision.
- After lowering you may free the Document; the graph borrows only the source.
- Options: `.interpretation`, `.limits` (null or omitted means the profile's
  limits), `.cancellation` (only if the profile enables cancellation) and
  `.policy` (only with `runtime_policy`). Unknown fields are compile errors. On
  runtime-policy profiles the call can also return
  `error.InvalidCancellationInterval`.
- `IR.lowerPartial(gpa, doc, options)` lowers a partial or complete Document
  into a `PartialGraph`; see [below](#lower-a-partial-document-yourself).

## Partial graphs for editors

`dot.ir.parsePartial` keeps what it can around recoverable syntax errors. It uses
the default DOT settings with [partial results](EDITORS.md#keep-the-finished-part-of-a-dot-file)
turned on. `parse` and `lowerComplete` don't change.

```zig
var bag: dot.reporting.FixedBag(dot.Diagnostic, 100, .omit) = .{};
var result = try dot.ir.parsePartial(gpa, source, .{ .diagnostics = bag.sink() });
defer result.deinit();
const ir = result.ir() orelse return error.GraphUnavailable;

var edges = try ir.edgeIterator(.{});
defer edges.deinit();
while (try edges.next()) |edge| {
    switch (try edge.attribute("color")) {
        .known => |color| std.debug.print("{f} -> {f}: color={?f}\n", .{ edge.from().name(), edge.to().name(), color }),
        .unknown => |answer| std.debug.print("{f} -> {f}: color={?f} (may change)\n", .{ edge.from().name(), edge.to().name(), answer.retained }),
    }
}
std.debug.print("coverage: {t}\n", .{ir.state()});
```

This is [partial_graph.zig](../examples/partial_graph.zig). For

```dot
digraph {
    a -> b [color=red];
    broken -> ;
    b -> c [color=blue];
}
```

it prints both edges with known colors, then `coverage: partial`, then the
syntax error. The abandoned `broken` endpoint is not made into a node.

- `result.ir()` is null when no snapshot is available, which doesn't mean the
  input is invalid. `result.checking` keeps the original parse and validation
  results; a snapshot never makes rejected input valid.
- No graph is built after a resource or storage failure, a diagnostic stop or
  incomplete delivery, a processor stop, an unfinished validation, or (for a
  strict graph) any validation error. A strict graph whose kind is mixed or
  unresolved also leaves `ir()` null, keeping the diagnostics. Calling
  `lowerPartial` yourself reports `error.UnsupportedSemantics` instead.
- The `.omit` bag keeps the first 100 diagnostics and lets work continue. The
  default `FixedBag` **stops** when it accepts its last slot, and a stop means
  no graph. Print `bag.omitted` too. Diagnostic capacity is not a work limit.
- Parsing and lowering have separate options and budgets, as in `parse`. Custom
  cancellable, runtime-policy or native-encoding needs: use a profile's
  `IR.parsePartial` or [lower the Document yourself](#lower-a-partial-document-yourself).

### Known and unknown answers

Answers that missing input could change come back as `dot.ir.Knowledge(T)`:

- `.known: T`: the answer holds for the kept input.
- `.unknown`: `.uncertainty` (why), and `.retained`, the answer from the kept
  input, if any.

For attributes the candidate is already optional, not a double optional. Known
`null` means the key is proven absent; unknown `null` does **not**. An implicit
empty is a non-null view with `.resolved.kind = .empty`.

`Uncertainty` has a `.reason` (`.skipped_input`, `.unfinished_input` or
`.unresolved_kind`) and a `.span`: the earliest relevant gap in the source. The
span is null for `.unresolved_kind` and zero-length at the end of input.

What stays known:

- Things the kept input shows: a found node, an existing edge, a member.
- An explicit node or graph assignment with no gap after it. In
  `a [color=red]; broken -> ; b [color=blue]`, `b`'s blue is known, while `a`'s
  red is unknown with red as the candidate: the missing statement could have
  changed it.
- A non-strict edge's own explicit values and ports, because no other statement
  can update that occurrence.
- A strict edge's explicit value with no gap after its winning connection,
  unless a **later kept connection has a set endpoint**. Missing members could
  join that set and overwrite the value. For example,
  `subgraph s { broken -> ; }; a->b[color=red]; subgraph s {}->b[color=blue]`
  keeps red, but filling the gap with `a` makes blue win. The current check is
  conservative: any later set connection makes the value unknown, even when it
  can't touch this pair.
- Strict undirected `tailport` and `headport` values (except on self-loops)
  stay unknown whenever there is a gap, because a missing earlier connection
  could reverse the edge.

Everything else is unknown when any gap exists: "not found" and `false`
answers, absent keys, defaults and inherited values. Node identity is graph-wide,
scopes can reopen, and missing input can add keys or create objects earlier.
Answers replay DOT rules over the snapshot; no repaired or cached values from an
earlier version are used.

**Known answers assume each gap is filled with whole statements.** Typing more
text keeps them true. Editing kept text, or replacing a gap with text that
continues the statement before it (for example `[color=blue];` right after
`a -> b [color=red] c`), can change them. Parse again after such edits.

Coverage doesn't check validity or label contents. Strict mixed-kind graphs and
strict graphs whose kind can't be resolved are refused rather than guessed.

### Partial API

| Call | Gives |
| --- | --- |
| `result.ir()` | `?*const PartialGraph`, borrowed from the result |
| `ir.state()` | `.complete` or `.partial`; a complete empty graph is complete |
| `ir.kind()` | `Knowledge(GraphKind)`; can be unknown when the kind depends on missing input |
| `ir.gaps()` | The gaps in execution order: `reason`, source `range` and owning `occurrence` when known |
| `ir.nodeIterator()` / `scopeIterator()` | Kept node and scope views; scopes include the root and merged reopened subgraphs |
| `ir.nodeView(id)` / `scopeView(id)` | Checked views for IDs you hold |
| `node.name()` / `scope.name()` | Logical-name formatter; a scope name is optional |
| `node.mentions()` | Each kept mention: source range and occurrence. O(1) to start and per entry |
| `node.attribute(key)` / `scope.attribute(key)` | `Knowledge(?AttributeView)`, can't fail; `attributeWith(key, options)` adds limits |
| `node.attributes(options)` / `scope.attributes(options)` | Iterator of `Knowledge(AttributeView)`, one per kept key; needs `deinit` |
| `scope.membership()` | The last kept snapshot, not proof of the final contents |
| `findNode(name)`, `hasEdge(from, to)`, `contains(membership, node)` | `Error!Knowledge(…)`; `findNodeWith`, `hasEdgeWith` and `containsWith` add limits |
| `edgeIterator(options)` / `edgeView(edge)` | Edge views over the kept connections |
| `edge.attribute(key)` / `edge.attributes(options)` / `edge.attributesWith(options)` | Edge lookup and iteration with `Knowledge` answers (fallible on streamed edges) |
| `edge.orientation()` / `edge.firstConnection()` | `Knowledge` of the stored `{ from, to }` and of the first connection |
| `materialize(options)` | All kept edges or an error; see below |
| `nodeCount()` / `scopeCount()` / `connectionCount()` | Counts of kept records, never of missing input |
| `retainedBytes()` / `peakBytes()` / `capacities()` | Memory and counts, including gap records |

- Every iterator ends after **the kept entries**, not all possible entries. An
  empty attribute iterator doesn't prove absence.
- IDs and order belong to this snapshot and can change when missing input is
  filled in. Ranges use the original source encoding.
- Node and scope attribute iteration uses the same key catalog and order as a
  complete graph, allocates nothing (`peakBytes() == 0`) and shares one budget
  across `next()` calls; errors are final and repeat. Unknown entries always
  have a `.retained` candidate.
- Completed child subgraphs inside an abandoned edge are kept, once, without
  that edge.
- Views and candidates borrow the graph: keep it alive and unmoved. `_data` and
  `_coverage` are internal.

### Partial edges

Stay on `PartialGraph` for both complete and incomplete input. Its edge views
use the same expansion, strict merging and folding as a complete graph, and show
uncertainty instead of hiding it. An unfinished statement never creates a
guessed edge.

- An edge's `from()`, `to()` and `.edge` record use the **snapshot's**
  orientation and first connection. Missing earlier input can change a strict
  pair's first contribution, including undirected orientation. Use
  `edge.orientation()` and `edge.firstConnection()` when that matters; their
  unknown answers carry the snapshot's values. When there is any gap,
  `orientation()` is unknown for a strict undirected edge between two different
  nodes, and `firstConnection()` is unknown for every strict edge. Otherwise
  both are known.
- `tailPort()` and `headPort()` return `Knowledge` answers. A candidate belongs
  to the snapshot's `from()`/`to()`.
- `materialize(.{})` finishes the **operation**, not the missing input:
  `graph.state()` and `graph.kind()` repeat the graph's own. Complete input gives
  complete coverage and known answers. The default folds attributes, so lookups
  and iteration can't fail (they still return `Knowledge`); `attributeWith` and
  `attributesWith` add limits, and the known/unknown check counts against the
  same budget.
  `.attributes = false` keeps the partial views and answers attribute queries
  the compact way.

```zig
var graph = try ir.materialize(.{});
defer graph.deinit();
var stored = graph.edgeIterator();
while (stored.next()) |edge| {
    switch (edge.attribute("color")) {
        .known => |color| std.debug.print("color={?f}\n", .{color}),
        .unknown => |answer| std.debug.print("color={?f} (may change)\n", .{answer.retained}),
    }
}
```

### Lower a partial Document yourself

```zig
const PartialDot = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
const IR = dot.ir.Lowering(.{});

var parsed = PartialDot.parseAndValidate(gpa, source, sink, .{});
defer parsed.deinit(gpa);
if (parsed.document == null) return error.NoDocument;
const doc = &parsed.document.?;
var ir = try IR.lowerPartial(gpa, doc, .{
    .interpretation = PartialDot.interpretation(doc, .{}),
});
defer ir.deinit();
```

- Take the interpretation from the accepting profile and options, as for
  `lowerComplete`. Complete Documents work too.
- This can lower the Document kept by a stopped parse, as a **new** operation;
  it never resumes parsing.
- Lowering failures are errors, never unknown answers or a half-built graph.
- Gap records count against lowering's work and memory limits and appear in
  `retainedBytes()` and `peakBytes()`. Complete lowering stores no gap records.

## Fixed buffers, no allocator

Every operation that builds something has an `In` form that uses buffers you
provide. It gives the same graphs, views and answers. **Nothing is sized or
reserved for you**: you pick capacities, or ask for bounds explicitly.

| Allocator-backed | Caller-owned buffers |
| --- | --- |
| `IR.lowerComplete(allocator, document, options)` | `IR.lowerCompleteIn(document, memory, options)` |
| `IR.lowerPartial(allocator, document, options)` | `IR.lowerPartialIn(document, memory, options)` |
| `IR.loweringSession(allocator, document, options)` | `IR.loweringSessionIn(document, memory, options)` |
| `IR.partialLoweringSession(allocator, document, options)` | `IR.partialLoweringSessionIn(document, memory, options)` |
| `graph.edgeIterator(options)` | `graph.edgeIteratorIn(scratch, options)` |
| `IR.edgeSession(graph, options)` | `IR.edgeSessionIn(graph, scratch, options)` |
| `view.attributes(options)` | `view.attributesIn(scratch, options)` |
| `IR.attributesSession(view, options)` | `IR.attributesSessionIn(view, scratch, options)` |
| `graph.materialize(options)` | `graph.materializeIn(memory, options)` |
| `graph.materializationSession(options)` | `graph.materializationSessionIn(memory, options)` |

The `In` calls never allocate, grow or fall back to an allocator. The scratch
and materialization forms also work on allocator-built graphs.

### Fixed-storage lowering

```zig
// Our application's envelope, not an automatic reservation or sizing pass.
const Retained = IR.FixedGraphStorage(.{
    .nodes = 8,
    .scopes = 1,
    .occurrences = 1,
    .mentions = 16,
    .connections = 8,
    .declarations = 8,
});
const Scratch = IR.FixedLoweringScratch(Retained, .{
    .nesting = 2,
    .edge_nesting = 1,
    .pending_endpoints = 2,
});
var retained: Retained = .{};
var scratch: Scratch = .{};
const lowered = IR.lowerCompleteIn(doc, .{
    .graph = retained.storage(),
    .scratch = scratch.storage(),
}, .{ .interpretation = Dot.interpretation(doc, .{}) });
if (lowered.outcome == .failure) {
    if (lowered.shortfall) |missing|
        std.debug.print("{t}: capacity {d}, needs at least {d}\n", .{
            missing.resource, missing.limit, missing.required_at_least,
        });
    return lowered.outcome.failure;
}
var nodes = lowered.graph.?.nodeIterator();
while (nodes.next()) |node| std.debug.print("node {f}\n", .{node.name()});
```

This is [fixed_graph.zig](../examples/fixed_graph.zig) (for
`digraph { a->b; b->c }`).

- `FixedGraphStorage` and `FixedLoweringScratch` hold inline byte arrays (left
  undefined) and have a `byte_size`. They don't allocate or clear anything. Put
  large ones in memory you manage, not on a small stack.
- Zero capacity means zero, not "automatic".
- Storage types belong to the profile's representation (attributes, encodings,
  indexes). Use one profile's `FixedLoweringScratch` with the same profile's
  `FixedGraphStorage`; mixing them is a compile error. Policies and limits don't
  change these types.

`dot.ir.GraphCapacities` (all `u32`, default 0):

| Fields | What uses them |
| --- | --- |
| `nodes`, `scopes` | Unique nodes and scopes, including the root scope |
| `occurrences`, `mentions` | Written scope bodies (including the root), and node mentions |
| `connections` | Connections, **not** expanded edges |
| `endpoint_ports` | Ported edge endpoints; a chain's middle endpoint uses one record; node-statement ports use none |
| `declarations`, `attributes` | Declarations, and written attributes and assignments |
| `attribute_keys`, `attribute_states` | Distinct keys, and attribute-map cells including update history |
| `coverage_gaps` | Partial-input gaps; complete lowering needs none |
| `left_offsets`, `right_offsets` | Connection index offsets: `nodes + 1` per indexed side |
| `left_entries`, `right_entries` | Connection index entries: `connections` per indexed side |
| `scope_memberships` | Scope index: one per scope |

`dot.ir.LoweringScratchCapacities`: `nesting` (open scope **and edge** frames,
including the root), `edge_nesting` (open edge statements) and
`pending_endpoints` (buffered endpoints, never their product). Hash tables and
cursors are derived from these counts.

- Pools for features the profile leaves out must be zero. A nonzero one is a
  compile error in `FixedGraphStorage`, or `error.InvalidStorage` from
  `loweringLayout` and binding.
- Ports use the existing mention and byte limits; there's no separate port
  limit.

**Three ways to size.**

1. Pick an envelope for your application and handle shortfalls.
2. Reuse `graph.capacities()` from an earlier run: the counts actually used, with
   no slack, so only a hint for changed input. Fixed direct results report
   `scratch_peak`; fixed sessions have `scratchPeak()`. An allocator-backed run
   has no scratch peak.
3. Ask for conservative bounds and bind your own buffers:

```zig
const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
const bounds = try IR.loweringBounds(doc.capacities(), options); // Or partialLoweringBounds.
const layout = try IR.loweringLayout(bounds.graph, bounds.scratch);
// Buffers of at least layout.graph_bytes / layout.scratch_bytes,
// aligned to layout.alignment.
const retained = try gpa.alignedAlloc(u8, .@"16", layout.graph_bytes);
defer gpa.free(retained);
const scratch = try gpa.alignedAlloc(u8, .@"16", layout.scratch_bytes);
defer gpa.free(scratch);
const lowered = IR.lowerCompleteIn(doc, try layout.bind(retained, scratch), options);
if (lowered.outcome == .failure) return lowered.outcome.failure;
```

- `loweringBounds` and `partialLoweringBounds` do checked arithmetic on Document
  counts (`doc.capacities()` or a compile-time envelope). They don't read the
  source or parse again. They use the limits in `options` (or the profile's) and
  ignore other options without calling hooks; pass the same options to sizing and
  lowering.
- Bounds guarantee no pool shortfall for a valid parser-built Document within
  the envelope, unless another limit or stop comes first. They don't guarantee
  acceptance or override memory and work limits.
- Bounds can reserve far more than needed, especially attribute cells:
  `min((h(A) + 5) × A × (S + 2), max_attribute_states)`, where `A` is attributes
  plus assignments, `S` subgraphs and `h` the AVL height bound. Index bounds may
  reserve a side that a graph of only set endpoints won't use.
- You can use the scratch bounds without reserving the graph-storage bounds.

**Failures.** `FixedLoweringResult` and `FixedPartialLoweringResult` have
`graph`, `outcome`, `shortfall` and `scratch_peak`. A graph exists exactly when
`outcome == .success`.

- A full pool fails with `error.PoolExhausted`; `shortfall` names the first full
  `resource`, its `limit` and `required_at_least` (for what was read so far, not
  the whole input). Other failures have no shortfall.
- Nothing falls back to an allocator, drops records or returns a half-built
  graph. Start a new operation with more storage. Semantic limits are checked
  before each write, including attribute cells.
- On runtime-policy profiles the direct call returns an error union for an
  invalid policy only; other failures are in `outcome`. Fixed-policy profiles
  need no `try`.
- `loweringLayout` and `bind` check arithmetic, sizes, alignment and overlap in
  every build mode: a short buffer is `error.BufferTooSmall`; a misaligned,
  overlapping or altered descriptor is `error.InvalidStorage`. Lowering also
  rejects buffers that overlap the source or Document. Extra buffer bytes are
  unused. Layouts are specific to the build, not a file format.
- `max_bytes` is checked against the **whole bound reservation** (graph storage
  plus scratch, with padding) before any write. `peakBytes()` reports that
  reservation and `retainedBytes()` the graph storage. Oversized pools waste memory too;
  fixed storage removes growth copies, not the cost of large pools.

**Lifetimes.** Keep the source and graph storage alive and unchanged while the
graph and its views are used. The Document and scratch are needed only until the
direct call returns or the session is destroyed; the graph keeps no pointer to
them. Don't lower into the same storage again while an old graph still uses it.
The fixed result owns no memory and has no `deinit`. Calling the graph's
`deinit()` is safe but unnecessary: it frees nothing. Sessions are
`IR.FixedLoweringSession` and `IR.FixedPartialLoweringSession`, with
`shortfall()` and `scratchPeak()` added; see
[small steps](#lower-a-document-in-small-steps). Their setup checks a fixed
number of descriptors without clearing pools or reading input; clearing hash
tables is charged work, so larger envelopes can need more credits.
`@sizeOf(IR.FixedLoweringSession)` is the inline session size.

### Queries after fixed lowering

A fixed graph has no allocator for later operations. Add one with the fixed
lowering option `.query_allocator = allocator`; lowering itself never uses it,
and it must outlive the operations that use it. It defaults to null, with no
fallback.

| Without `query_allocator` | Result |
| --- | --- |
| Names, values, node iteration, attribute lookup, `findNode`, `hasEdge`, `contains`, `scopeMembership` | Work as usual |
| Non-strict streaming with single-node endpoints | Works; needs no scratch |
| Streaming a non-empty set endpoint, or a strict graph's pairs | `error.StorageRequired` when scratch is needed, possibly after earlier edges |
| Strict edge attribute iteration | `error.StorageRequired` when winner scratch is needed; single-key lookup still works |
| `materialize` | `error.StorageRequired`, topology-only too |
| `toString(allocator)` and other calls that take an allocator | Use the allocator you pass |

`error.StorageRequired` ends the operation; it is never an empty answer. Use the
`In` forms below to stay allocation-free.

### Fixed scratch for streaming and queries

```zig
const layout = try IR.edgeScratchLayout(graph, try IR.edgeScratchBounds(graph, .{}));
const bytes = try gpa.alignedAlloc(u8, .@"16", layout.byte_size);
defer gpa.free(bytes);
var edges = try graph.edgeIteratorIn(try layout.bind(bytes), .{});
defer edges.deinit();
var attributes: IR.FixedAttributeScratch(.{ .winners = 1 }) = .{};
while (try edges.next()) |edge| {
    std.debug.print("{f} -> {f}\n", .{ edge.from().name(), edge.to().name() });
    var values = try edge.attributesIn(attributes.storage(), .{});
    defer values.deinit();
    while (try values.next()) |value|
        std.debug.print("  {f}={f}\n", .{ value.key(), value });
}
```

This is [fixed_edge_stream.zig](../examples/fixed_edge_stream.zig). It works the
same on allocator-built and fixed graphs.

| Capacity | Used for |
| --- | --- |
| `members` (`EdgeScratchCapacities`) | Distinct members of the current left and right endpoints, not their product; single nodes stay inline. `{a b c d}->x` needs 4; `{a b c d}->{a b c d}` needs 8. |
| `strict_pairs` (`EdgeScratchCapacities`) | One key per unique strict edge emitted, plus derived hash slots. Non-strict streams need none. |
| `winners` (`AttributeScratchCapacities`) | Every edge key in the graph, for strict edge attribute iteration. Node, scope, non-strict and materialized edges need none. |

- Compile-time helpers: `IR.FixedEdgeScratch(Retained, capacities)` (node marks
  sized from `Retained`, a `FixedGraphStorage` type) and
  `IR.FixedAttributeScratch(capacities)`, each with `.storage()` and
  `byte_size`. Runtime: `IR.edgeScratchLayout(graph, capacities)` (marks sized
  from the graph's node count) and `IR.attributeScratchLayout(capacities)`, each
  with `bind(buffer)`. Descriptors are `IR.EdgeScratch` and `IR.AttributeScratch`.
- There's no marks capacity to guess. With `members > 0`, a graph with more
  nodes than the envelope is `error.InvalidStorage`. With `members = 0`, no marks
  are reserved and single-node and empty endpoints work at any size; a non-empty
  set reports a member shortfall.
- `IR.edgeScratchBounds(graph, options)`: `members = 2N` when there are
  connections, and for strict graphs `strict_pairs = min(max_edges, max_pairs, N²)`
  (directed) or `min(max_edges, max_pairs, N(N+1)/2)` (undirected); all zero with
  no connections. `IR.attributeScratchBounds(graph)` (can't fail):
  `winners = K` (all keys in the graph) for strict graphs, else zero. Both read
  only metadata, accept complete and partial graphs, may reserve too much, and
  give `error.IndexLimit` when a size doesn't fit.
- `attributesIn` takes compact node, scope and edge views, partial ones too.
  `attributesSessionIn` also takes materialized edge views.

**Rules.**

- An operation borrows its scratch exclusively until `deinit`, even after it
  fails. Keep the bytes alive and unmoved; the descriptor variable may go away.
  `deinit` never frees your memory. Reuse starts fresh. Two operations at once
  need separate scratch.
- Emitted views borrow the graph and source, not the scratch, and survive scratch
  reuse.
- Binding and starting the operation check length, alignment, the node
  envelope and overlap with the graph's own memory. Pointer lifetimes and
  scratch already lent to another operation are your responsibility.
- `peakBytes()` and `max_bytes` count the **whole bound reservation**.
  `scratchPeak()` reports the most members, pairs or winner slots used; it
  doesn't predict unvisited input.

| Failure | What happens |
| --- | --- |
| Buffer too short | `error.BufferTooSmall` before any work |
| Misaligned, altered or overlapping descriptor, or node envelope too small | `error.InvalidStorage` before any work |
| Reservation above `max_bytes` | `error.MemoryLimit` before any work |
| A needed slot is missing | Final `error.PoolExhausted`; `shortfall()` names `.members`, `.strict_pairs` or `.attribute_winners` |
| Limit, work or cancellation stop | The usual error, no shortfall |

- A full strict-pair pool still skips duplicates. For a new pair, `EdgeLimit`
  comes before the pool shortfall.
- Edges or attributes already returned stay usable, but they are a prefix. Retry
  with more storage from the start; the prefix will be emitted again. Strict
  attribute iteration resolves its winners before the first entry, so a winner
  shortfall emits nothing.
- There is no eviction, hidden growth or enlarge-and-resume.

### Fixed-storage materialization

```zig
// Retained is the input graph's IR.FixedGraphStorage(...) type.
const Output = IR.FixedMaterializedStorage(.{
    .edges = 256,
    .attribute_states = 512,
    .attribute_keys = 32,
}, .{});
const Scratch = IR.FixedMaterializationScratch(Retained, Output, .{ .members = 128 }, .{});
var output: Output = .{};
var scratch: Scratch = .{};
const memory: IR.MaterializationMemory(.{}) = .{ .output = output.storage(), .scratch = scratch.storage() };
const built = graph.materializeIn(memory, .{});
if (built.outcome == .failure) {
    if (built.shortfall) |missing|
        std.debug.print("{t}: capacity {d}, needs at least {d}\n", .{
            missing.resource, missing.limit, missing.required_at_least,
        });
    return built.outcome.failure;
}
var materialized = built.materialized.?;
defer materialized.deinit();
var edges = materialized.edgeIterator();
while (edges.next()) |edge|
    std.debug.print("{f} -> {f}\n", .{ edge.from().name(), edge.to().name() });
```

- Works on complete and partial graphs, fixed or allocator-built. It never calls
  an allocator, including a `query_allocator`.
- `IR.FixedMaterializedStorage(capacities, selection)`: `dot.ir.MaterializedCapacities`
  has `edges`, `attribute_states`, `attribute_keys`, `adjacency_offsets` and
  `adjacency_entries`. The selection takes `.attributes` (default: what the
  profile keeps; `false` needs zero attribute cells and keys) and `.adjacency`
  (`.none` needs zero adjacency counts). The operation reads the selection from
  the output type; repeating `.attributes` or `.adjacency` in its options must
  agree.
- `IR.FixedMaterializationScratch(Retained, Output, .{ .members = … }, .{})`:
  one member buffer serves both endpoints, node marks come from `Retained`, and
  the strict table is sized from the output edge capacity and points into the
  output. `.{ .strict = false }` leaves the table out but rejects strict input
  (even an empty strict graph) before writing.
- For runtime sizes or allocator-built input, compute a layout:

```zig
// An explicit scan; binding and building never do this for you.
const bounds = try IR.scanMaterializationBounds(graph, .{});
const layout = try IR.materializationLayout(graph, bounds.output, bounds.scratch, .{});
const output_bytes = try gpa.alignedAlloc(u8, .@"16", layout.output_bytes);
defer gpa.free(output_bytes);
const scratch_bytes = try gpa.alignedAlloc(u8, .@"16", layout.scratch_bytes);
defer gpa.free(scratch_bytes);
const built = graph.materializeIn(try layout.bind(output_bytes, scratch_bytes), .{});
if (built.outcome == .failure) return built.outcome.failure;
var materialized = built.materialized.?;
defer materialized.deinit();
```

| Where capacities come from | Cost and meaning |
| --- | --- |
| Your own envelope | Chosen by you; a shortfall is possible |
| `materialized.capacities()` | Counts used by an earlier result (ordinary or fixed); enough to replay the same input and options |
| `built.scratch_peak` / `session.scratchPeak()` | Member capacity used, for replay |
| `IR.materializationBounds(graph, options)` | Constant-time arithmetic on graph counts; no hooks, walks or allocation |
| `IR.scanMaterializationBounds(graph, options)` | A scan of connections and body ranges, without expanding pairs, reading names or folding |

- Both bounds helpers return `{ output, scratch }`, use the graph's limits unless
  `options.limits` replaces them, and never shrink to fit a byte budget.
- Metadata bounds cap products by the pair and edge limits, strict output by the
  number of possible node pairs, and cells by edges × keys (plus port keys) and
  `max_attribute_states`. They can be much larger than the output. Scanned bounds
  use each connection's endpoint sizes and contributions; repeated mentions and
  strict duplicates still make them conservative.
- Adjacency bounds: entries up to twice the edge bound, offsets three or four
  times (nodes + 1); none when the edge bound is zero. The two adjacency
  capacities are combined pools, not per direction.
- The scan charges one work unit per connection and per body-range visit and
  checks cancellation as it goes; reopened subgraphs can repeat visits. It
  finishes or fails, with its own budget separate from building. Sizes that
  don't fit give `error.IndexLimit`.
- `IR.MaterializationMemory(selection)`, `IR.MaterializedStorage(selection)` and
  `IR.MaterializationScratch(selection)` name the descriptor types.
- Binding checks sizes, alignment and overlap without clearing or reading the
  input; building also rejects overlap with the source, the graph and its gap
  storage.
- **Result.** `materializeIn` returns `FixedMaterializationResult(selection)` by
  value: `materialized`, `outcome`, `shortfall`, `scratch_peak`; no error union.
  Shortfall resources are `materialized_edges`, `materialized_attribute_states`,
  `materialized_attribute_keys`, `members`, `adjacency_offsets` and
  `adjacency_entries`. Semantic limits come before pool checks; a strict
  duplicate or a replaced attribute needs no new slot.
- A failure returns no result, even if every edge was written. Restart with new
  storage, or stream edges if a prefix is enough.
- All reserved output bytes count in `retainedBytes()`. `peak_bytes` and the
  up-front `max_bytes` check count the whole output and scratch reservation.
- The result is the ordinary materialized type. Its `deinit()` only invalidates
  the handle. Keep the output storage alive while the result is used; results
  with attributes or adjacency also borrow the graph and source (and gap storage
  for partial graphs). Scratch can be reused after the call returns or the
  session is destroyed.

## Small steps and cancelling

Ordinary calls run to completion. Sessions let you do a bounded amount of work
per call, so an editor or server can pause, resume and cancel. There are no
threads, clocks or callbacks inside: you call `advance` from your own scheduler.

### Turn on metering or cancellation

Sessions on a profile (`IR.loweringSession`, `IR.edgeSession`, the query and
attribute sessions) use **that profile's** execution policy. The same settings as
the [parser](EXECUTION.md):

| Setting | Default | Meaning |
| --- | --- | --- |
| `.policy.execution.metering` | `false` | Sessions allow `advance(budget)`. Direct lowering also runs the step-by-step engine to completion. |
| `.policy.execution.cancellation` | `false` | Honor the `.cancellation` hook in the call's options |
| `.policy.execution.cancellation_interval` | `1` | Most work credits between hook calls; positive. Every resume also checks, even with budget 0. |
| `.runtime_policy` | `false` | Allow a `.policy` option per call, applied before any work |

```zig
const Request = struct {
    stop: bool = false,
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.stop;
    }
};
const IR = dot.ir.Lowering(.{
    .policy = .{ .execution = .{ .cancellation = true } },
    .runtime_policy = true,
});
var request: Request = .{};
const options = .{
    .interpretation = Dot.interpretation(doc, .{}),
    .cancellation = dot.ir.Cancellation{ .context = &request, .is_requested = Request.poll },
    .policy = .{ .execution = .{ .metering = true, .cancellation_interval = 64 } },
};
var graph = try IR.lowerComplete(gpa, doc, options);
defer graph.deinit();
// To pause and resume instead: IR.loweringSession(gpa, doc, options).
```

- Nothing is inherited from the parser that made the Document, or from an
  earlier operation. Document parsing and lowering have separate budgets;
  [event-based sessions](#pause-event-construction) provide a shared grant.
- A hook never enables cancellation. A fixed profile without cancellation
  rejects a hook at compile time; a runtime policy with cancellation off ignores
  it. A `void` hook means none. Typed and anonymous hooks are accepted.
- With cancellation on, the interval applies even without metering.
- Fixed policies are checked at compile time. With `runtime_policy`,
  `IR.validatePolicy(policy)` checks an override ahead of time, and each call
  checks once before hooks, allocation or writes
  (`error.InvalidCancellationInterval`). A policy can't change mid-operation.
- `advance` with metering off is a compile error on a fixed policy, and
  `error.MeteringDisabled` (no work done) on a runtime policy.
- With metering or cancellation on, direct `lowerComplete`, `lowerPartial`,
  `lowerCompleteIn` and `lowerPartialIn` run the step-by-step engine to the end
  and return only a finished graph. With both off they use the faster direct
  path and build no session.
- Graph methods (`edgeIterator`, `hasEdgeWith`, `materialize`,
  `materializationSession`, `attributeWith` and the others) take `.limits` and
  `.cancellation` as plain options and always honor a hook; no policy is
  involved. Graphs don't store a policy.
- A hook may call the session's own `cancel()` and return `false`; the session
  still stops. A hook may not call `advance`, `run` or `deinit`, and
  cancellation from an allocator callback isn't supported. See
  [EXECUTION.md](EXECUTION.md#cancelling).

### What every session has in common

| Call | What it does |
| --- | --- |
| `advance(budget: u32)` | Does at most `budget` work credits and returns a progress record. Running out of budget is a pause, not a result. Needs metering on profile sessions. |
| `run()` | Drives to the end (streams: to the next item), within the total limits. Works without metering. |
| `cancel()` | Stops an active session for good; a finished outcome is not replaced |
| `takeResult()` | Lowering and materialization only. Moves the result out once: `error.NotReady` while active, `error.AlreadyTaken` after, or the actual failure |
| `peakBytes()` | Peak requested bytes, including scratch and overlapping old and new buffers during growth |
| `deinit()` | Frees scratch, growth buffers and any result not taken. Required on every path, also after `takeResult()`. |

- A progress record has `work_used` (this call), `total_work` (all calls) and
  `outcome`: null while active, then `.success` or `.failure` with the error.
- `advance(0)` does no work but checks cancellation (when a hook is enabled).
  Any positive budget makes progress, even 1. Outcomes latch: later calls do no
  work and return the same outcome.
- Total limits such as `max_work` never refill when you pause. Running out of a
  call's budget pauses; running out of a total limit, allocation failure and
  cancellation end the session.
- `run().work_used` is the count of its last internal advance; `total_work` is
  the full count.
- Construction checks options and handles and polls cancellation, but doesn't
  scan or allocate.
- Keep the session, its inputs and the source alive and unmoved between calls.
  Don't copy an active session or an owning result.
- A pause is not a partial graph, and nothing is handed out before success.
- Work credits are not wall time. Allocator calls, hook calls and destruction
  are outside the budget, and the allocator may do its own work. This is a
  cooperative work bound, not a deadline.
- With the same allocator behavior, results and total credits don't depend on
  how you split the budget. Credits include real copying, so an allocator that
  grows in place can use fewer. Session credits are finer than the direct
  calls' work counts, so the same tight `max_work` need not suit both; results
  agree when both finish.

### Lower a Document in small steps

```zig
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

var operation = try IR.loweringSession(gpa, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
defer operation.deinit();
while (operation.advance(64).outcome == null) {
    // Return to your scheduler here. Keep the operation, Document and source
    // alive and unmoved until a later call to advance finishes lowering.
}
var ir = try operation.takeResult();
defer ir.deinit();
```

This is [resumable_graph.zig](../examples/resumable_graph.zig).

- `IR.loweringSession` and `IR.partialLoweringSession` take the same options and
  prerequisites as `lowerComplete` and `lowerPartial`, and give the same `Graph`
  or `PartialGraph`. They don't parse again, expand edges, run label checks or
  change validation results.
- `IR.LoweringSession` and `IR.PartialLoweringSession` are the types. Progress
  (`dot.ir.LoweringProgress`) adds `nodes_created` and `connections_created`;
  these are counts, not a finished graph.
- After `takeResult()` the graph borrows only the source; free the Document and
  the session.

### Materialize in small steps

```zig
var operation = try ir.materializationSession(.{});
defer operation.deinit();
while (operation.advance(64).outcome == null) {
    // Return to your scheduler here; keep the operation, IR and source alive.
}
var graph = try operation.takeResult();
defer graph.deinit();
```

This is [resumable_edges.zig](../examples/resumable_edges.zig).

- `materializationSession(options)` is a graph method, so it needs no profile
  policy: `advance` always works and a `.cancellation` hook is always honored.
  Options are the same as `materialize`: compile-time `.attributes` and
  `.adjacency`, runtime `.limits` (default: the graph's) and `.cancellation`.
- `takeResult()` returns the same type as `materialize`. Session types are
  `Graph.MaterializationSession(.{ .attributes = …, .adjacency = … })`, also on
  `PartialGraph`.
- Progress (`dot.ir.MaterializationProgress`) adds `pairs_visited` (including
  strict duplicates) and `edges_created`. These are progress, not finished edges;
  `edges_created` can be final while adjacency is still being built.
- Cancellation is checked at every resume and before every credit. A session at
  its `max_work` limit checks cancellation before reporting `WorkLimit`.
- A rejected product is detected before its edges are allocated. No failure
  returns a partial result. The result owns its buffers and, with attributes
  or adjacency, still borrows the graph and source.

### Stream edges in small steps

```zig
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

var stream = try IR.edgeSession(graph, .{});
defer stream.deinit();
while (true) {
    const progress = stream.advance(64);
    if (progress.edge) |edge|
        std.debug.print("{f} -> {f}\n", .{ edge.from().name(), edge.to().name() });
    if (progress.outcome) |outcome| switch (outcome) {
        .success => break,
        .failure => |err| return err,
    };
    // Yield to your scheduler here. No edge does not mean end of stream.
}
```

This is [resumable_edge_stream.zig](../examples/resumable_edge_stream.zig).

- Takes this profile's `Graph` or `PartialGraph`; types are `IR.EdgeSession` and
  `IR.PartialEdgeSession` (fixed: `IR.FixedEdgeSession`,
  `IR.FixedPartialEdgeSession`). Options: `.limits` (default: the graph's),
  `.cancellation` and `.policy` as the profile allows.
- `advance` returns early once one edge is ready. `progress.edge` holds at most
  one edge, delivered once. `run()` runs to the next edge or the end; it doesn't
  drain the stream.
- **No edge doesn't mean the end**: preparing a large endpoint, rehashing or
  skipping strict duplicates can use the whole budget. Only `.success` means the
  stream is finished. A budget of 0 never replays an edge.
- Progress adds `pairs_visited` and `edges_emitted`.
- There is no `takeResult`. Edges borrow the graph and source, not the session,
  and stay usable after `deinit()`.
- Order, deduplication, orientation and first connections match `edgeIterator`.
  Attribute and port queries on a delivered edge are separate operations with
  their own limits, not charged to `advance`.
- Memory as for `edgeIterator`. The pair limit counts duplicates; a stream may
  deliver a prefix of a product larger than `max_pairs` and stops at the pair
  that would go over. A failure doesn't take back delivered edges, but they are
  not a finished stream.

### Edge and membership queries in small steps

```zig
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

var query = try IR.hasEdgeSession(graph, from, to, .{});
defer query.deinit();
while (true) {
    const progress = query.advance(64);
    if (progress.outcome) |outcome| switch (outcome) {
        .success => |found| {
            std.debug.print("a -> c: {}\n", .{found});
            break;
        },
        .failure => |err| return err,
    };
    // Yield to your scheduler. No outcome yet does not mean "no edge".
}
```

This is [resumable_query.zig](../examples/resumable_query.zig).
`IR.containsSession(graph, membership, node, options)` works the same way.

| Result | Meaning |
| --- | --- |
| Null `outcome` | Still searching; not false, not absent |
| `.success` on a `Graph` | A `bool`, as from the direct call |
| `.success` on a `PartialGraph` | `Knowledge(bool)`, with the same rules as the direct call |
| `.failure` | The real cause, such as `WorkLimit` or `Cancelled`; no answer |

- Types: `IR.HasEdgeSession`, `IR.ContainsSession`, `IR.PartialHasEdgeSession`,
  `IR.PartialContainsSession`. Outcome types: `dot.ir.QueryOutcome` and
  `dot.ir.PartialQueryOutcome`.
- Only `max_work` applies: these queries don't allocate (`peakBytes()` is 0) or
  visit pairs, so `max_bytes = 0` and `max_pairs = 0` are fine.
- Handles are checked for range at construction; handles from another graph
  can't be detected. Finding a node by name first (`findNode`) is a separate,
  direct call.
- A found edge can finish early; "no" means finishing the search. The state is a
  small inline cursor, even across reopened scopes. Each `advance` is bounded,
  but total cost still grows with the connections and body ranges searched.

### Attribute lookups in small steps

| Object | Ordinary | Bounded, runs to the end | In small steps |
| --- | --- | --- | --- |
| Node or scope | `view.attribute(key)` | `try view.attributeWith(key, options)` | `try IR.attributeSession(view, key, options)` |
| Streamed edge | `try edge.attribute(key)` | `try edge.attributeWith(key, options)` | `try IR.attributeSession(edge, key, options)` |
| Materialized edge with attributes | `edge.attribute(key)` | `try edge.attributeWith(key, options)` | `try IR.attributeSession(edge, key, options)` |

```zig
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

var stream = try IR.attributesSession(edge, .{});
defer stream.deinit();
while (true) {
    const progress = stream.advance(64);
    if (progress.attribute) |attribute|
        std.debug.print("{f}={f}\n", .{ attribute.key(), attribute.value() });
    if (progress.outcome) |outcome| switch (outcome) {
        .success => break,
        .failure => |err| return err,
    };
    // Yield to your scheduler here, even if an entry was delivered.
}
```

This is [resumable_attributes.zig](../examples/resumable_attributes.zig).

| Session type | Answer | Progress fields |
| --- | --- | --- |
| `IR.AttributeSession` | `?AttributeView` in `outcome.success` | `work_used`, `total_work`, `outcome` |
| `IR.PartialAttributeSession` | `Knowledge(?AttributeView)` in `outcome.success` | The same |
| `IR.AttributesSession` | `AttributeView` in `progress.attribute` | The same plus `attribute`, `attributes_emitted` |
| `IR.PartialAttributesSession` | `Knowledge(AttributeView)` in `progress.attribute` | The same as `AttributesSession` |

- The view is passed by value and the session type is picked from it. Node,
  scope, streamed-edge, materialized-edge (with attributes) and adjacency views
  are accepted. For IDs, make a checked view first.
- `attributesSession` gives the same entries in the same order as the direct
  iterator, at most one per `advance`; `run()` stops at the next entry. Only
  `outcome = .success` means the list is finished. Entries delivered before a
  failure stay usable but aren't a full list.
- **The key is borrowed until `deinit()`**, unlike the direct call. If you queue
  a session, keep the key bytes somewhere stable (a string literal, or an owned
  copy stored with the session). Keys are logical UTF-8 whatever the source
  encoding.
- There is no `takeResult`: answers borrow the graph and source and outlive the
  session and any materialized owner. A materialized view's owner must stay
  alive until the session is destroyed.
- Single-key lookups use only inline state (`peakBytes() == 0`). Strict streamed
  edge iteration allocates the 12-byte-per-edge-key winner table when needed,
  bounded by `max_bytes`; everything else allocates nothing. `max_pairs = 0` is
  fine. Fixed forms: `IR.attributesSessionIn` with `IR.FixedAttributesSession`
  and `IR.FixedPartialAttributesSession`.
- Sessions return `tailport` and `headport` as ordinary attributes. The
  structured `tailPort()`/`headPort()` helpers and value formatting stay direct.

### What a credit buys

Lowering:

| Work | At most, per credit |
| --- | --- |
| Counting, traversal, indexing | One order slot, chain link, scope, mention or phase step |
| Name hashing and comparison | One byte (UTF-8, ASCII), one character (UTF-16/32, up to two code units), one `+` glue unit, one pending UTF-8 output byte, or one hash probe |
| Attribute maps | One tree visit or ancestor update, with at most two rotations and five cell writes |
| Buffer growth and setup | 64 bytes copied or cleared, or one bounded storage step |
| Query-index building | One connection or occurrence, one offset, or one allocation or phase step |

Materialization and edge streaming:

| Work | At most, per credit |
| --- | --- |
| Endpoint traversal | One body or mention, or one single-node or phase step |
| Pair expansion and deduplication | One candidate pair, one hash probe, or one rehash entry |
| Attribute folding | One attribute, tree visit or ancestor update (at most two rotations) |
| Port-key comparison | One source code unit, including `+` glue and comments |
| Buffer copying and setup | 64 bytes |
| Storage preparation | One step with an allocation, resize or free call |
| Adjacency | One edge (at most two incidences), one offset, or one phase step or allocation |

Queries: one connection, single node, membership body or binary-search probe,
with small fixed transitions and the final coverage check folded in.

Attribute sessions: hashing up to 64 key bytes, decoding one name or glue unit or
pending UTF-8 byte, one table, map, membership or coverage probe, one
contribution or attribute visit, setting up one winner, or one small phase step.

Long names, comments in concatenations, rehashing, scope-default overlays,
reopened membership and partial checks all pause at budget 1. Hash matches are
still confirmed by comparing names.

## Limits, memory and costs

### Limits

`dot.ir.Limits`. Every limit is a finite default, not a promise about acceptable
graph sizes. There is no "zero means unlimited".

| Field | Default | Counts | Error |
| --- | ---: | --- | --- |
| `max_nodes` | 1,000,000 | Unique nodes | `NodeLimit` |
| `max_scopes` | 100,000 | Written scopes, including the root | `ScopeLimit` |
| `max_mentions` | 4,000,000 | Node mentions | `MentionLimit` |
| `max_connections` | 2,000,000 | Connections | `ConnectionLimit` |
| `max_attributes` | 2,000,000 | Written attributes and assignments | `AttributeLimit` |
| `max_attribute_states` | 8,000,000 | Attribute-map cells while lowering (including history), or per-edge winner cells while materializing | `AttributeStateLimit` |
| `max_edges` | 1,000,000 | Edges emitted or materialized | `EdgeLimit` |
| `max_pairs` | 4,000,000 | Candidate pairs visited, duplicates included (`u64`) | `PairLimit` |
| `max_work` | 100,000,000 | Work units per operation (`u64`) | `WorkLimit` |
| `max_bytes` | 256 MiB | Peak live requested bytes per operation (`usize`) | `MemoryLimit` |

- Counts are `u32`. Sizes that don't fit give `error.IndexLimit`. Products use
  checked arithmetic.
- `max_bytes` includes temporary old and new buffers during growth. Fixed
  operations count their whole bound reservation. It excludes the borrowed
  input, inline operation state, allocator overhead and process memory (RSS).
- Limits are totals for one operation (or one iterator's whole life), not
  refilling credits or deadlines.

### Passing limits and cancellation

- **Lowering:** set a profile baseline with `Lowering(.{ .limits = … })`, or pass
  `.limits` per call. Omitted or null means the profile's limits.
  `dot.ir.parse` takes `.lowering = .{ .limits = …, .cancellation = … }`.
- **Graph operations** take `dot.ir.Options { limits: ?Limits, cancellation:
  ?Cancellation }`: `findNodeWith`, `writeNodeNameWith`, `hasEdgeWith`,
  `nodeAttributeWith`, `scopeAttributeWith`, `edgeAttributeWith`, the views'
  `attributeWith` and `attributes`, value `With` calls, `edgeIterator`,
  `materialize` and `materializationSession`. Omitted limits mean the limits the
  graph was built with. Explicit limits replace them as a whole; fields are not
  merged.
- **Iterators** count across all `next()` calls; limits don't reset per edge.
- Streaming may use a small prefix of a product larger than `max_pairs` and
  fails at the pair that would go over; materialization rejects that product
  before allocating it.
- A limit or cancellation is always an error, **never** `false`, absence, or a
  shorter graph presented as complete. A failed one-shot call frees what it
  allocated; an iterator still needs `deinit()`.
- Direct graph queries and pull iterators use coarser work units (table probes,
  comparisons, traversal steps) than sessions. Name operations are charged by
  their byte length and checked around each call. Allocation, copying during
  growth and a single name operation can't be interrupted. An iterator checks
  cancellation during endpoint traversal, pair visits and deduplication, but one
  `next()` may read whole endpoint sets first.
- None of this changes the parser's own metering or cancellation.

### Errors

All IR operations use `dot.ir.Error`:

| Error | Meaning |
| --- | --- |
| `OutOfMemory` | The allocator failed |
| `MemoryLimit`, `WorkLimit`, `NodeLimit`, `ScopeLimit`, `MentionLimit`, `ConnectionLimit`, `AttributeLimit`, `AttributeStateLimit`, `EdgeLimit`, `PairLimit` | A [limit](#limits) was reached |
| `IndexLimit` | A count or size doesn't fit its integer type |
| `Cancelled` | The cancellation hook or `cancel()` stopped the operation |
| `IncompleteDocument` | `lowerComplete` was given a partial Document |
| `InvalidDocument` | The Document's records are inconsistent (not built by the parser, or changed) |
| `InvalidIdentifier` | A UTF-16 or UTF-32 name or value has malformed code units |
| `InvalidHandle` | An ID, membership or edge is out of range, or an edge isn't one of this graph's edges |
| `UnsupportedEncoding` | The Document's encoding isn't compiled into this profile |
| `UnsupportedSemantics` | A strict graph with mixed or unresolved kind, or an operator that doesn't match its kind |
| `PoolExhausted` | A fixed pool is full; see the `shortfall` |
| `BufferTooSmall` | A caller buffer is shorter than its layout |
| `InvalidStorage` | A caller buffer is misaligned, overlaps, has an altered descriptor, or reserves a pool the profile leaves out |
| `StorageRequired` | A fixed graph without `query_allocator` needed scratch |

Also: `error.InvalidCancellationInterval` (runtime policy with interval 0),
`error.MeteringDisabled` (`advance` with runtime metering off), and
`error.NotReady` / `error.AlreadyTaken` from `takeResult()`.
Event construction's `EventIR.Error` also includes the bound DOT profile's
source-admission and policy errors.

### What each operation costs

| Operation | Allocates | Work |
| --- | --- | --- |
| `dot.ir.parse` | The Document (freed after) and the graph | Parse and validation, then lowering; the Document overlaps the graph while it is built |
| Lowering | Graph tables only | One pass over the Document's records, with name hashing and O(log K) attribute-map updates; reopening a subgraph after its parent's defaults change reapplies that subgraph's own overrides |
| `nodeIterator`, names, node and scope `attribute` | Nothing | O(1) per step; one key lookup and O(log K) map lookup per attribute |
| `findNode` | Nothing | Name length plus hash probes |
| `hasEdge` | Nothing | Scans connections and membership (or the index) |
| `contains` | Nothing | Bodies in the snapshot × a binary search |
| `scopeMembership` | Nothing | Scans occurrences (or the index); for every scope, can be quadratic |
| Streamed edge `attribute(key)` | Nothing | Non-strict: its own connection. Strict: all connections and membership. Repeating for every edge can cost edges × connections. |
| Strict undirected compact `tailPort()` / `headPort()` | Nothing | Can repeat first-contribution searches: O(C²) for C connections, and can exhaust `max_work` on modest output. Materialize for bulk access. |
| Node, scope, edge `attributes(options)` | Strict edges: 12 bytes per edge key | Scans the key catalog; a strict edge scans its contributions once |
| `edgeIterator` | Member buffers and marks; strict pairs | Visits every candidate pair, duplicates included |
| `materialize(.{ .attributes = false })` | The edge array and strict pair table | Every candidate pair |
| `materialize(.{})` | Edges, winner cells and key list: O(E + A + K) for E edges, A explicit winners, K edge keys, plus scratch | Every pair plus O(log K) map work per explicit write; never a dense edges × keys table |
| Adjacency | Row tables | O(nodes + edges) |

- **Lowering memory.** The declaration and port tables are allocated at their
  exact size. Node storage grows as needed, capped by the remaining mentions and
  `max_nodes`, so repeated names don't reserve one node per mention. Connections
  and port records share one checked allocation.
- **Attribute maps.** Effective node and graph values live in balanced maps that
  point at the written attributes. Snapshots are read-only and share branches,
  so no node or subgraph copies the whole default table. A new map with K keys
  keeps K cells; updating a finished map copies its O(log K) path. Older cells
  aren't garbage-collected. Attribute-free input allocates no attribute-map
  storage. A node record is 24 bytes on 64-bit targets.
- **Ports.** Written edge ports are stored once per ported endpoint and referred
  to by `PortId`. Equal spellings at different places stay separate.
- **Memory numbers.** `retainedBytes()` is the allocated payload including spare
  capacity. `peak_bytes` (or `peakBytes()`) also counts temporary scratch and
  growth buffers, but not the source, the Document, allocator metadata or RSS. A
  materialization peak excludes the graph it reads. Arenas can keep freed blocks
  and extra chunk capacity, so fewer retained bytes don't always mean a smaller
  arena or process. Use a bounded backing allocator for a hard cap.

Measured numbers are in [Performance](PERFORMANCE.md).

## Reference

### `dot.ir` module

| Name | What it is |
| --- | --- |
| `parse(allocator, source, options)` | Parse, validate and lower with the default profile; returns `ParseResult` |
| `parsePartial(allocator, source, options)` | The same with partial results; returns `PartialResult` |
| `ParseOptions` | `.diagnostics`, `.dot` (DOT `CheckOptions`), `.lowering` (`Options`) |
| `ParseResult`, `PartialResult` | `.checking`, `ir()`, `deinit()` |
| `Lowering(config)` | Makes a profile; see [Choose what the graph keeps](#choose-what-the-graph-keeps) |
| `Config`, `Capabilities`, `Indexes`, `Policy` | Profile settings |
| `Limits`, `Options`, `Cancellation`, `Error` | Limits, per-call options, the hook type and the error set |
| `NodeId`, `ScopeId`, `OccurrenceId`, `ConnectionId`, `Membership`, `PortId` | Handles |
| `Node`, `Scope`, `Occurrence`, `Mention`, `Connection`, `Declaration`, `Edge` | Record types; `Node` and `Connection` are the default profile's (use `IR.Node` and `IR.Connection` for others) |
| `MaterializedTopology` | Topology-only materialized result |
| `ResolvedAttribute`, `AttributeValue`, `AttributeOrigin`, `PortReference`, `PortAttributeKey` | Attribute details |
| `ValueKind`, `OperandKind`, `EncodedFragment`, `Compass` | Value and port helpers |
| `Knowledge`, `Uncertainty`, `CoverageGap` | Partial answers |
| `GraphCapacities`, `LoweringScratchCapacities`, `EdgeScratchCapacities`, `AttributeScratchCapacities`, `MaterializedCapacities`, `MaterializationScratchCapacities` | Fixed-storage capacities |
| `StorageShortfall`, `Resource` | Shortfall details |
| `Adjacency`, `EdgeDirection`, `IncidentEdgeOptions` | Adjacency selection and filters |
| `LoweringProgress`, `LoweringOutcome`, `MaterializationProgress`, `MaterializationOutcome`, `EdgeStreamingOutcome`, `QueryOutcome`, `PartialQueryOutcome` | Session progress and outcomes |

### Profile `IR = dot.ir.Lowering(config)`

| Name | What it is |
| --- | --- |
| `capabilities`, `Node`, `Connection`, `Graph`, `PartialGraph` | This profile's choices and types |
| `parse`, `parsePartial`, `ParseOptions`, `ParseResult`, `PartialResult` | One-call parsing with this profile |
| `lowerComplete`, `lowerPartial` | Lower a Document |
| `FromEvents(Dot)` | Bind complete/partial construction and UTF-8/ASCII sessions to a DOT event profile; see [Build from events](#build-from-events) |
| `loweringSession`, `partialLoweringSession`, `LoweringSession`, `PartialLoweringSession` | Lower in small steps |
| `lowerCompleteIn`, `lowerPartialIn`, `FixedLoweringResult`, `FixedPartialLoweringResult` | Fixed-storage lowering |
| `loweringSessionIn`, `partialLoweringSessionIn`, `FixedLoweringSession`, `FixedPartialLoweringSession` | Fixed-storage lowering in small steps |
| `FixedGraphStorage`, `FixedLoweringScratch`, `GraphStorage`, `LoweringScratch`, `LoweringMemory`, `loweringLayout`, `loweringBounds`, `partialLoweringBounds` | Lowering storage and sizing |
| `FixedMaterializedStorage`, `FixedMaterializationScratch`, `MaterializedStorage`, `MaterializationScratch`, `MaterializationMemory`, `materializationLayout`, `materializationBounds`, `scanMaterializationBounds` | Materialization storage and sizing |
| `FixedEdgeScratch`, `FixedAttributeScratch`, `EdgeScratch`, `AttributeScratch`, `edgeScratchLayout`, `attributeScratchLayout`, `edgeScratchBounds`, `attributeScratchBounds` | Query scratch and sizing |
| `edgeSession`, `edgeSessionIn`, `EdgeSession`, `PartialEdgeSession`, `FixedEdgeSession`, `FixedPartialEdgeSession` | Edge streams in small steps |
| `hasEdgeSession`, `containsSession`, `HasEdgeSession`, `PartialHasEdgeSession`, `ContainsSession`, `PartialContainsSession` | Queries in small steps |
| `attributeSession`, `attributesSession`, `attributesSessionIn`, `AttributeSession`, `PartialAttributeSession`, `AttributesSession`, `PartialAttributesSession`, `FixedAttributesSession`, `FixedPartialAttributesSession` | Attribute access in small steps |
| `validatePolicy(policy)` | Check a runtime override (runtime-policy profiles only) |

### `Graph`

| Call | Notes |
| --- | --- |
| `nodeIterator()`, `nodeView(id)`, `scopeView(id)`, `edgeView(edge)` | Views; constructors check handles |
| `findNode(name)`, `findNodeWith(name, options)` | `?NodeId` |
| `nodeName(id)`, `nodeSpelling(id)`, `writeNodeName(id, writer)`, `writeNodeNameWith(id, writer, options)` | Names |
| `text(range)`, `attributeSlice(range)` | Source bytes; a raw attribute range |
| `nodeAttribute[With]`, `scopeAttribute[With]`, `edgeAttribute[With]`, `attributeValue(resolved)` | ID-based attribute access |
| `hasEdge[With]`, `contains`, `scopeMembership` | Connection queries |
| `edgeIterator(options)`, `edgeIteratorIn(scratch, options)` | Edge streams |
| `materialize(options)`, `materializeIn(memory, options)`, `materializationSession(options)`, `materializationSessionIn(memory, options)` | Edge arrays |
| `retainedBytes()`, `capacities()`, `peak_bytes`, `limits`, `deinit()` | Memory, used counts, limits used, cleanup |
| `NodeView`, `ScopeView`, `EdgeView`, `AttributeView`, `AttributeIterator`, `FixedAttributeIterator`, `ValueView`, `OperandView`, `PortView`, `PortSyntaxView`, `GraphvizPortParts`, `PortText`, `CompassStatus`, `NodeIterator`, `EdgeIterator`, `FixedEdgeIterator` | View and iterator types |
| `Materialized`, `MaterializedFor(selection)`, `MaterializationSession(selection)`, `FixedMaterializationResult(selection)`, `FixedMaterializationSession(selection)` | Result and session types |

Views on a `Graph`:

| View | Has |
| --- | --- |
| Node view | `.id`, `name()`, `attribute(key)`, `attributeWith(key, options)`, `attributes(options)`, `attributesIn(scratch, options)` |
| Scope view | `.id`, `attribute`, `attributeWith`, `attributes`, `attributesIn` |
| Streamed edge view | `.edge`, `from()`, `to()`, `attribute`, `attributeWith`, `tailPort`, `headPort`, `tailPortWith`, `headPortWith`, `attributes(options)`, `attributesIn` (lookups need `try`) |
| Materialized edge view | `.edge`, `from()`, `to()`, `attribute`, `tailPort`, `headPort` (can't fail), `attributeWith`, `tailPortWith`, `headPortWith`, `attributes()` (no `deinit`), `attributesWith(options)` |
| Adjacency node view | The node view's calls plus `edges(.{ .direction })` and `edgeCount(.{ .direction })`; `mentions()` on partial results |
| Adjacency entry | `neighbor()`, `edge()`, `directions()` |
| Attribute view | `key()`, `value()`, `{f}`, `.resolved` |

`PartialGraph` calls are in the [partial API](#partial-api) table.

## Testing and benchmarks

```sh
zig build test-ir
zig build test-ir -Doptimize=safe
zig build fuzz-ir -Doptimize=safe -- --cases 10000 --seed 1
```

`test-ir` runs the IR tests and checks the exact output of every IR example.
`fuzz-ir` is a deterministic runner that generates and mutates inputs; it is not
coverage-guided. It covers complete and partial lowering, fixed storage, edge
expansion, adjacency, strict merging, query indexes, streaming and attribute
sessions. It compares direct and step-by-step results under random budgets,
checks adjacency against a separate scan of the edge array, injects memory and
work limits and cancellation, and checks undersized pools and leaks. Inputs and
limits are bounded so the run itself can't expand huge products. A failure
prints the seed, case number and input bytes; replay it with
`zig build fuzz-ir -Doptimize=safe -- --seed 1 --start N --cases 1`. Leave out
`-Doptimize` for Debug, or use `fast`. Generated inputs are UTF-8; UTF-16 and
UTF-32 are covered by the unit tests. Passing is evidence of robustness on those
inputs, not a security guarantee.

Benchmarks (add `-Doptimize=fast`; most also run with `safe` or `small`):

| Step | Measures |
| --- | --- |
| `bench-ir` | Lowering, streaming, materialization, attribute queries and value access |
| `bench-ir-pipeline` | Document-route time and peak memory by phase |
| `bench-ir-events` | Whole-route Document/event construction time, live peaks and Arena capacity |
| `bench-ir-event-sessions` | One-shot versus composed sessions: time, peak/final memory, allocations and credits |
| `bench-ir-materialized` | Bulk attribute folding against compact edge queries |
| `bench-ir-sessions` | Direct and step-by-step materialization, budgets and memory |
| `bench-ir-lowering-sessions` | Direct, metered, cancellable and runtime-policy lowering against sessions; direct calls report no credit counts |
| `bench-ir-edge-sessions` | Direct and step-by-step edge streaming |
| `bench-ir-query-sessions` | Direct and step-by-step `hasEdge` and `contains` |
| `bench-ir-attribute-sessions` | Direct and step-by-step attribute access |
| `bench-ir-query-indexes` | Index build cost, memory and repeated queries |
| `bench-ir-partial` | Partial lowering and queries; `-- --attributes-only` for node and scope iteration |
| `bench-ir-partial-edges` | Partial streaming and folding |
| `bench-ir-fixed` | Fixed lowering: observed capacities, bounds and sessions (sizing and buffer allocation are not timed) |
| `bench-ir-fixed-queries` | Fixed query scratch: throughput, reservation against use, state sizes |
| `bench-ir-fixed-materialization` | Fixed materialization: reservations, build and sizing time, session budgets |
| `bench-ir-adjacency` | Adjacency build, traversal and memory |

Measured results are in [Performance](PERFORMANCE.md).

## Not available yet

- Native-encoding event sessions and fixed event storage; complete/partial
  [event construction](#build-from-events), observers and UTF-8/ASCII sessions are available
- Checking that a port name exists in a node's label, or binding it to the label
- Finding a node by name (`findNode`) in small steps
- Structured `tailPort()`/`headPort()` and value formatting in small steps
- Shared-budget Document construction followed by lowering (the event route already shares one)
- Full cgraph compatibility; see the [known differences](#default-and-update-rules)

See the [roadmap](ROADMAP.md).

## Examples

- [build_graph.zig](../examples/build_graph.zig): one-call parse, nodes and
  streamed edges
- [graph_attributes.zig](../examples/graph_attributes.zig): effective node
  attributes, defaults and implicit empties, and edge values
- [graph_values.zig](../examples/graph_values.zig): value spelling, operands and
  joined text
- [materialized_attributes.zig](../examples/materialized_attributes.zig):
  materialize once, then read edge attributes directly
- [graph_adjacency.zig](../examples/graph_adjacency.zig): walk the edges at each
  node
- [partial_graph.zig](../examples/partial_graph.zig): a partial graph from input
  with a syntax error, its edge colors as known/unknown answers, and its coverage
- [fixed_graph.zig](../examples/fixed_graph.zig): lower into caller-owned storage
- [fixed_edge_stream.zig](../examples/fixed_edge_stream.zig): stream edges and
  attributes with caller-owned scratch
- [resumable_graph.zig](../examples/resumable_graph.zig): lower a Document in
  small steps
- [resumable_edges.zig](../examples/resumable_edges.zig): materialize in small
  steps
- [resumable_edge_stream.zig](../examples/resumable_edge_stream.zig): stream
  edges in small steps
- [resumable_query.zig](../examples/resumable_query.zig): an edge query in small
  steps
- [resumable_attributes.zig](../examples/resumable_attributes.zig): a strict
  edge's attributes in small steps

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.

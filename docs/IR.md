# DOT semantic graph

**Unreleased.** `dot.ir` is an optional layer above the parser. It resolves
logical node identities, scope membership and effective attributes/defaults,
while retaining symbolic connections and source provenance. Ordinary parsing
does not invoke or allocate storage for it.

## Start here

```zig
var result = try dot.ir.parse(allocator, source, .{ .diagnostics = bag.sink() });
defer result.deinit();
const ir = result.ir() orelse return error.GraphUnavailable;

var nodes = ir.nodeIterator();
while (nodes.next()) |node|
    std.debug.print("node {f}\n", .{node.name()});
```

`dot.ir.parse` uses the default UTF-8 DOT profile. It parses once, validates,
lowers accepted input and releases the temporary Document pools. It does not
copy source bytes or expand edges. The result owns the IR; keep the source
alive and unchanged. The pointer returned by `result.ir()` is borrowed from
that result, which must stay alive and unmoved while the pointer is used.

Diagnostics go to the supplied sink. Render the bag on success too: warnings
do not prevent a graph. A null `ir()` means DOT checking rejected **or stopped**;
`result.checking` preserves the parse outcome/completion, validation result,
counts and diagnostic delivery/stop reason. It must not be interpreted as
proof of invalid input. Lowering failures return typed errors and release
temporary storage. This complete-input entry point never publishes partial IR.

See runnable [build_graph.zig](../examples/build_graph.zig). It parses
`digraph { a -> { b c }; "a" -> d; subgraph s { x } }`, reports diagnostics,
and prints:

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

Here `a` and `"a"` are one node, edge endpoints introduce nodes implicitly,
and the isolated `x` remains present. The example streams individual edges
without retaining an expanded edge array; lowering keeps connections symbolic.

## Already have a Document or a custom profile?

Use the existing lowering entry point instead of parsing again:

```zig
const Dot = dot.Profile(.{}); // Your accepting profile.
const IR = dot.ir.Lowering(.{});

var parsed = Dot.parseAndValidate(allocator, source, bag.sink(), .{});
defer parsed.deinit(allocator);
if (!parsed.documentValid()) return error.InvalidInput;
const doc = &parsed.document.?;
var ir = try IR.lowerComplete(allocator, doc, .{
    .interpretation = Dot.interpretation(doc, .{}),
});
defer ir.deinit();
```

Use the interpretation from the **same profile and runtime options** that
accepted the Document. Runtime-policy profiles require `try` when obtaining
their interpretation. The lowering call requires this explicitly so conforming
operators or reading `graph` as generic cannot silently change meaning.

Input must be an accepted, complete parser-produced Document, with its normal
invariants intact. Lowering checks completeness but does not repeat syntax or
policy validation. It rejects partial Documents with `IncompleteDocument`.
Optional child-processor validation is the caller's acceptance decision.

## Partial snapshots for editors

Use `dot.ir.parsePartial` explicitly to retain facts around recoverable syntax
errors. It uses the default DOT profile with partial retention and collection
enabled. Ordinary `parse` and `lowerComplete` remain unchanged.

```zig
var bag: dot.reporting.FixedBag(dot.Diagnostic, 100, .omit) = .{};
var result = try dot.ir.parsePartial(allocator, source, .{ .diagnostics = bag.sink() });
defer result.deinit();
if (result.ir()) |ir| {
    var nodes = ir.nodeIterator();
    while (nodes.next()) |node| {
        switch (node.attribute("color")) {
            .known => |color| std.debug.print("{f}: {?f}\n", .{ node.name(), color }),
            .unknown => |answer| std.debug.print("{f}: {?f} (may change)\n", .{ node.name(), answer.retained }),
        }
    }
}
```

The [partial_graph.zig](../examples/partial_graph.zig) example streams retained
edges and renders diagnostics. For nodes, `a[color=red]; broken -> ; b[color=blue];` retains `a` and `b`, not
the abandoned endpoint `broken`. Red is a retained candidate; blue is known
because its explicit assignment follows the gap. Completed child scopes inside
an abandoned edge also survive, exactly once, without that outer edge.

| Partial API | Meaning |
| --- | --- |
| `result.ir()` | Borrowed `?*const PartialGraph`; null means unavailable, not necessarily invalid |
| `result.checking` | Original parse/validation outcomes, completion, counts and diagnostic delivery; IR publication never makes rejected input valid |
| `ir.state()` | `.complete` or `.partial` semantic coverage; a complete empty graph is complete |
| `ir.kind()` | `Knowledge(GraphKind)`; unfinished `.auto` can remain unknown |
| `ir.nodeIterator()` / `scopeIterator()` | Infallible retained views; scopes include root and merged reopened identities |
| `ir.nodeView(id)` / `scopeView(id)` | Checked constructors for caller-supplied handles |
| `node.name()` / `scope.name()` | Logical name formatter; scope names are optional |
| `node.mentions()` | Infallible iteration of source ranges and owning occurrences using the existing posting index |
| `node.attribute(key)` / `scope.attribute(key)` | Indexed, infallible `Knowledge(?AttributeView)`; `attributeWith(key, options)` is bounded/cancellable |
| `node.attributes(options)` / `scope.attributes(options)` | Bounded, allocation-free iteration of retained keys, yielding `Knowledge(AttributeView)` |
| `findNode(name)` / `hasEdge(from, to)` / `contains(membership, node)` | Bounded `Error!Knowledge(...)`; `With` variants accept limits/cancellation |
| `scope.membership()` | Bounded lookup of the last retained scope membership version, not proof of final contents |
| `ir.gaps()` | Semantic-order coverage records: reason, source range and owning occurrence where known |
| `edgeIterator(options)` / `edgeView(record)` | Retained edge views over the shared expansion engine; checked constructor for caller-supplied records |
| `edge.attribute(key)` / `edge.attributes(options)` | Bounded qualified edge lookup / retained-key enumeration; reuse value/provenance views |
| `materialize(options)` | All retained output or an error; partial-aware owning result, with `.attributes = false` for topology only |
| `nodeCount()` / `scopeCount()` / `connectionCount()` | Retained counts, never counts of missing input; connections remain symbolic |

`Knowledge(T)` is `.known: T` or `.unknown`, with `uncertainty` and an optional
`retained` candidate. For attributes, the candidate is already optional (not a
double optional). Known null means proven absence. Unknown null does **not**.
An implicit empty attribute remains a non-null view with `.resolved.kind = .empty`.
Attribute queries replay DOT
semantics over this snapshot, with ordinary provenance, raw values and operands;
no repaired or cached previous-document values are substituted.

Uncertainty identifies a deterministic earliest relevant source range with
`skipped_input`, `unfinished_input` or `unresolved_kind`; the last can have a null
span and EOF can have a zero-length span. Retained positive node/edge/member
witnesses are known. Negative answers and defaults conservatively depend on all
gaps: node identity is graph-wide, scopes can reopen, and missing input can
introduce catalog keys or earlier object creation. Explicit assignments after
the last semantic gap can still be known. Precomputed boundary/suffix indexes
avoid per-query history or gap scans; bounded attribute queries charge those
index probes against the same allowance as the attribute lookup. Coverage does not certify validity or
inner-markup processing. Strict/generic and ambiguous strict interpretation
remain unsupported rather than guessed.

All iterator exhaustion means **all retained entries**, not all possible entries.
Mention iteration is O(1) to initialize and per record, with no additional index.
Ranges use the original source encoding; traversal follows semantic contribution
order, not a new source sort. IDs/ordering are local to this snapshot and can
change when missing input is filled.

`parsePartial` does not launch lowering after a resource/storage failure,
diagnostic stop/failure, processor stop or incomplete checking operation. The
`.omit` bag above bounds retained diagnostics while permitting continued work;
the default stopping bag deliberately stops even when accepting its last slot.
Render diagnostics and the omitted count. Bounds on retained findings are not
work limits. Parsing and lowering have separate resource options/budgets, just
as in `parse`; custom cancellable/runtime/native profiles use explicit lowering.

For an existing parser-produced Document (complete or retained), use:

```zig
const IR = dot.ir.Lowering(.{});
var ir = try IR.lowerPartial(allocator, doc, .{
    .interpretation = Dot.interpretation(doc, options),
});
defer ir.deinit();
```

`Dot` must match the accepting profile/options, including runtime interpretation.
This low-level call can deliberately lower a stopped parser's retained Document
as a **new** operation; it never resumes parsing. Lowering failures are errors,
not unknown answers or partially built IR. Source remains borrowed; Document
pools may be freed after lowering. Gap metadata and its growth count against
lowering's work/memory limits and `retainedBytes()` / `peakBytes()`. Complete
lowering allocates no coverage storage. Borrowed views/candidates require the
IR to remain alive and unmoved; `_data` and `_coverage` are implementation details.

### Edges without switching graph types

Stay on `PartialGraph` for both complete and incomplete input. The complete-only
`Graph` APIs are unchanged; partial-aware views expose uncertainty instead of
silently converting an incomplete graph into a complete one.

```zig
var edges = try ir.edgeIterator(.{});
defer edges.deinit();
while (try edges.next()) |edge| {
    switch (try edge.attribute("color")) {
        .known => |value| std.debug.print("color={?f}\n", .{value}),
        .unknown => |u| std.debug.print("color={?f} (may change)\n", .{u.retained}),
    }
}

var graph = try ir.materialize(.{});
defer graph.deinit();
var stored = graph.edgeIterator();
while (stored.next()) |edge| {
    const color = edge.attribute("color"); // Infallible indexed lookup; still Knowledge.
    _ = color;
}
```

Both use the existing forward expansion, strict deduplication and attribute
folding engines. Connections remain symbolic until explicitly iterated or
materialized. Non-strict parallel occurrences stay separate; strict pairs merge
retained contributions. An unfinished owner never creates a guessed edge.

Materialization finishes the **operation**, not missing source coverage:
`graph.state()` and `graph.kind()` preserve the input IR's qualified state/kind.
Complete input through this same API yields complete coverage and known answers.
`.attributes = false` returns retained topology without winner maps; its
`edgeIterator()` still returns partial-aware compact views, with bounded
on-demand attribute queries. The default folds once, giving infallible indexed
attribute lookup/enumeration. `attributeWith` and `attributesWith` remain
bounded/cancellable and charge qualification against the same work allowance.

An edge's `from()`, `to()` and raw `edge` record use **retained snapshot
orientation** and first-connection provenance. Missing earlier input can change
the first contribution of a strict pair, including undirected orientation.
Use `edge.orientation()` (`Knowledge` of `{ from, to }`) and
`edge.firstConnection()` (`Knowledge(ConnectionId)`) when that certainty matters.
Their unknown answers include retained candidates. Currently these checks are
conservative across any source gap; directed orientation and non-strict
occurrence identity remain known. Self-loop orientation is unambiguous.

`tailPort()` / `headPort()` also return qualified answers and reuse the existing
structured port views. A candidate belongs to retained `from()` / `to()`, not a
guessed repaired orientation. Strict undirected ports remain uncertain across
gaps even when a later port assignment is retained. Other strict explicit
winners after the last semantic gap can be known. A non-strict edge's own
explicit assignments/suffixes remain known because other statements cannot
update that occurrence. Defaults and absence remain conservative across gaps.

Node, scope and edge `attributes(...)` yield `Knowledge(AttributeView)` for
each retained key
(not an optional attribute inside a known answer). Unknown entries have their
retained candidate, including implicit-empty views. Exhaustion does not certify
that missing input introduces no more keys. Root graph attributes use
`(try ir.scopeView(.root)).attributes(options)`; subgraphs use their scope views.

```zig
var nodes = ir.nodeIterator();
while (nodes.next()) |node| {
    var attributes = try node.attributes(.{});
    defer attributes.deinit();
    while (try attributes.next()) |answer| switch (answer) {
        .known => |value| std.debug.print("{f}={f}\n", .{ value.key(), value }),
        .unknown => |u| {
            const candidate = u.retained.?; // Every enumerated key has a retained value.
            std.debug.print("{f}={f} (may change)\n", .{ candidate.key(), candidate });
        },
    };
}
```

Node/scope iteration uses the existing object-kind key catalog and maps, in the
same order as complete iteration; duplicate assignments yield one winning
value per logical key. It allocates no scratch or retained metadata
(`peakBytes() == 0`). Call `deinit()` even on early exit. Lookup and coverage
share one cumulative work allowance and cancellation token across all `next()`
calls. Errors, including stops during qualification, are terminal and repeat.
An empty iterator does not imply known absence when source coverage is partial.

The source/IR must remain alive, immutable and unmoved; folded edge views also
borrow the materialized result. Returned attribute/port/value views borrow only
the IR. There is no copied source, reparsing, extra winner cache or second
expanded edge list. Streaming errors are terminal and repeat; materialization
returns all retained output or frees it and returns an error. Resource exhaustion
never becomes successful partial materialization. Pull iteration is not a
replenishable-credit session and does not change parser metering guarantees.

Benchmark lowering/query costs with `zig build bench-ir-partial -Doptimize=ReleaseFast`
and expansion/qualified attribute consumption with
`zig build bench-ir-partial-edges -Doptimize=ReleaseFast` (also Safe/Small).
For node/scope enumeration, run
`zig build bench-ir-partial -Doptimize=ReleaseFast -- --attributes-only`.

## What you can read

| API/data | Meaning |
| --- | --- |
| `nodes` / `findNode(logical_name)` | Unique logical node identities, including implicit endpoints |
| `nodeIterator()` | Iterate borrowed node views in first-introduction order, without checked conversions or allocation |
| `nodeName(node)` | Borrowed logical-name formatter for `{f}`; checks the node handle, decodes only when printed |
| `nodeSpelling(node)` | Borrowed first source spelling, in its original encoding, including quotes/concatenation |
| `writeNodeName(node, writer)` | Stream the logical name without allocating a decoded copy or rechecking DOT syntax |
| `scopes` | Semantic subgraphs; named scopes merge within the same semantic parent, anonymous scopes remain distinct |
| `occurrences` | Each written scope body, its source range and immutable membership version |
| `mentions` | Written node references with source spans and owning scope occurrence |
| `connections` | One record per written chain link, with symbolic endpoints, ports, written/effective operators and raw attributes |
| `contains(membership, node)` | Membership in that specific version, without edge expansion |
| `scopeMembership(scope)` | Final version of a semantic scope |
| `hasEdge(from, to)` | Whether any effective connection covers the pair; undirected edges work both ways |
| `edgeIterator(options)` | Stream borrowed edge views in semantic order, without retaining the expanded output array |
| `materialize(options)` | Retain edges and fold effective attributes in one forward pass; `.attributes = false` selects topology-only output |
| `nodeAttribute(node, key)` | Final node value with origin, or absence |
| `scopeAttribute(scope, key)` | Final graph/subgraph value with origin; `.root` is the graph |
| `edgeAttribute(edge, key)` | Final value for a streamed/materialized edge, including strict updates |
| `attributeValue(resolved)` | Borrowed value view: original spelling, operands and joined output |
| `nodeView(id)` / `scopeView(id)` / `edgeView(edge)` | Borrowed component access with `.attribute(key)` and `.attributes(options)` |
| `attributes` / `declarations` | Retained raw attributes and node/default/graph-assignment contributions, separate from effective values |

IDs and membership handles belong to one IR. Don't manufacture them or mix
handles from different graphs. Public membership/query calls bounds-check
handles, but equal numeric IDs from different IRs are not distinguishable.
Keep returned arrays immutable. `text(range)` expects a range from this IR,
as `Document.text` expects a range from its Document.

Names use DOT logical identity: `a`, `"a"`, and `"a" + ""` identify one node.
Queries take logical UTF-8 bytes, not quoted DOT expressions. There is no case
folding, Unicode normalization, numerical normalization, or HTML entity
expansion. If the accepting UTF-8 profile preserved invalid bytes, identity
preserves those bytes too. Hash collisions are checked with logical equality.

`writeNodeName` uses those same logical bytes: native UTF-16/32 names are
written as UTF-8, while byte-profile names preserve their bytes. It does not
expand HTML entities or escape names for any output format. `nodeSpelling`
borrows the source instead; keep that source alive and unchanged. Writer
errors propagate, and a stopped write may have emitted a prefix. There is no
hidden decoded-name cache or allocation (the supplied writer may allocate).

`nodeName` formats the same logical bytes using ordinary writer semantics:
writer failures propagate, with no IR cancellation polling or work budget.
Use `writeNodeNameWith` for explicitly limited/cancellable writes. A formatter
borrows source bytes; do not manufacture or mutate its internal fields. The
iterator and formatter add no retained storage to the IR.

Node IDs follow first introduction, including a left endpoint encountered
before its subgraph endpoint. Connections follow semantic execution order:
nested endpoint-body connections precede their containing statement's links.
These are distinct orderings. Source spans retain original byte offsets.

## Effective attributes

```zig
// digraph { node[color=red]; a; node[color=blue]; b; a[shape=box] }
const node = try ir.nodeView((try ir.findNode("a")).?);
if (node.attribute("color")) |color| {
    std.debug.print("color={f}\n", .{color.value()}); // red
    // color.resolved.kind == .inherited; provenance points to color=red.
}

var attributes = try node.attributes(.{});
defer attributes.deinit();
while (try attributes.next()) |attribute|
    std.debug.print("{f}={f}\n", .{ attribute.key(), attribute.value() });
```

See [graph_attributes.zig](../examples/graph_attributes.zig) for a runnable
example with diagnostics, effective node values and streamed edge values.
Query keys are case-sensitive logical UTF-8 names, just like `findNode`.
Individual attribute lookups allocate nothing and do not expand edge sets.

### Component views and all attributes

`nodeView`, `scopeView` and `edgeView` create small borrowed values, without
allocating or adding owner pointers to stored nodes/edges. Use `scopeView(.root)`
for the graph and another scope ID for a subgraph. Use an `Edge` from this IR's
materialized array with `edgeView`; a node pair alone cannot identify
a non-strict parallel occurrence. The ID-oriented APIs above remain useful when
storing compact handles rather than views. Node/edge iterators yield views
directly: no redundant `try ir.nodeView(...)`/`edgeView(...)` in ordinary loops.
Keep `nodeView(id)` and the other checked constructors for caller-supplied handles.

All three views have `.attribute(key)`, `.attributeWith(key, options)` and
`.attributes(options)`. A node also has `.id` and `.name()`; an edge has its
original `.edge` record and `.from()`/`.to()` node views. A lookup/iteration
entry exposes `.key()` as a logical formatter and `.value()` as a borrowed value
view (also formattable), plus
`.resolved` with the full `ResolvedAttribute` provenance described below.
Formatting an attribute with `{f}` prints its value directly, exactly like
`attribute.value()`, without allocating or escaping. `{?f}` accepts an optional
attribute: absent keys print `null`, while implicit-empty and written-empty
values print no characters. They remain distinct through `.resolved.kind`.

`node.name()` and indexed node/scope `.attribute(key)` access are infallible and
unmetered on valid views. Lookup uses the existing key index and balanced map,
not a history scan; hashing/collision checks still have a cost. Use
`.attributeWith(key, options)` for explicit work limits/cancellation. Edge
attributes, all-attribute iteration and graph queries remain bounded and
fallible: resolving symbolic contributions is not a simple value re-read.

The iterator returns **one final effective value per key** in that object kind's
first-introduction order (semantic traversal order, not alphabetical). It
includes inherited defaults and implicit empties, even when a key was first
written on another object of the same kind. It never returns duplicate written
assignments. Use raw `ir.attributes`/`declarations` for source history.

Each `next()` returns one entry, `null` on exhaustion, or a typed error. Limits
and cancellation accumulate across the iterator, including preparation; an error
is terminal and repeated on later calls. Always `deinit()`, even on early exit
or error. Entries borrow the IR/source, **not** iterator scratch, and remain
usable after iterator cleanup. Keep the IR alive, unmoved and immutable; don't
manufacture or mutate views or copy a live attribute iterator. `edgeView` checks
record bounds; membership and strict first-contribution identity are checked
when attributes are accessed.

Node, scope and non-strict-edge attribute iteration allocate nothing. Strict
edges scan contributions once before the first entry; when matching explicit
assignments exist, a sorted winner table uses **12 bytes per distinct edge key
in the IR**. Repeated updates overwrite those slots, not append history, and
keys belonging only to nodes/graphs need no slots. A strict edge with only
inherited defaults needs no scratch. `.peakBytes()` reports this iterator's peak
requested scratch, bounded by `.limits.max_bytes`. This merges attributes for
one edge, not a whole-graph bulk materialization, and never expands endpoint sets.

Lookups distinguish the cases below. On a view entry, these fields live under
`.resolved`; the ID-oriented methods return `ResolvedAttribute` directly.

| Result | Meaning |
| --- | --- |
| `null` | The key was never introduced for that object kind (graph, node or edge) |
| `.kind = .explicit` | An explicit assignment supplies the final value |
| `.kind = .inherited` | A creation-time default or parent graph snapshot supplies it |
| `.kind = .derived` | An endpoint suffix supplies an effective `tailport` or `headport` |
| `.kind = .empty` | The key exists, but DOT supplies an implicit empty value here |

An explicit `color=""` is still `.explicit`, with `.value = .written`.
A language-defined empty is `.value = .empty`, not a fabricated source range.
No Graphviz renderer defaults (such as an assumed default shape) are added.

`ResolvedAttribute.attribute` is an optional index into `ir.attributes`; it is
null for endpoint-derived values and their introduced empties. `.origin` identifies
the declaration, connection, or `.written_left_port`/`.written_right_port` endpoint;
`.scope` identifies that origin's scope. Derived keys are named by `.port_key`.
Port origins name the written statement side; tail/head follow the stored edge.
For an implicit empty, these identify the catalog's first written assignment,
or the first effective endpoint contribution for a suffix-only key, not a source
assignment of an empty string. A chain shares its written
attribute list, but an explicit edge result identifies the applicable link.
The original key/value ranges remain available, including quotes and HTML-like
delimiters. All ranges use original source-byte offsets.

### Value spelling, operands and joined output

```zig
// a [label="a" + <<b><c>bee</c></b>>]
const value = node.attribute("label").?.value();
// raw() is original spelling in the source's encoding (UTF-8 here).
std.debug.print("raw: {s}\njoined: {f}\n", .{ value.raw().?, value });
// raw: "a" + <<b><c>bee</c></b>>
// joined: a<b><c>bee</c></b>

var parts = value.parts();
while (parts.next()) |part|
    std.debug.print("{t}: {f}\n", .{ part.kind(), part });
// string: a
// markup: <b><c>bee</c></b>
```

See runnable [graph_values.zig](../examples/graph_values.zig). Reading or printing
a value never replaces its source spelling or parses its markup. `ValueKind`
has three cases: `.string` (including numerals), `.markup` and `.concatenation`.
Concatenation preserves all operands, including empty ones and mixed forms.

| Value operation | Meaning/cost |
| --- | --- |
| `kind()` | Infallible on-demand classification; O(first operand length), no stored kind byte |
| `raw()` / `span()` | Original complete spelling/byte range, including wrappers and concatenation glue; null for implicit empty |
| `encoding()` | Original admitted encoding and byte order, including ASCII provenance |
| `parts()` | Allocation-free operand iterator; `next()` is infallible, no preliminary kind scan |
| `{f}` / `writeLogical(writer)` | Stream joined logical DOT content; ordinary writer errors only |
| `toString(allocator)` | Owned joined bytes; caller frees; uses IR work/allocation limits |
| `kindWith`, `partsWith`, `writeLogicalWith`, `toStringWith` | Explicit `dot.ir.Options` limits/cancellation |

Each operand has `kind()` (`string`/`markup`), `raw()`, `span()`, `innerSpan()`,
`encoding()`, `{f}`, `writeLogical[With]`, and `form()` for bare/numeral/quoted/html
spelling. A single value yields **one operand**, including an implicit empty
string whose raw/inner spans and form are null. Written `""` and `<>` have real
spans and different kinds. Absence is still the attribute lookup's null result.

`part.fragment()` returns null for strings; a markup operand returns
`EncodedFragment { input: processor.Fragment, encoding: encoding.Actual }`.
It borrows the markup interior, excluding exactly one DOT angle envelope, and
retains the original file-byte origin. Pass this explicitly to a compatible
markup profile (and its `.encoding` option for native input). The existing
markup Document can then navigate `b` → `c` and borrow `<c>bee</c>` with `raw()`.
There is no second markup IR, automatic processing or result association here.

Joined output removes DOT operand wrappers, `+`/glue, quoted continuations and
lexical quote escapes. It preserves markup tags, reference spellings, unknown
DOT escapes and numeric spellings. DOT `"a&amp;b"` stays `a&amp;b`; decoding
markup text to `a&b` belongs to the markup logical reader. No text extraction,
HTML-safe escaping, rendering or `\N` substitution happens here. Native UTF-16/32
is written as UTF-8; admitted byte-profile contents remain byte-preserving.

Ordinary borrowed access is unmetered, not constant-time. Bounded value traversal
charges inspected/skipped source bytes (including repeated delimiter lookahead),
plus output bytes/native decoding work, before doing that work. It polls inside
long operands and glue; writer calls and allocation are not interruptible.
`partsWith` budgets cover the entire iterator lifetime; errors are terminal and
repeat, never becoming exhaustion. It needs no `deinit()`. This is cumulative
work accounting, not a replenishable session or a latency deadline.

`toString` makes two bounded passes (count, then write) and one exact allocation,
with no growable buffer or cache. Both passes share the work allowance. Failure
frees the output; no successful prefix is returned. Writer-based operations may
have written a prefix on failure. Views/operands borrow the IR and source, not
iterator scratch; keep their owners alive, unmoved and immutable. Do not
manufacture views or change their fields.

### Default and update rules

- Node/edge defaults apply when the object is first created. Changing a default
  does not replace a value on an existing object. Introducing a new key gives
  existing objects without that key an implicit empty value.
- Later explicit assignments update only their supplied keys; omitted keys
  retain their earlier values. Duplicate keys within a list use the last value.
- A subgraph captures parent **graph attributes** when first created. Reopening
  it does not replace that snapshot. Node/edge defaults instead inherit current
  parent defaults unless locally overridden; newly created objects use those
  current defaults. Existing objects still keep their creation-time values.
- A strict edge uses the first covering connection's defaults, then merges
  explicit contributions in semantic order, including overlapping endpoint sets
  and reversed undirected statements. There is no specificity priority.
- Non-strict parallel edges remain independent. `edgeAttribute` takes an `Edge`
  from iteration/materialization, not just a node pair, so it cannot silently
  choose one parallel occurrence's attributes.

These rules have focused comparisons against Graphviz 16.0.0's cgraph behavior.

### Endpoint ports

Endpoint suffixes participate in effective edge attributes without changing
written syntax or adding fake assignments to `ir.attributes`:

| Input/contribution | Effective result |
| --- | --- |
| `a:p:n -> b:q` | `tailport = "p:n"`, `headport = "q"` |
| `a:p -> b [tailport=q]` | Explicit `tailport=q` wins over the suffix |
| `strict digraph { a:p -> b:q; a -> b:r }` | Tail stays `p`; head becomes `r` |
| `strict graph { a:p -- b:q; b:r -- a:s }` | In the first edge's `a`–`b` orientation: tail `s`, head `r` |
| `strict graph { a:p -- b:q; b:r -- a:s [tailport=x] }` | Tail `x`, head `r`; explicit attribute names are not swapped |
| `a:p -> {}` | No pair and no introduced port attribute |

Creation defaults apply first, then suffixes, then the contribution's explicit
attributes. Strict updates retain omitted values. Only suffixes are mapped to
the first edge's orientation; self-loop left/right suffixes remain tail/head.
Chains apply a middle endpoint's suffix to each adjacent link. Port names are
case-sensitive logical DOT identifiers, not markup to process or compass names
to validate. A single `:n` remains the string `n`: it may name a port, and the
IR does not guess its layout meaning.

A derived value has `.kind() == .string`, resolved `.value = .port` (a compact
connection/side reference, not copied port syntax),
and yields one string operand. `raw()`/`span()`
cover from the first identifier through the second, preserving quotes, `+`,
comments and the intervening colon, but excluding the leading node/colon.
`{f}`, `writeLogical` and `toString` join the logical components with `:`.
The operand has null `form()` and `innerSpan()` because it is derived, not a
single written DOT token; `fragment()` is null even for `a:<p>`.

`edge.tailPort()` and `edge.headPort()` expose small borrowed views of the **same
effective winners** as `attribute("tailport")` and `attribute("headport")`.
Tail belongs to `edge.from()`, head to `edge.to()`, in stored orientation. For
compact edges these queries remain fallible/bounded; materialized edges have
infallible indexed lookup. Both offer `tailPortWith(options)` / `headPortWith(options)`.
The returned view's `.resolved` keeps the attribute's kind and provenance;
`.value()` gives its general value view. An implicit/explicit empty is a view,
not `null`. `null` means that the key is absent.

Keep the two readings explicit:

| Access | Meaning |
| --- | --- |
| `port.syntax()` | Winning endpoint syntax, or `null` for an attribute/default/implicit empty |
| `syntax.first()` / `syntax.second()` | Logical first and optional second identifiers, without splitting either |
| `syntax.spans`, `syntax.raw()`, `syntax.span()` | Original source-byte ranges and whole suffix spelling, including intervening syntax |
| `port.graphvizParts()` | Effective logical value split at its **first** colon |
| `parts.name()` / `parts.compassText()` | Text before and optional text after that colon; empty suffix differs from absent |
| `syntax.compass()` / `parts.compass()` | `.absent`, `.recognized` (`dot.ir.Compass`), or `.unrecognized` (the retained text) |
| `syntax.first().asCompass()` / `parts.asCompass()` | A compass candidate, **not** layout resolution; `parts` returns a candidate only without a colon |

For `a:"x:y":n`, syntax retains `x:y` and `n`; the explicit Graphviz reading
returns `x` and the unrecognized suffix `y:n`. For `tailport="x:y:n"`, only the
Graphviz reading is available: there are no endpoint component spans to invent.
Neither reading rewrites or discards the original spelling.

```zig
// A compact edge: lookup may inspect contributions under the IR limits.
if (try edge.tailPort()) |port| {
    if (port.syntax()) |syntax| {
        std.debug.print("written first identifier: {f}\n", .{syntax.first()});
    }
    const parts = port.graphvizParts();
    std.debug.print("name: {f}, compass text: {?f}\n", .{ parts.name(), parts.compassText() });
}
```

A lone `a:n` retains the identifier `n`; Graphviz prefers a shape-defined port
named `n`, otherwise it treats it as a compass. The helpers do not inspect the
shape. Recognition is case-sensitive (`n`, `ne`, `e`, `se`, `s`, `sw`, `w`, `nw`,
`c`, `_`); the enum names `_` as `.automatic`. An absent second component stays
absent: renderer defaults are not inserted. `<p>` in a port is the identifier
`p`, **not** a markup subtree, including through `syntax.first()`.

These text views provide `{f}`, `writeLogical(writer)` and
`writeLogicalWith(writer, options)`. They stream logical bytes through constant-size
scratch, with no allocation or decoded cache. Native UTF-16/32 produces UTF-8;
byte profiles preserve their bytes. Text windows are **not source spans**:
formatting re-reads the underlying value even for a suffix. Splitting and
compass recognition are linear single-value reads, infallible by default, with
`graphvizPartsWith`, `compassWith` and `asCompassWith` for bounded/cancellable
work. Each `With` call has its own work allowance; it is not a resumable session.
All port/syntax/text views borrow only the IR and its source, not materialized
storage. No extra per-edge fields, pools or indexes are retained for these helpers.

All access paths agree: compact queries, all-attribute iteration and folded
materialization. Written catalog keys retain their introduction order; additional
suffix-only keys are appended in `tailport`, `headport` order. An introduced
suffix-only key supplies an implicit empty on other edges; an unintroduced key
is absent. Compact queries discovering these empties may inspect other
port-bearing connections and their partners under the same work/cancellation
limits. They do not allocate or expand Cartesian products. Materialization
discovers introductions during its existing forward pass and remains indexed.

This is endpoint-value resolution only. It does **not** parse a label, check
whether a named port exists, bind a label subtree, or compute attachment geometry.
Source suffixes remain available on every original connection even when an
explicit attribute overrides their effective value.

## Symbolic first; expand explicitly

`{ a b } -> { x y }` is **one connection**, not four stored edges. Membership
uses shared node-mention ranges and immutable scope-prefix snapshots, not
copied ancestor sets. Singleton endpoints carry a node ID directly.

All endpoint versions are captured after the whole edge statement executes.
Thus both ends of `subgraph s { a } -> subgraph s { b }` contain `a` and `b`.
An earlier statement's snapshot does not change when `s` reopens later.

To consume individual edges without keeping them all:

```zig
var edges = try ir.edgeIterator(.{});
defer edges.deinit();
while (try edges.next()) |edge|
    std.debug.print("{f} {s} {f}\n", .{
        edge.from().name(), edge.edge.operator.lexeme(), edge.to().name(),
    });
```

You can stop early with `break`; `deinit()` releases scratch without visiting
the remaining pairs. Keep the IR alive, unmoved and immutable while iterating.
Do not copy a live iterator. Each `next()` returns an edge view, `null` on
exhaustion, or a typed error. An error is terminal: subsequent calls return
that same error, not `null`. Already consumed edges cannot be retracted; a
consumer that needs all-or-nothing publication must stage its own result or
use `materialize`.

Connections are visited forward, and endpoint members follow first-mention
order. Streaming and materialization share this traversal and deduplication.
Non-strict graphs retain parallel occurrences; strict directed pairs are
ordered, strict undirected pairs are unordered. A strict edge keeps the first
connection's orientation and provenance. Ports do not change edge identity.
**All** written contributions remain in `ir.connections`. Use `edge.attribute`
to resolve a value across them (or `ir.edgeAttribute(edge.edge, key)`). The view
borrows context; streaming does not build per-edge attribute indexes.
Materialization resolves attributes by default, as described below. If only
connectivity is needed, topology-only materialization returns compact `Edge`
records without building those indexes. Attributes remain in the IR for later
individual queries; disabling their materialization does not discard them.

To retain just the expanded edge array:

```zig
var graph = try ir.materialize(.{ .attributes = false });
defer graph.deinit();
for (graph.edges) |edge| {
    // edge.from / edge.to are IDs in ir.nodes.
}
```

Materialization uses a collision-checked pair map for strict graphs, indexing
its output rather than retaining a second edge list. Neither expansion path
runs a whole-graph query for every emitted edge.

Strict generic graphs, and strict concrete graphs preserving an operator
inconsistent with their effective kind, return `UnsupportedSemantics`.
Non-strict generic graphs retain both edge kinds. No mixed-kind strict identity
rule is invented here.

### Materialize effective attributes once

The ordinary call retains edges and their resolved effective attributes:

```zig
var graph = try ir.materialize(.{});
defer graph.deinit(); // Before releasing ir or its source.

var edges = graph.edgeIterator();
while (edges.next()) |edge| {
    if (edge.attribute("color")) |color|
        std.debug.print("{f} -> {f}: {f}\n", .{
            edge.from().name(), edge.to().name(), color,
        });
    var attributes = edge.attributes();
    while (attributes.next()) |attribute|
        std.debug.print("  {f}={f}\n", .{ attribute.key(), attribute });
}
```

See [materialized_attributes.zig](../examples/materialized_attributes.zig).
Construction is bounded and fallible; lookup and iteration on its certified views
are infallible. No iterator allocation or `deinit` is needed. The output keeps
the same `edges` records, first-connection ordering and orientation as the
topology-only option. Attribute enumeration follows edge-key introduction order and
includes implicit empties, just like compact attribute iteration. Values, source
spans, winning connection/declaration origins and mixed operands are unchanged.

`edge.attributeWith(key, options)` and `edge.attributesWith(options)` add explicit
work limits/cancellation for reading the folded result. The latter accumulates
its budget across `next()` calls and repeats terminal errors. No lookup scans
connection history or expands endpoint sets.

The forward pass applies every connection's explicit assignments to its visited
pairs, including strict duplicates. An existing strict edge keeps its creation
defaults; later default changes do not replace them. Non-strict parallel edges
stay independent. The algorithm does **not** query the entire compact graph
separately for each output edge.

The result owns its edge array and explicit-winner maps, but borrows the IR's
default snapshots, keys, source values and provenance. Keep the IR/source alive,
immutable and unmoved; edge views/iterators additionally require their materialized
result to stay alive and unmoved. Returned attribute/value views borrow only the
IR. Nothing is copied into a new string or markup tree.
`graph.retainedBytes()` includes output allocation capacities; `graph.peak_bytes`
also includes temporary growth and pair/endpoint scratch, excluding the IR.

Only materialization builds these maps; ordinary parsing, lowering and streaming
do not. `.attributes` defaults to `true`. Set it to `false` when only connectivity
is needed or compact, on-demand attribute queries are preferable. Folding spends
additional time and memory up front; a single read of a simple graph may be
cheaper through compact queries. Defaults are shared, and overwritten explicit
assignments reuse map cells instead of retaining update history.

`.attributes` is a **compile-time** selection because it changes the result's
capabilities: the default returns `IR.Graph.Materialized` with attribute views;
`false` returns `dot.ir.MaterializedTopology` with only the owning `edges` array.
No folding state or code is instantiated in the topology-only path. `limits`
and `cancellation` remain runtime values, including when passed together with
`.attributes`. `dot.ir.Options` also works directly and uses the default
attribute-enabled result. Unknown fields are compile errors.

All output is published together, or an error is returned and storage released.
The operation's `max_pairs`, `max_edges`, `max_work`, `max_bytes` and
`max_attribute_states` apply throughout, including strict duplicates, map updates,
hash probes, scratch and old/new buffers during growth. Here
`max_attribute_states` bounds distinct explicit `(edge, key)` winners, not every
update. Shared defaults and implicit empties need no per-edge cells.
These are total-operation limits and cooperative cancellation, not resumable
metering or hard deadlines.

Endpoint-derived values use the same winner cells as explicit assignments;
repeated port updates replace a winner rather than retaining an update list.
Defaults and empty values are still shared. `.attributes = false` omits all
attribute folding, including endpoint ports, while preserving the source IR.

## Ownership, limits and costs

The IR owns its tables through the supplied allocator and borrows only the
immutable source bytes. Document pools may be released after lowering. Keep
source bytes alive until the IR is released. Materialized edges own their
array but refer to IR-local node/connection IDs; retain the IR to interpret
those IDs and read names or provenance. No source text is copied.

Lowering, streaming and materialization use the supplied allocator. Name access, `findNode`, `contains`,
`scopeMembership`, and `hasEdge` allocate nothing. Pair queries currently scan
symbolic connections; membership uses per-node postings and shared intervals.
This is not a prebuilt adjacency index. Materialization needs memory
proportional to its output, plus deduplication scratch for strict graphs.

Effective node/graph values use immutable balanced maps referencing written
attributes. Creation snapshots share map branches; there is no full default-table
copy per node or descendant scope. Updating a key retains O(log K) map cells
for K distinct keys in that map, plus bounded rotation cells. Reopening a scope
after its parent's defaults change reapplies that scope's local overrides.
Attribute-free input allocates no attribute-state storage. On the measured
64-bit build the node record remains 24 bytes: its state handle uses existing
padding. Layout on another target follows that target's alignment rules.

Node/scope queries perform logical key lookup followed by O(log K) map lookup.
Non-strict edge queries inspect their own connection's list and creation map;
strict queries scan symbolic connections and membership, retaining no expanded
pairs. All probes, comparisons and map/traversal steps are work-limited.
Repeated per-edge queries can therefore cost edges × connections: this is
**not** a bulk attribute-export index. Default `materialize` supplies the
forward-pass path described above. Its explicit-winner maps use
balanced trees: updates/lookups are O(log K) for K explicit keys on that edge,
in addition to pair/index work. Default lookup uses the shared immutable maps.
The operation still visits every contributed pair, including duplicates; output
edge count alone does not bound its work. It retains O(E + A + K_total) output
storage for E edges, A distinct explicit edge/key winners, and K_total edge keys,
plus pair/endpoint scratch. It never creates a dense edges × all-keys table.

All-attribute iteration scans the interned key catalog (including skipping other
object kinds). Node/scope iteration performs a map lookup per relevant key.
Non-strict edges search their own written list per key, then their creation map.
Strict-edge iteration scans symbolic contributions/membership once and merges
explicit writes with O(log K) winner-table comparisons for K edge keys, then
looks up inherited defaults for keys with no explicit winner. It does not rerun
a graph-wide query per key, but enumerating attributes separately for every
strict edge still revisits connections per edge. Formatting keys/values follows
ordinary writer semantics, outside iterator work accounting.

Streaming allocates scratch lazily. Non-strict singleton-to-singleton iteration
allocates nothing. Set endpoints reuse two member buffers and a `u32` mark per
IR node for deduplicating mentions. These buffers grow to the largest endpoints
visited, not to their Cartesian product. Strict streaming additionally retains
compact pair keys and a hash table proportional to unique edges already
emitted: it is **not** constant-memory. Output consumed by the caller is not
part of the iterator's allocation limit.

Finite defaults are defined by `dot.ir.Limits`:

| Limit | Default |
| --- | ---: |
| Unique nodes | 1,000,000 |
| Written scopes, including root | 100,000 |
| Node mentions | 4,000,000 |
| Symbolic connections | 2,000,000 |
| Raw attributes, including assignments | 2,000,000 |
| Persistent attribute-map cells | 8,000,000 |
| Edges emitted or materialized | 1,000,000 |
| Candidate pair visits during expansion | 4,000,000 |
| Accounted work per operation | 100,000,000 |
| Peak live requested allocation bytes per operation | 256 MiB |

## Resumable Document lowering

Opt in through the same execution-policy vocabulary as the parsers. There is
no separate `resumable` switch. This policy belongs to the IR operation: the
profile that parsed a Document does not implicitly select its lowering driver.

```zig
const IR = dot.ir.Lowering(.{
    .policy = .{ .execution = .{ .metering = true } },
});
var operation = try IR.loweringSession(allocator, doc, .{
    .interpretation = Dot.interpretation(doc, .{}),
});
defer operation.deinit();
while (operation.advance(4096).outcome == null) {
    // Yield to the application's scheduler; resume this operation later.
}
var ir = try operation.takeResult();
defer ir.deinit();
```

See [resumable_graph.zig](../examples/resumable_graph.zig). Already parsed and
accepted input has the same prerequisites as `lowerComplete`. Use
`partialLoweringSession` for an explicitly retained partial Document; its result
is the existing `PartialGraph`, with the same retained facts and uncertainty.
Both operations keep edges symbolic. They do not parse the source again,
materialize edges, invoke child processors or change validation outcomes.

### Execution policy and lifecycle

| Setting | Default | Meaning for lowering sessions |
| --- | --- | --- |
| `.policy.execution.metering` | `false` | Enable `advance(budget)`; `run()` remains available either way |
| `.policy.execution.cancellation` | `false` | Enable the borrowed `.cancellation` hook in session options |
| `.policy.execution.cancellation_interval` | `1` | Positive maximum lowering credits between hook polls; every resume also polls, including budget zero |
| `.runtime_policy` | `false` | Allow session options `.policy` to override the compiled baseline at initialization |

Fixed policies are checked at compile time. With `.runtime_policy = true`,
`IR.validatePolicy(override)` checks an override independently; construction
also resolves and checks it once. Runtime `advance` returns `MeteringDisabled`
without doing work when metering is disabled; the fixed-policy equivalent is a
compile error. Runtime policy changes settings, not the lowering implementation.
There is no mid-session policy replacement. Direct `lowerComplete`/`lowerPartial`
keep their existing throughput-specialized driver and explicit limits/cancellation
options, even on a profile that enables metered sessions. Existing materialization
sessions remain explicitly selected through their own API below.

`LoweringSession` and `PartialLoweringSession` expose `advance(u32)`, `run()`,
`cancel()`, `peakBytes()`, `takeResult()` and `deinit()`. The lifecycle matches
materialization sessions: zero grants do no semantic work, positive grants make
progress, terminal outcomes are latched, and ownership transfers once after
success. `LoweringProgress` reports this call's `work_used`, cumulative
`total_work`, factual `nodes_created`/`connections_created`, and optional
`LoweringOutcome` (`success` or `failure`). Progress counts are not published IR.
`run().work_used` is the last internal advance's count, not its lifetime total.

Construction binds input/options and checks admission; it performs no scan or
allocation. Keep the immutable Document, source and active session alive and
unmoved until lowering finishes and the result is taken. After successful transfer,
the IR borrows only source bytes: Document pools and session scratch can be freed.
An execution pause is not a partial source. Cancellation, allocation/limit failure
and unfinished work never publish a half-built IR; `takeResult()` returns
`NotReady`, the actual failure, or `AlreadyTaken` as appropriate. `deinit()` is
required on every path, including after successful transfer.

### Lowering work units

One credit performs one bounded transition:

| Work | Maximum per credit |
| --- | --- |
| Counting/traversal/indexing | One order slot, chain link, scope, mention or phase transition |
| Identity hashing/equality | One byte (byte profiles), native scalar (at most two UTF-16 code units), glue unit, pending UTF-8 output byte or hash-table probe |
| Persistent attribute maps | One tree visit or ancestor update, with at most two rotations/five appended cells |
| Buffer growth/initialization | At most 64 bytes copied/cleared, or one bounded storage-preparation transition |

Long names, concatenation comments, hash-table rehashes, scope-default overlays
and membership/posting preparation all yield. Budget one needs no minimum
larger grant. Hash collisions still require logical equality; native validation
and byte-profile byte preservation match direct lowering. Total credits include
actual growth copies, so comparisons between budget partitions require the same
allocator resize behavior. Intermediate work units need not equal the direct
driver's coarser `max_work` accounting. Configured lifetime limits still stop
the operation; pausing does not replenish them.

Allocator callbacks, cancellation predicates and destruction are external work,
not latency-bounded operations. This is cooperative work metering, not a deadline.
No thread or shared parse-plus-IR budget is introduced. Fixed-storage lowering,
event lowering and resumable query/edge-streaming operations remain separate work.
Measure this path with `zig build bench-ir-lowering-sessions -Doptimize=fast`.

## Resumable materialization

Keep `materialize(.{})` for a direct call. Opt into a session when your
application needs control **during** expansion and attribute folding:

```zig
var operation = try ir.materializationSession(.{});
defer operation.deinit();

while (operation.advance(4096).outcome == null) {
    // Yield to your application's scheduler here if needed.
    // Keep operation, ir and source alive and unmoved until the next advance.
}
var graph = try operation.takeResult();
defer graph.deinit();
```

In an event-driven application, store the operation and call `advance` once
per scheduling turn instead of spinning this loop. No thread, clock, callback
dispatch or automatic yielding is introduced. See
[resumable_edges.zig](../examples/resumable_edges.zig) for a runnable example.

Options have the same form as `materialize`: compile-time `.attributes = false`
excludes folding; `.limits` and `.cancellation` are runtime values. Omitted
limits inherit the IR's baseline. Named session types are
`Graph.MaterializationSession(true/false)` and the corresponding types on
`PartialGraph`. `takeResult()` returns exactly the existing materialized type.
A partial source stays partial even when the operation finishes successfully.
An unfinished operation is a **pause**, not a new partial graph.

| Method | Contract |
| --- | --- |
| `advance(budget: u32)` | At most `budget` defined steps; exhaustion yields without losing progress. |
| `run()` | Drives the same machine to a terminal outcome, honoring total limits and cancellation. |
| `cancel()` | Permanently cancels an active operation; terminal outcomes are unchanged. |
| `takeResult()` | Transfers finished output once; `NotReady` while active, `AlreadyTaken` after transfer, actual error on failure. |
| `peakBytes()` | Peak requested bytes, including scratch and overlapping old/new growth buffers. |
| `deinit()` | Frees scratch, pending growth buffers and any untransferred output, including after failure. |

`advance` and `run` return `dot.ir.MaterializationProgress`: `work_used` for
that advance, `total_work: u64`, factual `pairs_visited`, `edges_created`, and
optional `outcome`. Outcome is `.success` or `.{ .failure = error.… }`;
null means still active. `run().work_used` is its final advance's count;
`total_work` remains cumulative. Edge counts before success are progress only,
not published edges or final attributes. Repeated calls after termination do
no work and preserve the outcome; explicit cancellation does not erase a prior
resource error or success. `advance(0)` polls cancellation without semantic work.

### Session work units and limits

One credit is one bounded state transition, not one edge and not a byte count:

| Work | Maximum per credit |
| --- | --- |
| Endpoint traversal | One body or mention, or one singleton/phase transition |
| Pair expansion/deduplication | One candidate, one hash-table probe, or one rehash entry/probe |
| Attribute folding | One attribute, AVL node visit or ancestor update (at most two rotations) |
| Port-key comparison | One original source code unit, including concatenation glue/comments |
| Buffer copying/initialization | At most 64 bytes |
| Storage preparation | One bounded transition with allocation/resize/free calls; no hidden library copy |

Initial construction only binds the IR/options and polls cancellation; it does
not scan, allocate, expand or run an unmetered sizing pass. Positive budgets
advance even with budget one. Cancellation polls at every resume and before
each credit, including while initializing tables, copying growth buffers and
walking long names. This leaves DOT, markup and string accounting unchanged.

The driver specializes cancellation presence once per resume and has a compact
one-credit entry into the same transition machine. Neither optimization batches
credits or reduces polling: budget one uses the entry poll for its only step;
larger budgets poll before each additional step. See the
[session measurements](PERFORMANCE.md#resumable-ir-materialization-2026-10-24)
for measured costs versus the direct driver.

Per-call exhaustion is resumable; cumulative `limits.max_work`, memory/edge/
pair/map limits, allocation failure and cancellation are terminal. A rejected
product is checked before its expanded edges are allocated. No terminal failure
publishes a partially materialized graph. Session storage remains owned until
`deinit`, which is also required after a successful `takeResult` for scratch.
The transferred result owns its buffers and, when attributes are included,
continues borrowing the IR and source. Do not copy active sessions or owning
results; borrowed views do not extend their owners' lifetimes.

For the same allocator behavior, results and total credits are independent of
budget partitioning. Credits include actual copying, so an allocator accepting
in-place growth can consume less work and peak memory than one requiring a move.
Yielding never replenishes the lifetime allowance. Session credits differ from
the direct driver's coarser cumulative accounting: the same small `max_work`
need not admit both. Values/order/provenance agree when both complete.

This is a cooperative **work bound**, not a latency deadline. Allocator calls,
the cancellation predicate and destruction are external/unmetered; the backing
allocator can reserve or initialize memory internally. Library-controlled copies,
table initialization and rehashing are resumable. Fixed-storage sessions,
resumable queries and edge-streaming are not implemented by this slice.
The session's raw allocation boundary also avoids the standard typed helpers'
whole-buffer debug poisoning; all readable elements are initialized explicitly.

## Applying resource options

Set a compile-time baseline with `Lowering(.{ .limits = ... })`, or pass
`.limits` at lowering. `findNodeWith`, `writeNodeNameWith`, `hasEdgeWith`, `edgeIterator`, and `materialize` accept
operation-specific `.limits` and `.cancellation`; so does
`materializationSession`. There is no unlimited-by-zero
special case. Counts/indices are `u32`, pair/work totals are `u64`; byte limits
use the allocator's `usize` domain. Candidate products use checked arithmetic.
`nodeAttributeWith`, `scopeAttributeWith` and `edgeAttributeWith` accept the
same options. `max_attribute_states` bounds retained map cells; exhausting it
returns `AttributeStateLimit`, with no incomplete IR published.

Iterator limits accumulate across all `next()` calls; they do not reset per
edge. Pair visits include strict duplicates, while `max_edges` counts emitted
edges. Streaming can consume a small prefix of a product larger than its pair
allowance; attempting to visit the next pair beyond the allowance returns
`PairLimit`. Materialization, which promises a whole result, rejects an
over-budget connection product before allocating its expanded output.

For `dot.ir.parse`, `.dot` supplies ordinary default-profile `CheckOptions`
(parse/validation resources); `.lowering` supplies the IR operation options.
IR limits/cancellation apply to lowering only, not to DOT parsing/validation
or a combined peak across both stages. The temporary Document overlaps IR
construction before it is released. There is no shared budget or metered
session in this convenience call. Use explicit profiles/lowering when those
stages need different policies or source encodings.

Limits or cancellation return typed errors, **never** `false`, absence, or a
truncated graph presented as complete. One-shot failure frees operation-owned
storage; an iterator must be `deinit()`ed on failure or early exit too.
For direct calls and pull iterators, work limits count table probes, comparisons and traversal work; they are not
wall-clock deadlines. Cancellation is cooperative. Existing trusted-name
primitives are charged by their byte lengths and polled around each call;
allocation, copying during growth, and an individual name operation are not
interruptible. An iterator polls during endpoint traversal, pair visits and
deduplication, including when one `next()` skips many duplicates. A call may
need to enumerate whole endpoint memberships before yielding an edge. Pull
iteration allows stopping between edges, but is **not** a fixed-work-per-call
metered session with replenishable credits. Use `materializationSession` when
bounded expansion is needed. None of this changes the parser's
existing metering or cancellation guarantees.

`retainedBytes()` reports retained allocation payload including spare capacity.
`peak_bytes` includes temporary scratch and overlapping growth buffers, but
excludes source/Document storage, allocator metadata and process RSS. A
materialization peak excludes the already-retained IR. `edges.peakBytes()`
reports the corresponding iterator scratch peak. Arena allocators may
retain freed blocks or reserve extra chunk capacity; use a bounded backing
allocator when that physical capacity must have a hard cap.

UTF-8 is the default. To lower native Documents, enable the corresponding
readers with `Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } })`.
The Document supplies the actual encoding and original byte ranges. Unused
native readers remain compiled out.
ASCII-admitted Documents are also readable by the UTF-8 configuration. Native
logical-name/value decoding can return `InvalidIdentifier` if the accepting
parser left encoding validation off and a name or attribute value contains
malformed code units. Native values are checked while lowering, before exposing
their formatters; byte-profile values preserve their raw bytes.

## Verification

```sh
zig build test-ir
zig build test-ir -Doptimize=ReleaseSafe
zig build bench-ir -Doptimize=ReleaseFast
```

The benchmark reports lowering separately from parsing, materialization and
streaming, including strict deduplication and a 1,000-edge prefix of a
50,000 × 50,000 endpoint product. It reports retained/requested peak bytes and
arena capacity separately. This is the first
production topology baseline, not a comparison with a previously shipped IR.
Recorded numbers are in [Performance](PERFORMANCE.md#document-to-ir-topology-unreleased-2026-10-21).

The same command also reports attribute-bearing lowering and direct query costs,
including shared defaults, repeated updates, reopened/deep scopes and a symbolic
product. The bulk attribute benchmark compares construction, full attribute
consumption, retained/requested peak bytes and total arena capacity with compact
queries. Run it alone with `zig build bench-ir-materialized -Doptimize=ReleaseFast`.
Compare direct materialization with session `run()` and budgets 1/64/4096 using
`zig build bench-ir-sessions -Doptimize=fast`. It consumes the same results and
reports time, actual credits, retained/requested peak bytes and session state
size. Label-port existence/binding, event-based/resumable lowering, resumable
queries/streaming and fixed-storage IR construction remain later work.

The final section measures value kind/operand access, joined output, bounded
writing and exact-allocation `toString`, plus a benchmark-only kind cache.
See the [value-access comparison](PERFORMANCE.md#value-access-and-view-producing-iterators-2026-10-22)
for memory results, the on-demand classification decision and the remaining
reopened-subgraph streaming caveat.

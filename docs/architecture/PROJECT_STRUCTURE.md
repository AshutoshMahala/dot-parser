# Project Structure

Status: living document — updated as slices land  
Last updated: 2026-09-27 (common/DOT/markup source separation)

The package provides independent Zig DOT and markup modules and must not depend
on Zigraph. Source directories separate language-owned implementation from shared
mechanisms; the public module names remain `dot_parser` and `markup_parser`.

## Design rule

Start with a small physical layout and split modules only when responsibilities
actually grow. Architectural boundaries are important from the first commit;
having one file per hypothetical future feature is not.

The [optional execution contract](EXECUTION_CONTRACT.md) defines implemented
bounded parsing and cancellation, now available for caller-owned fixed storage.

## Current layout

```text
dot-parser/
├── build.zig
├── build.zig.zon
├── CHANGELOG.md
├── LICENSE-APACHE
├── LICENSE-MIT
├── README.md
├── src/
│   ├── root.zig               (dot_parser public facade)
│   ├── markup.zig             (markup_parser public facade)
│   ├── support.zig            (shared parser_support build-module root)
│   ├── common/                (no grammar or retained-document dependencies)
│   │   ├── location.zig
│   │   ├── reporting.zig      (typed fixed/growing/streaming diagnostic sinks)
│   │   ├── execution.zig      (borrowed cancellation hook)
│   │   ├── processor.zig      (generic policy/fragment preparation, not scheduling)
│   │   ├── stack.zig          (frame- and index-typed nesting storage)
│   │   └── wdp.zig            (identity hashing, not language-specific registries)
│   ├── dot/
│   │   ├── policy.zig         (typed inputs, resolution, pure verification)
│   │   ├── profile.zig        (compile-time/runtime policy-bound facade)
│   │   ├── parse_engine.zig   (DOT storage adapters and specialized drivers)
│   │   ├── diagnostic.zig
│   │   ├── console.zig
│   │   ├── lexer/
│   │   │   ├── lexer.zig      (backend selection and equivalence tests)
│   │   │   ├── token.zig      (vocabulary shared by the DOT scanner backends)
│   │   │   ├── scalar.zig     (one byte per credit; the default)
│   │   │   └── block.zig      (64-byte block masks; opt-in)
│   │   ├── identifier.zig
│   │   ├── identifier_value.zig
│   │   ├── syntax_event.zig
│   │   ├── parser.zig
│   │   ├── scratch.zig        (explicit reusable nesting frames)
│   │   ├── syntax.zig
│   │   ├── validate.zig
│   │   └── validation_checks.zig
│   └── markup/
│       ├── policy.zig
│       ├── profile.zig
│       ├── lexer.zig
│       ├── parser.zig
│       ├── engine.zig
│       ├── scratch.zig
│       ├── syntax.zig
│       ├── validate.zig       (independent duplicate-attribute checks)
│       ├── diagnostic.zig
│       └── result.zig
├── tests/
│   ├── integration.zig
│   ├── markup.zig             (standalone markup consumer tests)
│   ├── parser_modules.zig     (coexistence and shared type identity)
│   ├── policies.zig
│   ├── policy_settings.zig
│   ├── compile_fail/          (public compile-time policy constraints)
│   ├── freestanding_policy.zig
│   ├── freestanding_markup.zig
│   ├── attributes.zig
│   ├── edge_chains.zig
│   ├── ports.zig
│   ├── subgraphs.zig
│   ├── subgraph_endpoints.zig
│   ├── sessions.zig
│   ├── freestanding_session.zig
│   ├── diagnostics.zig        (probe table: identity, location, wording)
│   ├── measure.zig            (count-only dry run equals retained pools)
│   └── corpus/
│       ├── README.md          (corpus governance)
│       ├── valid/
│       ├── invalid/
│       └── unsupported/       (recognized-but-deferred constructs)
├── examples/
│   ├── markup.zig
│   ├── parse_undigraph.zig
│   ├── policies.zig
│   ├── fixed_buffer.zig
│   ├── diagnostics_demo.zig
│   ├── identifiers.zig
│   ├── attributes.zig
│   ├── bounded.zig
│   ├── edge_chains.zig
│   ├── ports.zig
│   ├── subgraphs.zig
│   ├── subgraph_endpoints.zig
│   └── check_file.zig         (command-line checker: recovery + renderer)
├── bench/
│   ├── markup.zig             (standalone fixed/runtime/count-only parsing)
│   ├── throughput.zig         (parse + validate, retained memory)
│   ├── policies.zig           (fixed/runtime policy costs; no recorded baseline yet)
│   ├── lexer.zig              (lexical fixtures, no timed allocation)
│   ├── session.zig            (independent execution-policy costs)
│   └── subgraphs.zig          (sibling/deep scope costs)
└── docs/
    ├── MARKUP.md
    ├── SUPPORTED_SYNTAX.md
    ├── SUBGRAPHS.md
    ├── OWNERSHIP.md
    ├── OUTCOMES.md
    ├── POLICIES.md
    ├── EXECUTION.md
    ├── BASELINES.md
    ├── architecture/
    │   ├── PROJECT_STRUCTURE.md
    │   └── EXECUTION_CONTRACT.md
    └── internal/              (contributor-facing requirements and questions)
```

Unit tests live beside the code they exercise. `tests/integration.zig`
tests the public API exactly as an external consumer, and `tests/corpus`
holds reusable DOT inputs grouped by expected outcome class (see its
README for the governance rules).

## File responsibilities

### Module roots, `src/common/` and `src/markup/`

`markup_parser` is an independent build module rooted at `src/markup.zig`, with
its implementation under `src/markup/`.
Its scanner, iterative event grammar, storage consumers, diagnostics and policy
are markup-owned, not adapters around DOT. Slices 1–2 cover text, elements, quoted
attributes and independent duplicate validation; the
[consumer guide](../MARKUP.md) lists exact coverage. Retained nodes form preorder
subtree intervals with a sparse owner-indexed attribute pool; fixed/growing/count-only
consumers share one parser. Validation uses explicit temporary per-element scratch. Public
events and DOT composition remain deferred. The
[internal slice record](../internal/MARKUP.md) separates future grammar from code.

Both build modules depend on one `src/support.zig` module exposing `common/`
location, reporting, cancellation, generic processor preparation and WDP hashing.
DOT and markup also instantiate the shared nesting-stack mechanism with their
own frame types and unchanged index widths.
This preserves shared Zig type identity when both parsers are imported without a
grammar dependency in either direction. `common/` owns mechanisms, not DOT or
markup policies, diagnostic payloads, grammars, output models or renderers.
Existing `dot.processor` access stays unchanged; moving its generic implementation
does not add processor composition to markup or create a new public module.
Direct CLI compilation wires `--dep parser_support` for each parser and supplies
`-Mparser_support=src/support.zig`; package consumers receive this automatically.

### `src/root.zig`

The DOT public surface over `src/dot/`. Like `src/markup.zig`, it owns public
facade types and re-exports intentionally public building blocks and convenience
entry points. Root files do not implement scanning or grammar, and must not expose
internal storage layouts merely because they are convenient during development.

### `src/common/location.zig`

Small source primitives:

- `Span` (also `Range`): start offset and byte length, eight bytes — the
  only position the library stores, in tokens, events, diagnostics and
  retained records alike.
- `Location`: byte offset, physical line, and byte column, derived on demand
  by `locate` / `Span.locate`, or through a `PositionCursor` for many.
- One newline policy for LF, CRLF, and CR.

This module performs no allocation and does not interpret Unicode display
width.

### `src/dot/diagnostic.zig`

WDP diagnostic identities and typed diagnostic fields:

- Diagnostic severity and code. Components are logical domains (`Syntax`,
  `Validation`, `Resource`, `Profile`), never source modules; a code names
  one condition and the grammar position travels in the payload.
- Source location/span, plus typed related locations (the open delimiter,
  the suspect misindented brace).
- Parse/validation outcome categories.
- Fixed-capacity and streaming diagnostic sink helpers.

Human-readable catalogs, localization, JSON, and runtime hashing do not belong
in the initial core; `console.zig` is the optional renderer that turns the
payloads into wording and is dropped by the linker when unused.

### `src/dot/lexer/`

The raw-byte scanner: one interface, two implementations. It is the first
subsystem to get its own directory, as its responsibilities grew to four files.
`Policy.scanner` selects `scalar.zig` (the default) or `block.zig`: fixed profiles
specialize one, while runtime profiles select a specialized engine at operation
or session initialization. `lexer.zig` supplies the factories and differential
tests that hold both backends to identical output.
`token.zig` carries the `Token`, `Result` and keyword-folding definitions
they share. `root.zig` selects `Token`, `Result`, ordinary `Lexer`, `For`
and the backend enum for the public namespace; internal resumable factories and scan
drivers are not re-exported. The scanner recognizes:

- Every DOT keyword (`graph`, `digraph`, `strict`, `node`, `edge`, and
  `subgraph`), case-independently. Keywords always tokenize;
  whether one is legal in its position is the parser's decision.
- Bare byte-oriented identifiers (ASCII plus bytes 0x80–0xFF), numeral, and
  quoted identifiers (including `+` concatenation).
- `{`, `}`, `;`, `:`, `[`, `]`, `=`, `,`, `--`, and `->`.
- Whitespace and physical line endings (LF, CRLF, standalone CR); a leading
  UTF-8 byte order mark is skipped.
- Comments, skipped without retaining trivia (see [supported syntax](../SUPPORTED_SYNTAX.md)).
- End of input, invalid bytes, malformed operators (`-`, `-->`) and
  incomplete numerals (`.`, `-.`), each its own typed failure; a numeral
  running into a letter or second dot raises a warning the parser forwards.
- Introducers of deferred HTML identifiers, reported as typed
  unsupported-feature failures.
- Resumption after a failure, so the parser's statement-boundary recovery
  can continue past malformed bytes.

It borrows source spans, performs no hidden allocation, and owns no AST types.
Ordinary lexing and the private metered parser share one resumable scanner.
Metered scanning can yield within every supported lexical form; public parsing
can run to completion or through fixed-storage sessions. Budget/frontier counters compile out of
ordinary lexing; shared continuation-state and throughput costs are recorded
in [baselines](../BASELINES.md).

The scalar scanner walks one byte per step through a small state machine. The
block scanner classifies each 64-byte block into bit masks with vector
compares (byte classes, newlines, quotes with backslash parity carried across
blocks, comment delimiters) and runs a token machine over the masks, advancing
a whole run or delimiter search per step and never past the block; its state
is 160 B against 56 B. The [execution contract](EXECUTION_CONTRACT.md) gives
each backend's credit accounting, and the benches take `-Dlexer=scalar|block`
to compare them.

### `src/dot/identifier.zig`

Explicit logical-value decoding over one raw identifier expression. Uses the
lexer to validate spelling, then emits decoded chunks into caller memory or a
writer. It performs no allocation, caching, Unicode normalization, layout
escape interpretation, or numeric conversion. The document offers convenience
methods over this module without adding fields to retained records.

### `src/dot/parser.zig`

The parser state machine and a private, provisional syntax-event contract. It
parses one document and emits source-shaped events. It does not allocate AST
nodes directly and does not know about graph engines.

Under the opt-in `recovery = .statements` policy a body syntax error aborts
the sink once and the grammar keeps running for diagnostics only,
resynchronizing at `;`/`}`; the default remains fail-fast.

Public facades offer run-to-completion and fixed-storage sessions. The metered specialization
separately charges scanning, grammar transitions, and event attempts, retaining
one token and pending action across yields. The ordinary specialization uses
the same grammar with immediate callbacks and no pending-work/progress fields.
Cancellation adds a borrowed hook and polls before each microstep. It can be
selected independently of metering; disabled features compile out. `root.zig`
owns the fixed-session API, lifetime rules, and public storage-failure mapping.

### `src/dot/syntax.zig`

The borrowed, index-based syntax document (`Document`) and its two builders
(allocator-backed and fixed-storage). The builders are the first consumers
of the private syntax-event contract.

Document data includes:

- Document kind (`undigraph` or `digraph`), the `strict` marker, and the
  optional graph name.
- Ordered statement IDs, including standalone subgraph owners in preorder.
- Compact scope occurrence records with parent IDs, source ranges and body
  intervals; allocation-free direct/recursive views and scope-aware traversal.
- Node statements.
- Edge statements with the written operator and compact node references.
- Inline bare identifier ranges or pooled qualified occurrences, exposed through
  checked reference views. Port suffixes remain raw first/optional second IDs.
- Chain statements with a first edge and compact continuation-link range;
  no eager pairwise expansion. The edge iterator provides an allocation-free view.
- Standalone assignments and graph/node/edge attribute statements.
- Ordered key/value pairs in an attribute pool, referenced by compact ranges;
  adjacent groups are flattened and duplicate keys are preserved.

The document preserves written statements. It does not synthesize implicit
nodes from an edge statement.

### `src/dot/validate.zig`

Validation over syntax data. It completes after independent validation errors
and writes them to a caller-supplied diagnostic sink or bag. Parsing is
kind-agnostic; default validation requires `--` for an undigraph and `->` for a
digraph. Profile-selected treatment, severity and reading specialize this same
validator rather than creating a second parser. Warning/error occurrence counts
are independent of diagnostic delivery. It preflights explicit validation scratch,
then merges only enabled finding streams in source order. Fixed-off streams and
their state are excluded; runtime-off streams do not inspect the input.

### `src/dot/validation_checks.zig`

Independent finding streams for operators, whole-source UTF-8, repeated attribute
keys and consumer restrictions on effective kinds, ports and subgraphs. Shared
kind resolution also serves interpretation. Only repeated-key analysis needs
caller workspace: one temporary key index per attribute, sorted by decoded-byte
identity and back into source order, with no retained graph mutation, decoded
string allocation or unbounded hash-bucket scans. Lexical numeral severity is
applied by the parser/scanner, not replayed by document validation.
Private `identifier_value.zig` shares validated-expression traversal between
safe public decoding and logical key comparisons; unchecked helpers are not
exposed on the public identifier API.

### `src/dot/policy.zig` and `src/dot/profile.zig`

`policy.zig` owns source-independent typed inputs, per-leaf resolution and pure
verification. `profile.zig` binds a compile-time baseline, conditionally exposes
runtime overrides/error returns, and composes parsing, measurement and validation.
It receives the facade type as a comptime argument to avoid importing root back
through a module cycle. Interpretation derives auto facts once per immutable
document without adding retained syntax fields. The [policy guide](../POLICIES.md)
records all migrated settings and session ownership/cost contracts.

### `src/dot/parse_engine.zig`

Allocator-backed, fixed-storage and count-only adapters share the grammar in
`parser.Machine`. Fixed policies capture limits/recovery at compile
time; runtime policies retain only resolved parse-stage values. Scanner and
execution choices select an engine before scanning. Fixed-storage sessions
retain one driver, rebind self-pointers before driving, and latch results once.
Runtime `Profile.Session` wraps one tagged union plus its latched validation
selection; reset verifies before cancelling or overwriting old state. Allocator
callbacks and source-sized pool growth are never advertised as budgeted work.

There is no second parser-options schema or compatibility machine wrapper.
`Machine` consumes `policy.ParseSettings` directly, separately from borrowed
scratch; direct event-sink fixtures live in its test-only namespace. Default
facade functions delegate to the default `Profile`, including validation.

## Further splits only when needed

The language boundary is now explicit: keep DOT-specific refinements under
`dot/` and markup-specific refinements under `markup/`. Split lexer, parser,
syntax storage or validation files further only when implemented responsibilities
justify it. Future DOT IR, lowering, semantic checks and graph adapters remain
DOT-owned; they do not belong in `common/`.

Promote source/encoding adapters, observability or tooling helpers into `common/`
only when they have a genuinely language-independent contract. Do not create
placeholder directories, universal policy/outcome types, or a shared grammar
engine merely to make the two parsers look alike.

Engine-specific adapters should normally live in their own packages or
repositories. This repository may contain generic adapter contracts and example
targets, but not a Zigraph dependency.

## Dependency direction

Each language depends on shared mechanisms, never the reverse. DOT and markup
internals do not import each other; a future composition adapter must not make
either standalone parser depend on the other's grammar. Within each language,
the layers below apply (DotIR, lowering and engine adapters remain future work):

```text
common primitives
  ↑
language-owned source scanning and lexer
  ↑
parser and private syntax-event contract
  ├──→ syntax builder and syntax tree
  ├──→ direct event consumers
  └──→ drivers

syntax tree
  ├──→ validation
  ├──→ DotIR lowering
  └──→ optional tooling

DotIR
  ├──→ semantic validation
  ├──→ documentation and analysis
  └──→ generic engine-target adapters
```

Forbidden dependencies:

- Common primitives must not depend on either language's lexer, parser, AST,
  policies, diagnostic payloads, IR, logging, or an engine.
- Lexer must not depend on parser, AST, or IR.
- Parser must not depend on an AST builder or engine.
- Syntax-tree storage must not depend on validation or `DotIR`.
- `DotIR` and adapters must not leak back into parser types.
- Observability must not become a required logging dependency.

## Ownership and memory boundaries

```text
Source bytes        caller-owned; borrowed for as long as spans are used
Parser state        temporary; fixed-size plus explicit scratch memory
Syntax tree         mid-term; caller allocator/arena/fixed buffer
Validation bag      caller-selected: streamed, fixed, or arena-backed
DotIR               optional mid/long-term caller-owned storage
Engine data         owned entirely by the engine adapter/consumer
```

No module may silently promote borrowed data into long-term ownership. Copying
must be requested explicitly and supplied with explicit memory.

## Public versus provisional contracts

During the experimental `0.x` phase:

- `root.zig` and `markup.zig` convenience functions are public but unstable.
- The syntax-event sink remains private/provisional.
- Syntax-tree types may change while the first slices teach us their real shape.
- `GraphTarget` is deferred until `DotIR` exists.
- No stable ABI or serialized tree format is promised.

## Test organization

Use four complementary levels:

1. **Unit tests:** colocated with location, lexer, parser, storage, and validation
   code.
2. **Public integration tests:** import `dot_parser` or `markup_parser`, just as
   consumers do; coexistence tests also verify shared primitive type identity.
3. **Corpus tests:** DOT files grouped by outcome class (valid, invalid,
   unsupported) with expected statements, diagnostics, or features.
4. **Property/fuzz tests:** `std.testing.fuzz` harness with determinism
   checks; every discovered regression becomes a permanent small test.

Every module that accepts memory must be tested with a deliberately undersized
fixed buffer. Every parser boundary should be tested with input truncated at
each byte position.

## Standalone scope storage

Subgraphs are records plus intervals into the single global statement order, not
separately allocated child trees. Root is scope zero; subgraph IDs identify source
occurrences. Scope views add no retained membership index. Iterators skip body
intervals for direct traversal or scan descendants iteratively for recursive views.
Global scope-aware traversal ascends parent links amortized linearly.

`scratch.zig` owns only the nesting-frame representation/stack mechanics.
The facade owns its lifetime; the parser borrows it and pushes/pops in constant
fixed-storage work. Builders retain parent IDs independently, closing body/source
ranges on exit. Allocator-backed scratch can use a separate temporary allocator;
fixed parsing receives a document/scratch memory bundle. Neither parser nor
builder uses input-dependent recursion or integrates graph-engine semantics.

Endpoint edges use separate generalized owner/link pools while public edge views
share a node-or-scope endpoint union. The prefix before promotion remains in its
original node-only link range. Indexed links tolerate nested owners without
copying, recursion or eager expansion. Endpoint scopes have no standalone order
entry; global statement traversal remains owner-first. A subtree scope boundary
supports direct-child traversal independently of statement kinds.

See `examples/subgraph_endpoints.zig` for the public endpoint switch and
`tests/subgraph_endpoints.zig` for nested ordering, storage failures, work
partitioning and cancellation coverage.

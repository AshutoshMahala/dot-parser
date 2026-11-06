# Architecture

A map of the source code for contributors. For the reasons behind the design,
see [Why it works this way](DESIGN.md). For the rules a processor must follow,
see [Bringing your own processor](CUSTOM_PROCESSORS.md).

## Modules

The package exposes three independent modules and one shared internal module:

| Module | Root file | Who uses it |
| --- | --- | --- |
| `dot_parser` | `src/root.zig` | Users who parse DOT. It also contains the optional graph layer, `dot.ir` (unreleased), in `src/ir.zig` and `src/ir/`. |
| `markup_parser` | `src/markup.zig` | Users who parse HTML-like labels, with or without DOT |
| `string_processor` | `src/string.zig` | Users who check string values, on their own or in DOT and markup attributes (unreleased) |
| `parser_support` | `src/support.zig` | All three modules internally. Not imported by users directly. |

The three modules never import each other. Anything they share lives in
`src/common/` and reaches them through `parser_support`. When DOT checks labels
or strings, the user passes the markup or string processor in as a
compile-time parameter.

## How a DOT parse flows

```text
source bytes
  → lexer (src/dot/lexer/)       turns bytes into tokens
  → parser (src/dot/parser.zig)  checks the grammar, emits events (src/dot/events.zig)
  → builder (src/dot/syntax.zig) stores events in the document's arrays
  → Document                     what users read
  → validate (src/dot/validate.zig)  optional checks over the finished document
  → graph layer (src/ir/)        optional: builds a graph from an accepted Document
```

`src/dot/parse_engine.zig` connects the one grammar to three kinds of storage:
allocator-backed, fixed buffers, and counting only (for `measure`).
`src/dot/profile.zig` applies the chosen settings and exposes the public
functions.

`Profile.Events(Sink)` (unreleased) sends the same events to a consumer type
of your own instead of a builder. `events.zig` defines the one event contract
used by user consumers, the document builders and the sizing sink;
`event_profile.zig` has the event-only drivers. There is no translation layer
between them. Builder-only scope state is kept in the nesting scratch, not in
the events. Which consumer is used is decided at compile time.

The markup parser follows the same shape under `src/markup/`.

## How the graph layer is built

> **Unreleased.** Not in 0.5.0.

The optional `IR.FromEvents(Dot).parse` route uses the same event contract to
build a complete graph without retaining a Document. It stages the active
statement, validates committed groups and replays them through shared IR
semantics. The ordinary Document route remains the default.
`Observe(Consumer)` forwards selected events before their IR work, using the
same event interface and caller-owned observer. Coverage stays in `checking`
for both bindings; typed observer failures are captured at the callback.

Building the graph from a `Document` is called *lowering* in the code and the
API (`lowerComplete`, `loweringSession`). `src/ir.zig` defines
`dot.ir.Lowering(config)`, which fixes the representation at compile time:
whether attributes are kept, which query indexes exist, and which source
encodings are read.

- **Direct lowering** (`lower.zig`) builds the whole graph in one call.
  **Lowering sessions** (`lowering_session.zig`) do the same work in small,
  charged steps. **Fixed lowering** (`fixed_lowering.zig`, `fixed_storage.zig`)
  writes into caller-owned buffers. All three share the same rules and
  helpers.
- The graph (`topology.zig`, or `partial.zig` for unfinished files) keeps edge
  sets as compact connections. Queries such as `hasEdge` read them without
  expanding anything.
- Edges are expanded only on request: streamed (`edges.zig`, `edge_session.zig`)
  or built into an edge list (`materialized_attributes.zig`,
  `materialization_session.zig`, `fixed_materialization.zig`), optionally with
  adjacency (`adjacency*.zig`).
- Building the graph, expanding edges and the `With` forms of queries count
  their work and memory against the limits in `resources.zig`. Plain accessors
  are unmetered.

## Source map

### Root files

| File | Purpose |
| --- | --- |
| `src/root.zig` | The `dot_parser` module: everything users import from it |
| `src/ir.zig` | The `dot.ir` graph layer: `Lowering(config)`, `parse`, `parsePartial` and the public graph types (unreleased) |
| `src/markup.zig` | The `markup_parser` module |
| `src/string.zig` | The `string_processor` module (unreleased) |
| `src/support.zig` | The internal `parser_support` module: re-exports `src/common/` |

### `src/common/`: shared by the processors

| File | Purpose |
| --- | --- |
| `location.zig` | Byte spans and lazily computed line and column locations |
| `text_position.zig` | Optional conversion to editor lines and columns (unreleased) |
| `reporting.zig` | Diagnostic sinks, fixed and growable bags, fixes, stop reasons |
| `wdp.zig` | Builds diagnostic codes and their short ids at compile time |
| `execution.zig` | The cancel-check hook and the cancellation-interval countdown |
| `processor.zig` | Prepares settings for processors combined at compile time |
| `string_routing.zig` | Compile-time choice of which attributes go to a string processor (unreleased) |
| `logical.zig` | Reads a value's decoded text one character at a time, keeping positions in the original bytes (unreleased) |
| `stack.zig` | Storage for the nesting stack |
| `utf8.zig` | Decoding one UTF-8 character |
| `completeness.zig` | Whether a document or node is complete or partial |
| `encoding.zig` | Encoding choices, byte order marks, reading UTF-16 and UTF-32 without converting, and the encoding check both parsers use |
| `source_dispatch.zig` | Picks the reader once per file, before the parse loop starts |
| `console.zig`, `console_text.zig` | The optional console renderer, source excerpts and `printDiagnostics` |
| `console_widths.zig` | Unicode character width tables, generated by `tools/generate_console_widths.zig` |

### `src/dot/`: the DOT parser

| File | Purpose |
| --- | --- |
| `lexer/lexer.zig` | Picks a scanner; the interface the parser sees |
| `lexer/token.zig` | Token types shared by both scanners |
| `lexer/scalar.zig` | The default scanner, one byte at a time |
| `lexer/block.zig` | The opt-in scanner, 64 bytes at a time with vector instructions |
| `lexer/preview.zig` | Describes an unfinished token at a pause or end of input, for previews (unreleased) |
| `parser.zig` | The grammar, as a resumable state machine |
| `events.zig` | The event contract every DOT output uses: the document builders, the sizing sink and your own consumers (public, unreleased) |
| `event_profile.zig` | Event-only drivers over the same grammar (unreleased) |
| `event_test.zig` | Test-only recording consumer for the same contract |
| `syntax.zig` | The `Document`, its views and iterators, and its builder |
| `parse_engine.zig` | Connects the grammar to each kind of storage |
| `execution_variant.zig` | Picks the run-time execution variant (metering, cancellation interval) once, before the grammar loop |
| `scratch.zig` | Temporary nesting frames |
| `partial.zig` | Tracks the finished parts of a file and its gaps, for partial results |
| `validate.zig`, `validation_checks.zig` | Validation and its individual checks |
| `attribute_catalog.zig` | Graphviz's documented attribute names, for the optional unknown-attribute check (unreleased) |
| `policy.zig` | The `Policy` type, presets and defaults |
| `profile.zig` | `Profile(...)`: settings applied to the public functions |
| `source_profile.zig` | `Profile(...)` for profiles that read other encodings |
| `string_profile.zig` | `Profile(...)` when string checks are routed to attributes (unreleased) |
| `diagnostic.zig` | DOT's diagnostic codes and detail types |
| `console.zig` | DOT wording for the console renderer |
| `identifier.zig` | Public helpers to decode, hash and compare names |
| `identifier_cursor.zig` | Walks a name one character at a time, in any supported encoding |
| `identifier_parts.zig` | Splits a joined name such as `"a" + "b"` into its parts |
| `identifier_value.zig` | Decodes a name's value, and hashes and compares it |
| `name.zig` | The `Name` type for complete names the parser recognized (unreleased) |
| `parsed_name.zig` | Internal reader for names the parser already checked |
| `logical.zig` | Logical reader for a DOT name's decoded value, for string checks (unreleased) |
| `composition.zig` | Checking HTML-like values with a markup processor during parsing |
| `comment.zig` | Kept comments: their kind and position |

### `src/markup/`: the markup parser

| File | Purpose |
| --- | --- |
| `lexer.zig`, `lexer_runs.zig` | Scanner, with optional vector scanning of long runs |
| `parser.zig` | The grammar |
| `engine.zig` | Connects the grammar to each kind of storage |
| `syntax.zig`, `kind.zig` | The markup `Document` and its node types |
| `scratch.zig` | Temporary nesting frames |
| `validate.zig`, `validation_rules.zig` | Validation and the XML name and reference rules |
| `validate_source.zig`, `scope.zig` | Validation of parts of a document that failed to parse |
| `validation_poller.zig` | Shared cancel-check countdown for validation |
| `policy.zig`, `profile.zig` | Settings and the public functions |
| `source_profile.zig` | `Profile(...)` for profiles that read other encodings |
| `string_profile.zig` | `Profile(...)` when string checks are routed to attributes (unreleased) |
| `result.zig`, `fragment_result.zig` | Result types |
| `diagnostic.zig`, `console.zig` | Codes, details and console wording |
| `graphviz.zig` | Graphviz's tag and attribute names, for Graphviz mode |
| `graphviz_content.zig` | Graphviz's label content rules: which elements may contain which (unreleased) |
| `graphviz_value.zig` | Graphviz attribute value and required-attribute checks (unreleased) |
| `graphviz_entities.zig` | HTML 4 named references, for Graphviz mode (unreleased) |
| `logical.zig` | Logical reader for markup text and attribute values, for string checks (unreleased) |
| `typo.zig` | Compares closing-tag names for typo recovery |

### `src/string/`: string checks

> **Unreleased.** Not in 0.5.0.

| File | Purpose |
| --- | --- |
| `profile.zig`, `policy.zig` | Settings, compile-time binding, one-call checks and step-by-step sessions |
| `value.zig` | Reads string contents one character at a time, in their own encoding |
| `compare.zig`, `compare_logical.zig` | Exact and case-insensitive comparison, for raw contents and for logical readers |
| `batch.zig` | Faster checking of unchanged ASCII runs, without changing work credits |
| `validators.zig` | The built-in `equals` and `one_of` checks, and an adapter for your own predicate |
| `casefold.zig` | Optional Unicode 17.0.0 case folding, generated by `tools/generate_string_casefold.zig` |
| `diagnostic.zig`, `console.zig` | Codes, details for your own validators, and console layout |
| `result.zig` | Coverage, validity, completion and session progress |
| `UNICODE_LICENSE.txt` | The Unicode License for the generated tables |

### `src/ir/`: the graph layer

> **Unreleased.** Not in 0.5.0.

**Setup and limits**

| File | Purpose |
| --- | --- |
| `representation.zig` | The compile-time choices (attributes, indexes, encodings) that decide a graph's type |
| `execution_policy.zig` | IR execution settings (metering, cancellation), using the parser's names |
| `resources.zig` | Limits, cancellation and work and memory counting for every IR operation |
| `parse.zig` | `parse` and `parsePartial`: parse, check and build, then free the temporary document |

**Building the graph**

| File | Purpose |
| --- | --- |
| `lower.zig` | Builds the graph from an accepted `Document` in one call |
| `event_lowering.zig` | Opt-in `IR.FromEvents(Dot).parse`, policy admission, diagnostics and ownership |
| `event_builder.zig` | Active-statement staging and replay through shared semantic primitives |
| `event_observer.zig` | Optional typed forwarding, subscription filtering and observer lifecycle |
| `event_storage.zig` | Private construction pages and checked copying into ordinary contiguous IR pools |
| `event_validation.zig` | Bounded committed-group and source checks without a Document |
| `lowering_session.zig` | Builds it in small steps |
| `lowering_primitives.zig` | Small bounded steps used by lowering sessions |
| `lowering_types.zig` | State records shared by the direct and step-by-step builders |
| `lowering_storage.zig` | Chooses growable or caller-owned pools at compile time |
| `session_storage.zig` | Grows session buffers by copying in small, charged chunks |
| `names.zig` | Node and subgraph identity: hashing and comparing names by value |
| `topology.zig` | The graph type: nodes, subgraphs, mentions, connections and their queries |
| `topology_storage.zig` | Keeps connections and their ports in one allocation |
| `partial.zig` | The partial graph type and its known-or-unknown queries |
| `coverage.zig` | For partial graphs, where the gaps are and which answers they affect |
| `query_indexes.zig` | Optional connection and membership indexes |
| `fixed_storage.zig` | Caller-owned pools and their sizes, for building without an allocator |
| `fixed_lowering.zig` | `lowerCompleteIn`, `lowerPartialIn` and their sessions |

**Reading attributes and values**

| File | Purpose |
| --- | --- |
| `views.zig` | Node, subgraph and edge views over the stored records |
| `attributes.zig` | Effective attribute maps, shared between snapshots |
| `attribute_primitives.zig` | Bounded steps for attribute lookups |
| `attribute_session.zig` | Attribute lookup and listing in small steps |
| `query_storage.zig` | Caller-owned scratch for edge streaming and attribute listing |
| `values.zig` | Value views: spelling, kind, parts and joined text |
| `ports.zig` | `tailport` and `headport` values from written `a:p` endpoints |
| `port_views.zig` | Views of a written port, and Graphviz's reading of it |

**Edges**

| File | Purpose |
| --- | --- |
| `edges.zig` | Expands compact connections into edges, for streaming and building |
| `edge_session.zig` | Edge streaming in small steps |
| `query_session.zig` | Edge-existence and membership queries in small steps |
| `partial_edges.zig` | Edge views for partial graphs |
| `materialized_attributes.zig` | Builds the edge list with each edge's final attributes |
| `materialization_session.zig` | Builds the edge list, or streams edges, in small steps |
| `materialization_options.zig` | Edge-list choices (attributes, adjacency) and direction filters |
| `materialization_storage.zig` | Output and scratch buffers for the edge list, growable or fixed |
| `materialization_bounds.zig` | Safe sizes for fixed edge-list buffers |
| `fixed_materialization.zig` | `materializeIn` and its session |
| `adjacency.zig` | Node views that list their edges |
| `adjacency_rows.zig` | Builds each node's edge rows in bounded steps |
| `adjacency_materialization.zig` | Adds the adjacency step to building the edge list |

### `tools/`: maintenance and consumer checks

| File | Purpose |
| --- | --- |
| `generate_console_widths.zig`, `generate_string_casefold.zig` | Unicode table generators |
| `unicode.zig` | Shared generator helpers: version and checksum pins, formatting, comparison |
| `templates/string_casefold.zig.txt` | Lookup code the case-folding generator appends |
| `check_string_sizes.mjs` | Runs the built Wasm modules and checks their exports and table sizes (Node) |
| `perf_string.zig` | `zig build perf-string`: compares string benchmarks against a Git revision |
| `fuzz_ir.zig` | `zig build fuzz-ir`: generated and mutated inputs checked across IR paths |

The generators read local, pinned Unicode files and never modify repository
files themselves. Ordinary library builds use the checked-in tables and never
import these tools or fetch Unicode data. The build passes exact artifact
paths to `check_string_sizes.mjs`, so it doesn't depend on installed or stale
`zig-out` files. See [building and testing](../README.md#building-and-testing)
for the commands.

## Dependency rules

- `src/common/` knows nothing about DOT, markup or string rules.
- The string processor imports shared support only, never DOT or markup.
- DOT and markup never import each other. During composition, DOT receives the
  markup and string processors as compile-time parameters from the user.
- The graph layer (`src/ir/`) sits above DOT: it imports DOT's `Document`,
  events, policy, validation rules and name helpers. DOT's parser, document and validation never import
  it; only `src/root.zig` exports it.
- Inside each parser, imports point one way: lexer → parser → builders and
  drivers → document → validation.
  - The lexer must not import the parser or the document.
  - The parser must not import the document builder.
  - The document must not import validation.
- No module may keep borrowed data (such as the source) longer than it was lent.
- The library depends on nothing outside the Zig standard library, and uses no
  OS, file system, threads or network.

## What is public

During 0.x everything public may still change, but some parts are meant to
stay internal:

- **Public:** everything exported from `src/root.zig` (including `dot.ir`),
  `src/markup.zig` and `src/string.zig`.
- **Internal:** the parser state machine, the document builder and its
  storage bookkeeping. The event contract they use is public (unreleased).
- No stable binary layout and no saved file format is promised.

## Tests

There are four levels of tests:

1. **Unit tests** live next to the code in `src/`.
2. **Public integration tests** in `tests/` import the modules exactly as a
   user would:
   - `tests/integration.zig` is the main DOT suite;
   - `tests/markup.zig` imports only `markup_parser`, so `zig build test-markup`
     builds no DOT;
   - `tests/parser_modules.zig` uses DOT and markup together;
   - `tests/ir.zig` covers the graph layer (`zig build test-ir`);
   - `tests/string.zig` imports only `string_processor`, and
     `tests/logical_values.zig` covers the logical readers.
3. **Corpus tests** run the `.dot` files in `tests/corpus/`, grouped into
   `valid/`, `invalid/` and `unsupported/`. Each file has an expected result
   registered in `tests/integration.zig`. See
   [tests/corpus/README.md](../tests/corpus/README.md).
4. **Fuzz tests** feed random bytes and check that parsing never crashes,
   leaks or gives different results. They run briefly in every test run.
   `zig build fuzz-ir` runs a longer, repeatable campaign for the graph layer.

Also:

- `tests/compile_fail/` holds programs that must fail to compile, such as
  invalid settings. `build.zig` checks the expected compiler error.
- The graph-layer examples are checked for their exact output in
  `zig build test` and `zig build test-ir`.
- `zig build check-freestanding` compiles both parsers, the graph layer and
  the string processor for RISC-V32 and Wasm32 with no OS.

Two habits for new code: every function that takes caller memory gets a test
with a buffer that is too small, and every parser boundary gets a test with the
input cut off at each byte.

## Commands

```sh
zig build test                 # unit and integration tests
zig build test-markup          # markup only, without building DOT
zig build test-ir              # graph layer only
zig build test-string          # string processor only
zig build examples             # build and run all examples
zig build check-freestanding   # RISC-V32 and Wasm32 compile checks
zig build check-benches        # compile benchmarks without running them
zig build check                # everything above, plus tool and Wasm checks
zig build -Doptimize=fast test --fuzz=1000   # longer fuzzing
```

Benchmarks are listed in [Performance](PERFORMANCE.md#running-the-benchmarks).

## Adding a DOT feature

1. Add a test file to `tests/corpus/valid/` (and malformed variants to
   `invalid/`), and register it in `tests/integration.zig`.
2. Update the table in [SUPPORTED_SYNTAX.md](SUPPORTED_SYNTAX.md) in the same
   change.
3. Add an entry to the [changelog](../CHANGELOG.md), marking anything that
   breaks existing code.

# String integration — logical values and source mapping

**Direction agreed 2026-10-19; explicit validator binding implemented.** Shared
bounded plain/DOT/markup readers expose scalar locations and borrowed fast paths;
`Profile.WithReader` connects them to built-in/custom validators, sessions and
mapped findings. Retained-attribute routing and one-shot/delayed host execution
are implemented, including DOT → markup → string. See
[host integration](../STRINGS.md#attribute-processing-in-dot-and-markup).
Range selection and host-aware fixes remain design. Unimplemented syntax below
is illustrative. The current
standalone API remains documented in [STRINGS.md](../STRINGS.md); host routing,
policy delegation and composition constraints remain in
[PROCESSOR_CONTRACT.md](PROCESSOR_CONTRACT.md).

## Responsibility and implementation order

DOT and markup own boundaries, quoting, escapes/references and recovery. String
validators receive logical contents without needing host AST types, attribute
names or element identity. Hosts select the child and its policy; the child owns
its checks. Compile-time binding remains mandatory, and host string handling
defaults to passthrough even when a processor is bound.

| Source | Logical input / destination |
| --- | --- |
| DOT `color=red` or `color="red"` | String contents `red` |
| DOT `label="S" + "F"` | One string value `SF`, not two independent checks |
| Markup `title="A&amp;B"` | String contents `A&B`, using the host's reference rules |
| DOT `label=<...>` | Markup branch; no implicit conversion to a string |

Reuse host decoding rules rather than inventing a second interpretation. DOT
layout escapes are not expanded by this interface. Mixed quoted/markup
concatenations leave requested string processing unavailable; pure HTML operands
stay on the markup path. No tag stripping or markup flattening is performed.
Unknown or malformed references must not be silently invented as decoded
characters. Unavailable logical input leaves child coverage unavailable without
duplicating the host's syntax/reference diagnostics.

Implement in slices:

1. Logical-value adapters and original-source diagnostic/fix mapping, with the
   same validator interface for standalone contents and host values.
   Reader adapters, validator binding and mapped primary/related findings are
   implemented. Safe edit mapping remains. Existing standalone byte-oriented
   validators still work on standalone values; portable validators use readStep.
2. Implemented string attribute routing for DOT and markup, with default
   passthrough, child-owned delegated policies and a shared diagnostic destination.
   Per-attribute markup routes remain future work.
3. Implemented single-call `parseAndValidate` and explicit `processStrings` over
   retained documents. No-tree/source/event routing remains. Shared-budget
   composed sessions remain separate work; a synchronous call must not claim
   resumable composition merely because the standalone child can be metered.

## Logical-value interface

Keep `State(Context)` / `step(state, value, settings, context)` and the optional
unmetered `check` path. Built-ins and custom validators use the same contract.
The implemented binding replaces the assumption that all logical contents are
available in `.bytes` with an optional borrowed fast path and incremental cursor:

```zig
value.contiguous(); // ?BorrowedContents: unchanged logical contents, if available
value.location();   // SourceLocation: the whole original value's location

// Context.Cursor has fixed-size, default-initialized state for the bound adapter.
context.readStep(&cursor, value);
```

`BorrowedContents` identifies its source encoding and location; it is not
implicitly UTF-8. Null means use the cursor, not allocate or decode eagerly.
The accessor must not scan to discover contiguity; it may conservatively return
null when that fact is not already available. Raw spelling, if exposed, must be
named distinctly and never masquerade as logical contents.

Illustrative read result:

```zig
union(enum) {
    pending,
    scalar: struct {
        codepoint: u21,
        location: SourceLocation,
    },
    end,
    stopped,
}
```

`pending` means bounded progress without a ready scalar. A long reference or
comment between concatenated operands may take many steps. Returning the next
character must not hide an arbitrary scan inside one credit. Budget-one progress,
cancellation boundaries and equivalent batching remain requirements. Existing
standalone credit accounting must not be weakened to accommodate host adapters;
their work must be explicitly accounted for before shared-budget execution ships.

## Locations and provenance

`SourceLocation` is an adapter-produced location, not a logical byte/character
index or a promise of an editable range. The reader foundation now represents
this with an original-byte `span`, a `segment_start` identifying the operand's
opening delimiter/content start, and `mapping = exact | enclosing`. These
contain no pointers into cursor state. Primary/related bounds, segment origins
and native alignment are checked in ReleaseFast too. These checks do not prove
fabricated locations came from a reader or grant edit permission. Range helpers
and fix materialization remain implementation design; no struct-size guarantee
is made.

| Logical item | Original source location |
| --- | --- |
| `&` decoded from `&amp;` | All five source bytes of `&amp;` in UTF-8 |
| `"` decoded from DOT `\"` | Both source characters of the escape |
| One scalar encoded as a UTF-16 surrogate pair | Both original code units |
| `SF` assembled from `"S" + "F"` | Distinct operand provenance; not an exact contiguous content range |

Validators report using these locations, not `origin + logical_offset`. Delivered
diagnostic spans stay in original physical byte coordinates, including for
UTF-16/32 and nested DOT → markup → string. Resolve provenance once; do not
rebase already-original positions at each enclosing processor.

Whole-value failures use the whole original value location. A finding spanning
operands may use primary/related locations or an enclosing highlight, but must
not turn the intervening quotes, comments and operators into editable content.
An enclosing highlight is not evidence of an exact mapping.

Check custom locations and standard primary/related/fix fields against the active
value and permitted mapping, including in ReleaseFast. Invalid locations are
validator contract failures, not silent clipping. Typed locations help prevent
coordinate mistakes; they do not sandbox trusted custom Zig code. Retained
diagnostics must not point into temporary cursor/session state. Source and any
borrowed custom detail/replacement text must outlive their retained uses.

## Custom diagnostics and fixes

Illustrative resumable validator: readStep/report locations are implemented,
but the logical replacement offer below remains future API:

```zig
const NoAmpersands = struct {
    pub const Settings = void;
    pub const defaults: Settings = {};
    pub const uses_comparison = false;
    pub const Detail = enum { ampersand };

    pub fn State(comptime Context: type) type {
        return struct { cursor: Context.Cursor = .{} };
    }

    pub fn step(state: anytype, value: anytype, _: Settings,
                context: anytype) strings.Step {
        return switch (context.readStep(&state.cursor, value)) {
            .pending => .pending,
            .stopped => .stopped,
            .end => .passed,
            .scalar => |item| blk: {
                if (item.codepoint != '&') break :blk .pending;
                if (!context.report(.{
                    .at = item.location,
                    .detail = .ampersand,
                    .fix = .{ .logical_replace = .{
                        .at = item.location,
                        .text = "and",
                        .applicability = .maybe,
                    } },
                })) break :blk .stopped;
                break :blk .pending;
            },
        };
    }

    pub fn message(_: Detail, writer: anytype) !void {
        try writer.writeAll("ampersands are not allowed");
    }
    pub fn hint(_: Detail, writer: anytype) !void {
        try writer.writeAll("consider writing “and”");
    }
};
```

Policy supplies severity. Existing typed detail/message/hint reporting remains;
there is no allocation of message strings. Reports survive a later `.passed`,
and detailed findings suppress the generic failure fallback. `report` returning
false stops the validator for sink stops, fail-fast or another terminal cause.
Fix filtering does not suppress the finding or change validity.

A logical replacement describes intent, not bytes to splice into source:

- The host adapter owns escaping/quoting and verifies whether the selection is
  safely replaceable. String validators must not need DOT or markup escaping code.
- Replacement text is borrowed UTF-8. Materializing an edit accounts for host
  spelling and the original source encoding. Unrepresentable replacements must
  be rejected explicitly, not encoded with loss.
- Logical replacements must be distinguishable from existing raw replacements.
  Consumers must not apply logical text directly to its source range.
- Unsupported mappings retain the diagnostic and expose why an applicable edit
  could not be produced. Invalid custom locations are contract failures instead.
- A fix crossing operands must not delete glue or reconstruct the expression
  implicitly. General multi-edit rewriting is outside this first slice.
- A validator's applicability claim cannot make an unsafe mapping safe. Fixes
  are never applied automatically; the example uses `.maybe` because “and” is
  only one possible repair.

Fix materialization is an explicit consumer operation using a writer or
caller-owned buffer. Keep only bounded intent/metadata and borrowed text while
reporting; do not hide arbitrary replacement validation, escaping or allocation
inside one parser credit. Materialization must validate the replacement and
mapping before presenting an applicable edit. Its output/failure contract must
be defined before exposing the API.

## Memory and performance constraints

- No decoded whole-value copy or per-character mapping array is mandatory.
  Produce locations while traversing and retain only what the validator needs.
- Cursor/adapter state is fixed-size, not proportional to the value length,
  reference spelling length or number of concatenated operands. Keep state
  movable across yields, with no pointers into the current session instance.
- Contiguous unchanged contents retain direct-comparison opportunities.
  Compile-time host adapters must not introduce a runtime discovery/dispatch
  registry or mandatory processing state into passthrough profiles.
- Repeated checks can repeat decoding. Arbitrary backward mapping queries may
  require another traversal or explicitly requested mapping storage; neither
  is free or hidden inside one bounded step.
- Diagnostic storage is still caller-selected. A growable bag can allocate;
  custom validators and explicit fix output may incur caller-controlled costs.
- Benchmark no binding, bound passthrough and active processing separately:
  short/long contents, references/escapes, concatenation and UTF-8/16/32. Measure
  throughput, budget-one behavior, cancellation, state/binary size, allocations
  and peak memory. No default-path non-regression claim without measurements.

## Remaining details and acceptance tests

Implemented prerequisites: reader binding traverses the whole logical value
before checks. A reader failure returns `input_unavailable`, its typed original
location in `input_failure`, and unavailable check coverage without duplicating
host diagnostics. Bound sessions preserve scalar-step credits across budget
partitions, cancellation intervals and movable state. Optional checked reader
ASCII runs and validator batches group equivalent pending steps without crossing
polls, budgets, host decoding boundaries or terminal transitions. Readers without
these optional methods retain scalar execution; no cursor state or heap storage
is added. Plain standalone batching/credits are unchanged. Raw fixes are rejected in bound reporting until
safe host-aware materialization exists. Automatic string routing reports
constant-size aggregate coverage without retaining per-value results.

The streaming/mapping direction is decided. Before adding logical edits, define
the range-selection representation, empty-value and insertion boundaries,
cross-operand range helpers, fix-materialization outcomes, and malformed or
unresolved input prerequisites. The implemented routing precedence is explicit
attribute string rule → host string default → passthrough. Delegated child
policies override child baselines; enabled runtime child patches override the
delegated settings. Mixed concatenations are unavailable to string processing,
never implicitly flattened. Shared-budget and no-tree execution remain open.

Test standalone/bound built-ins and custom validators through the same interface.
Include complete escape/reference highlights, native encodings, empty operands,
concatenation with comments and physical line continuations, and multi-level
origin mapping. Verify invalid custom locations fail with safety checks disabled;
unsupported cross-operand fixes preserve findings; accepted materialized edits
preserve host syntax and express the requested logical replacement. Test borrowed
lifetimes, moved sessions, fixed storage and no hidden allocation.

Exercise tiny budgets and cancellation while inside long references and skipped
glue, not just at ready characters. Resumption must not duplicate reads, reports,
fix offers or credits. Built-in/custom comparison parity, Unicode folding,
fail-fast/collect and sink-stop behavior must remain intact.

# Roadmap

Remaining work after 0.5.0. Items described as implemented are available in
0.5.0 unless marked Unreleased; the other items are plans and can change. The linked guides describe
the implemented contracts.

## DOT

- **Richer graph queries and bulk attribute folding.** The unreleased
  [semantic IR](IR.md) resolves unique nodes, shared scope membership, symbolic
  connections, effective attributes/defaults and their origins from complete
  Documents. Borrowed component views expose individual/all effective attributes.
  Edge iteration/materialization is explicit and bounded. Materialization resolves
  bulk edge updates and endpoint-port values once by default, with a topology-only
  option. Opt-in partial IR retains qualified queries, iteration and materialized
  output; Document lowering and materialization have resumable sessions.
  Label-port existence/binding, event lowering, fixed storage and resumable
  query/edge-streaming operations remain.
- **Feeding input in pieces.** Today the whole input must be in memory before
  parsing starts.
- **Validation in small steps**, and validation that can be cancelled.
- **A ready-made "untrusted input" preset** for DOT, like the one markup has.
- **Step-by-step parsing of UTF-16 and UTF-32**, and source excerpts for them
  in boxed output. One-call parsing is available in 0.5.0; see
  [encodings](#encodings).
- **Broader event output.** The unreleased [public DOT events](EVENTS.md) support
  event-only one-shot parsing and UTF-8 sessions. Combined tree/event output,
  event-driven validation, public pull events and composed execution remain.

## Markup

The markup parser is a general, extensible base for HTML-like markup. Graphviz
labels are its first and most important use. HTML subsets, SVG, and custom
dialects such as XAML should be able to build on it without inheriting each
other's rules.

- **More ways to check.** DOT's `markup` setting already chooses whether labels
  are checked: `none` (report `<...>` as unsupported), `passthrough` (keep it
  unchecked) or `process` (check it with the bound label checker). How they are
  checked is the checker's `mode`: `.graphviz` is now the default,
  supplying tag and per-element attribute vocabulary checks. `.structural`
  remains available explicitly for custom vocabulary and byte-exact tag matching.
  `extended` remains planned. Graphviz child/content rules, attribute values and
  references remain unfinished, as does automatic selection of Graphviz label
  contexts. For example, an HTML-like port `n:<p>` has the value
  `p`, not an opening tag.
- **More optional rules.** Name rules and reference lists stay separate,
  independent choices. More lists, and a way to supply your own, are planned.
- **Dialects that parse differently.** Some dialects need different parsing,
  not just different checks. HTML's `<br>` with no closing tag is the usual
  example. The plan is an explicit, compile-time dialect rule on the same
  engine, described as a defined subset, never as full browser HTML. This still
  needs its own design.
- **String integration** for checking values inside markup. The unreleased
  [standalone string processor](STRINGS.md) supplies equality, membership and
  custom checks, with resumable metering and cancellation. Host adapters, source maps and attribute-specific selection
  are still needed; callers currently select contents and invoke it explicitly.
- **More of a partial markup document.** Unreleased DOT retention keeps later
  recovered statements with gaps; markup still retains its prefix. Gap-aware
  markup trees and pausing/resuming label checks remain unfinished.

## Checking labels inside DOT

- **Small steps and shared budgets.** Checking labels in small steps, with one
  budget for DOT and its labels. Label work would count against DOT's budget.
- **Fixed buffers** for checking every label during the DOT parse. Today that
  mode uses an allocator. Checking selected labels afterwards already supports
  fixed buffers.

## Encodings

One-call parsing of UTF-16 and UTF-32 is available in 0.5.0; see
[source encodings](ENCODINGS.md). It reads the original bytes without
converting them. Still to do:

- step-by-step sessions for these encodings
- splitting the encoding check into small steps, so it can share a budget
- source excerpts for them in boxed output

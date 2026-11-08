# Roadmap

What is planned but not built yet. Plans can change. Features that already
exist are described in their guides; the ones that are not in 0.5.0 are marked
"unreleased" there.

## DOT

- **Feeding input in pieces.** Today the whole input must be in memory before
  parsing starts.
- **Validation in small steps**, and validation that can be cancelled.
- **A ready-made "untrusted input" preset** for DOT, like the one markup has.
- **Step-by-step parsing of UTF-16 and UTF-32**, and source excerpts for them
  in boxed output. One-call parsing is available; see [encodings](#encodings).
- **More event output.** [DOT events](EVENTS.md) (unreleased) work in one call
  for every encoding, and in sessions for UTF-8. Still to do: sessions for
  UTF-16 and UTF-32, validation driven by events, a document and events from
  the same parse, label and string checks through events, and a pull-style API
  where you ask for the next event.

## Graph layer

The [semantic graph](IR.md) (unreleased) already finds unique nodes and
subgraph membership, resolves effective attributes, streams or builds edges,
works on unfinished files, runs in small steps or in fixed memory, and has
optional indexes and adjacency. Still to do:

- **Label ports.** Checking that a port such as `a:p` exists in the node's
  label, and linking the port to that part of the label. Today a port is only
  a value (`tailport`, `headport`).
- **More event-based graph construction.** `IR.FromEvents(Dot).parse` and
  `parsePartial` are available without a retained Document, with optional
  observer forwarding, fixed storage and UTF-8/ASCII shared-budget sessions.
  Native sessions remain.
- **One budget for Document construction followed by lowering.** Those two
  operations still have separate steps; event-based sessions already share a
  grant across parsing, checking and graph construction.
- **More in small steps:** finding a node by name (`findNode`), structured
  `tailPort()` / `headPort()` views, and formatting values.
- **Walking the edges at a node without building the edge list first**, and
  filtering those edges by attribute.
- **Closer Graphviz compatibility.** A few cases still differ from Graphviz on
  purpose, such as the edge `key` attribute. They are listed in
  [default and update rules](IR.md#default-and-update-rules), and each needs its
  own decision.

## Markup

The markup parser is a general, extensible base for HTML-like markup. Graphviz
labels are its first and most important use. HTML subsets, SVG, and custom
dialects such as XAML should be able to build on it without inheriting each
other's rules.

- **Checking only the values Graphviz reads as labels.** Today DOT checks every
  `<...>` value as a label. For example, an HTML-like port `n:<p>` has the
  value `p`, not an opening tag.
- **A third mode, `extended`**, next to `.graphviz` (the default) and
  `.structural`.
- **More optional rules.** Name rules and reference lists stay separate,
  independent choices. More lists, and a way to supply your own, are planned.
- **Dialects that parse differently.** Some dialects need different parsing,
  not just different checks. HTML's `<br>` with no closing tag is the usual
  example. The plan is an explicit, compile-time dialect rule on the same
  engine, described as a defined subset, never as full browser HTML. This still
  needs its own design.
- **More string integration.** [String checks](STRINGS.md) (unreleased) already
  run on chosen DOT and markup attributes. Still to do: one shared budget for
  DOT, its labels and its strings; string checks without a kept document, for
  example from events; string checks in DOT sessions and with fixed storage;
  choosing per markup attribute; and suggested fixes that edit the original
  DOT or markup text.
- **More of a partial markup document.** Partial DOT results (unreleased) keep
  the statements after an error; partial markup still keeps only the part
  before the first error. Keeping later markup with its gaps marked, and
  pausing and resuming label checks, are still to do.

## Checking labels inside DOT

- **Small steps and shared budgets.** Checking labels in small steps, with one
  budget for DOT and its labels. Label work would count against DOT's budget.
- **Fixed buffers** for checking every label during the DOT parse. Today that
  mode uses an allocator. Checking selected labels afterwards already supports
  fixed buffers.

## Encodings

One-call parsing of UTF-16 and UTF-32 is available since 0.5.0; see
[source encodings](ENCODINGS.md). It reads the original bytes without
converting them. Still to do:

- step-by-step sessions for these encodings
- splitting the encoding check into small steps, so it can share a budget
- source excerpts for them in boxed output

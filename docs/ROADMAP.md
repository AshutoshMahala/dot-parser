# Roadmap

What is planned but not built yet. Nothing on this page is available today, and
plans can change. The other guides describe only what works now.

## DOT

- **A graph layer** on top of the document that applies defaults, expands
  edges like `a -> { b c }`, and works out the list of unique nodes. Graph
  engines could then use this layer instead of raw syntax.
- **Feeding input in pieces.** Today the whole input must be in memory before
  parsing starts.
- **Validation in small steps**, and validation that can be cancelled.
- **A ready-made "untrusted input" preset** for DOT, like the one markup has.
- **UTF-16 and UTF-32 input.** See [encodings](#encodings).
- **A public event or logging interface.** The events the parser produces are
  internal for now.

## Markup

The markup parser is a general, extensible base for HTML-like markup. Graphviz
labels are its first and most important use. HTML subsets, SVG, and custom
dialects such as XAML should be able to build on it without inheriting each
other's rules.

- **More ways to check.** DOT's `markup` setting already chooses whether labels
  are checked: `none` (report `<...>` as unsupported), `passthrough` (keep it
  unchecked) or `process` (check it with the bound label checker). How they are
  checked is the checker's `mode`: `.structural` remains the default;
  unreleased `.graphviz` supplies tag and per-element attribute vocabulary checks.
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
- **A built-in string processor** for checking quoted values inside markup.
  Today you can prepare its settings with `PolicySet` and keep positions with
  `fragment.child`, but your code must run it.

## Checking labels inside DOT

- **Small steps and shared budgets.** Checking labels in small steps, with one
  budget for DOT and its labels. Label work would count against DOT's budget.
- **Fixed buffers** for checking every label during the DOT parse. Today that
  mode uses an allocator. Checking selected labels afterwards already supports
  fixed buffers.

## Encodings

UTF-16 and UTF-32 input may later be converted to UTF-8 before parsing. When
that happens:

- the original encoding, byte order and byte order mark must be recorded
- a lossy conversion must be reported, never silent
- positions must say whether they refer to the original file or the converted
  bytes

Today, convert the input to UTF-8 yourself first. Positions then refer to the
converted bytes.

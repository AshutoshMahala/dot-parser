# Source encodings

> **Unreleased.** Not in 0.4.0.

Encoding applies to the **whole input buffer**, not just strings or non-ASCII
characters. Both parsers keep the original bytes; spans, limits and byte columns
refer to those bytes. Parsing does not transcode the source or allocate a map.

## Compile the readers you need

```zig
const Parser = dot.Profile(.{
    .source_encodings = &.{ .utf8, .utf16, .utf32 },
});

var result = try Parser.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
```

The same option is available on `markup.Profile`.

| Selection | Meaning |
| --- | --- |
| Omitted | Existing UTF-8/raw-byte path |
| `&.{}` or `&.{.ascii}` | ASCII-only, including strings, comments and markup bodies |
| `&.{.utf8}` | Existing UTF-8/raw-byte path |
| `&.{ .utf8, .utf16, .utf32 }` | All three families, both byte orders for UTF-16/32 |
| `&.{.utf32}` | UTF-32 only; no implicit UTF-8 fallback |

Duplicate selections are harmless. This is a compile-time capability, **not** a
runtime policy leaf. Runtime calls can choose an enabled reader, not add one.
The UTF-8-only profile retains its existing function signatures and execution
path. Other selections add an input-error union and `.encoding` call option.

## BOM or explicit byte order

An explicit `.encoding` is authoritative. Only a BOM matching that reader is
skipped as framing; bytes resembling another encoding's BOM remain content in
the selected reader. The bytes remain in the borrowed source and occupy their
original offsets. For example, explicit UTF-16LE treats `ff fe 00 00` as its
two-byte BOM followed by NUL, not a UTF-32LE BOM. Grammar NUL rules still apply.

Without explicit selection, a leading BOM selects UTF-8, UTF-16LE/BE or
UTF-32LE/BE. UTF-32 signatures are tested before UTF-16 signatures. A BOM for a
compiled-out reader returns `UnsupportedEncoding`, without trying a shorter BOM.

Without a BOM, use an explicit encoding for native input:

```zig
var parsed = try Parser.parseBorrowed(allocator, source, bag.sink(), .{
    .encoding = .utf16be,
});
defer parsed.deinit(allocator);
```

Other choices are `.ascii`, `.utf8`, `.utf16le`, `.utf32le` and `.utf32be`.
There is no host-endian guess. Without either selection, UTF-8 is preferred if
enabled, otherwise ASCII if enabled; a native-only profile returns
`error.EncodingRequired`. No NUL-pattern heuristic or retry with another reader
is performed. Explicit selection cannot enable a compiled-out reader.

| Selection order | Result |
| --- | --- |
| Explicit `.encoding` | Use that reader; recognize only its matching BOM |
| Otherwise, leading BOM | Use the longest matching signature |
| Otherwise, UTF-8 compiled | Use the existing UTF-8/raw-byte reader |
| Otherwise, ASCII compiled | Use the ASCII reader |
| Otherwise | `EncodingRequired`; provide native encoding and byte order |

Native input must contain complete, valid code units: no unpaired UTF-16
surrogates or invalid UTF-32 scalars. The initial one-shot API checks this in an
allocation-free pass before grammar processing. Bad framing/content returns
`error.TruncatedCodeUnit` or `error.InvalidEncoding`; a compiled-out reader
returns `error.UnsupportedEncoding`. These admission errors precede tree
creation and diagnostic emission, so they do not publish a partial tree.
If cancellation is enabled, admission polls between bounded byte runs and returns
`error.Cancelled` when stopped before grammar processing begins.

UTF-8 keeps the existing raw-byte contract. `validation.invalid_utf8` remains
optional and defaults to off; enabling native readers does not make UTF-8
validation mandatory. That check is `.not_run` for native markup input rather
than pretending native bytes were checked as UTF-8.

Markup's recovery-search allowance counts source code units, not physical
bytes: one credit per UTF-8/ASCII byte, UTF-16 unit or UTF-32 unit. Ancestor
probes and name code-unit comparisons each spend one credit. This preserves
UTF-8 behavior without giving wider encodings extra search work for equivalent
ASCII markup. It does not change physical-byte spans/limits, session stepping
or cancellation polling; see [parse failures](MARKUP.md#when-parsing-fails).

## DOT and markup together

```zig
const Parser = dot.Profile(.{
    .source_encodings = &.{.utf16},
    .processors = .{ .markup = markup.Profile(.{
        .source_encodings = &.{.utf32},
    }) },
});
```

Explicit outer/inner selections form a union: this composition accepts UTF-16
and UTF-32. An omitted inner setting inherits the outer selection when bound;
the same inner profile defaults to UTF-8 when used standalone. The actual reader
is selected once for DOT and inherited by its markup operands, in proactive and
delayed processing. A single buffer cannot mix encodings merely because several
readers were compiled.
Only the outer buffer's BOM is framing: a leading U+FEFF inside a bound label is
content, not a second BOM to discard.

Custom processors participating in native composition must provide
`withSourceEncodings(capabilities)` and `forSourceEncoding(actual)` and honor
that binding. The returned worker can be a leaf: it need not expose these factory
hooks itself. Workers must share their diagnostic, diagnostic-sink and owning
result types across encodings so a composed result has one statically known type.
No runtime processor replacement is introduced.

`forSourceEncoding` is a binding-only hook, not a standalone parser factory.
Its prepared/workspace contract consumes fragments of an already admitted outer
buffer and does not repeat admission or reinterpret inner BOM-like bytes. Use
`markup.Profile(.{ .source_encodings = ... })` for independent parsing, bounds
checks and encoding admission. The binding hook does not expose standalone parse
entry points or sessions.

## Reading and showing results

`document.source_info` records the actual reader, BOM presence and selection
provenance (`.default`, `.explicit`, `.bom`, or `.inherited`). Raw names, values,
comments and markup `content()` still return original encoded bytes.
Use `document.commentBody(comment)` to remove DOT comment delimiters correctly
for any source encoding (`comment.body(source)` remains the UTF-8/raw-byte helper).
`Document.decodeIdentifier` / `writeIdentifier` explicitly produce UTF-8 for
native DOT spellings, using caller storage or a writer; UTF-8/raw-byte decoding
retains its previous behavior.

Use the encoding when resolving or rendering a diagnostic:

```zig
const at = dot.location.locateEncoded(source, finding.span.start,
    document.source_info.encoding);
try dot.console.render(finding, .{
    .source = source,
    .source_encoding = document.source_info.encoding,
}, writer);
```

Lines recognize encoded LF/CRLF/CR; columns count **physical bytes**, not UTF-16
units or editor character positions. Renderer output is UTF-8. Native inline tag
names are decoded in bounded stack storage; boxed native diagnostics currently
use compact location lines instead of source excerpt windows. Suggested edit
spellings must be encoded in the source encoding before applying them.

## Costs and current boundary

Enabled native grammars add binary code; disabled grammars are not instantiated
by dispatch. The source buffer itself usually grows compared with UTF-8. Output
pools, indices and scratch record layouts do not change. One encoding record is
stored per document, not per token/node/attribute; on the current aarch64 build
it fits existing Document padding (DOT 256 B, markup 56 B).

The initial native facade supports one-shot borrowed/fixed parsing, measurement,
validation, markup workspaces and proactive/delayed composition. Native admission
is a full unmetered pass. Resumable `Session` dispatch and native excerpt windows
are not yet exposed by these opt-in profiles; UTF-8-only sessions are unchanged.
The work is not a string processor, normalization facility, encoding detector
without a BOM, or browser/XML transcoder.

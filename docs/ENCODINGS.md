# Source encodings

> **Available since 0.5.0.**

By default both parsers read UTF-8, or plain bytes. Some tools, especially on
Windows, save files as UTF-16 or UTF-32. These settings let the parsers read
such files directly, without converting them first.

Nothing is converted. The parsers read your original bytes, and every position,
length, limit and column refers to those bytes. No copy of the source and no
position map is made.

## Choose the readers you need

Readers are chosen at compile time with `source_encodings`, so readers you
don't list are left out of the program:

```zig
const Parser = dot.Profile(.{
    .source_encodings = &.{ .utf8, .utf16, .utf32 },
});

var result = try Parser.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
```

`markup.Profile` takes the same option.

| `source_encodings` | Reads |
| --- | --- |
| Left out | UTF-8 or plain bytes, as before |
| `&.{}` or `&.{.ascii}` | ASCII. Other bytes are still read; [the encoding check](#checking-that-the-text-is-valid) reports them. |
| `&.{.utf8}` | UTF-8 or plain bytes, as before |
| `&.{ .utf8, .utf16, .utf32 }` | All three; UTF-16 and UTF-32 in either byte order |
| `&.{.utf32}` | UTF-32 only; UTF-8 isn't tried |

- Listing a reader twice is harmless.
- This is a compile-time choice, not a run-time setting. A call can pick among
  the compiled readers, but can't add one.
- A UTF-8-only profile (the option left out, or `&.{.utf8}`) keeps its usual
  functions and behaviour. With any other choice, including ASCII, functions
  can also return encoding errors, calls accept an `.encoding` option, and
  there is no step-by-step `Session`.

## How the reader is chosen for a file

| Checked in this order | Reader used |
| --- | --- |
| You pass `.encoding` | That one. Only its own byte order mark is skipped. |
| The file starts with a byte order mark | The encoding the mark names. Longer marks are checked first, so a UTF-32 mark beats UTF-16. |
| UTF-8 is compiled in | UTF-8 |
| ASCII is compiled in | ASCII |
| Otherwise | `error.EncodingRequired`: pass `.encoding` with the encoding and byte order |

```zig
var parsed = try Parser.parseBorrowed(allocator, source, bag.sink(), .{
    .encoding = .utf16be,
});
defer parsed.deinit(allocator);
```

The choices are `.ascii`, `.utf8`, `.utf16le`, `.utf16be`, `.utf32le` and
`.utf32be`.

- **A passed `.encoding` always wins.** A byte order mark for a different
  encoding is then just content. With `.utf16le`, for example, the bytes
  `ff fe 00 00` are a UTF-16 byte order mark followed by a NUL character, not a
  UTF-32 mark. The usual rules about NUL still apply.
- A skipped byte order mark stays in your source buffer, at its position.
- **No guessing.** Without a mark or `.encoding`, the library doesn't assume
  your machine's byte order, doesn't look for patterns of zero bytes, and never
  retries with another reader. `.encoding` can't turn on a reader that wasn't
  compiled in.
- A byte order mark for a reader that isn't compiled in returns
  `error.UnsupportedEncoding`; a shorter matching mark isn't tried instead.
- **A UTF-8-only profile has no encoding errors.** It reads every file as
  UTF-8, so a UTF-16 file gives syntax errors in DOT. Markup reports a UTF-16
  or UTF-32 byte order mark as `unsupported_feature`. To explain the real
  problem instead, [check the encoding first](#check-the-encoding-yourself).

## Checks before parsing

A profile with any readers other than UTF-8 alone first checks that it can read
the file. This looks only at the first few bytes and the length, and allocates
nothing:

| Error | Meaning |
| --- | --- |
| `error.EncodingRequired` | The file has no byte order mark, and no reader can be picked without one. Pass `.encoding`. |
| `error.TruncatedCodeUnit` | A UTF-16 or UTF-32 file ends partway through a code unit: its length isn't a whole number of 2- or 4-byte units |
| `error.UnsupportedEncoding` | The file needs a reader that isn't compiled in |
| `error.SourceTooLarge` | The file is 4 GiB or larger |

These come before any diagnostic or document, so they never leave a partial
document. If cancellation is on and already requested, nothing is read and you
get the ordinary cancelled result (`outcome == .cancelled`, or
`completion == .cancelled` from markup validation), the same for every
encoding. `encoding.InputError` contains only the four admission errors above;
it no longer includes `Cancelled` (unreleased). In 0.5.0, UTF-16, UTF-32 and
ASCII input returned `error.Cancelled` instead. Whether the text itself is
valid is a separate check, described
[below](#checking-that-the-text-is-valid). No setting turns these checks off.

### Check the encoding yourself

> **Unreleased.** Not in 0.5.0.

`Parser.inspectSource(source, encoding)` runs the same checks without parsing.
It works on every profile, including UTF-8-only ones, which is where it helps
most. `dot.inspectSource` and `markup.inspectSource` use the default UTF-8
reader. Pass `null` to let it pick the reader as parsing would, or the same
`.encoding` you will pass to parsing:

```zig
switch (Parser.inspectSource(source, null)) {
    .selected => |info| {
        _ = info; // the encoding, whether there is a byte order mark, and how it was chosen
    },
    .failure => |failure| {
        try writer.print("{s}\n", .{failure.message()});
        if (failure.span) |span|
            try writer.print("byte offset {d}, length {d}\n", .{ span.start, span.len });
    },
}
```

A failure has:

| Field | Meaning |
| --- | --- |
| `reason` | The error parsing would return, such as `error.UnsupportedEncoding` |
| `span` | The bytes at fault, if any: the whole unsupported byte order mark, or the incomplete last code unit. `null` for a missing or unsupported `.encoding`, and for a file that is too large. |
| `encoding` | The reader that was picked or found, if any |
| `message()` | A short explanation. For an unsupported encoding, it suggests saving as UTF-8 or adding the reader to `.source_encodings`. |

`.require()` on the result gives you the encoding info, or the error parsing
would return.

It reads at most the first four bytes and allocates nothing. It doesn't check
the text, and it doesn't add readers to a UTF-8-only program. A UTF-8-only
profile never runs these checks while parsing; profiles with other readers run
them and report problems as Zig errors, not diagnostics. [check_file.zig](../examples/check_file.zig) uses it, so a file
with an unsupported byte order mark gets an encoding message instead of syntax
errors.

## Checking that the text is valid

`validation.invalid_encoding` checks that the text is valid in the file's
encoding. It is `.err`, `.warning` or `.off` (the default), and replaces
`invalid_utf8` from 0.4.0. It uses the reader chosen for the file, not every
compiled-in reader:

| Reader | Reports |
| --- | --- |
| ASCII | Any byte above `0x7F` |
| UTF-8 | Broken or cut-off sequences, overlong forms, surrogates, and values above `U+10FFFF` |
| UTF-16 | A high or low surrogate without its partner |
| UTF-32 | Surrogates, and values above `U+10FFFF` |

- **It's part of validation, not parsing.** Parsing reads invalid text as it
  is, and keeps it wherever the grammar allows. `parseBorrowed` never runs this
  check, even when it is turned on. So a document is built before the check
  runs; for untrusted input, also set [limits](POLICIES.md#untrusted-input).
- When it is off, it doesn't run at all.
- Each bad code unit is one finding: one byte in ASCII or UTF-8, 2 bytes in
  UTF-16, 4 bytes in UTF-32. The check then carries on from the next code unit,
  so a valid character right after it isn't reported too.
- A finding names the encoding and the bad code unit. Its position counts bytes
  in the original file. As an error it makes the result invalid; as a warning
  it doesn't.
- It only checks the encoding. Whether a name uses allowed characters is a
  separate check.

**Which parser checks what.** DOT checks the whole DOT file, including strings,
comments and the space between, except the inside of HTML-like `<...>`
labels. That part belongs to the label checker and its own
`invalid_encoding` setting:

- When labels are [checked](LABELS.md), the label checker's setting decides. A
  bad label can make the combined result invalid while `result.dot` stays
  valid. Labels [checked later](EDITORS.md#check-chosen-labels-later-in-the-same-result)
  use the label checker's setting at that time.
- **When labels aren't checked** (`.passthrough`), nothing checks the inside of
  labels, and nothing reports that. In 0.4.0, `invalid_utf8` covered them.
- Markup on its own checks its whole input: names, values, text, comments and
  CDATA. `validateScope` and `validateScopeIn` check only the range you give
  them. A UTF-16 surrogate pair split by the edge of that range counts as
  invalid.
- [String checks](STRINGS.md) (unreleased) don't depend on these settings: a
  value whose text isn't valid in its encoding never passes a string check.

Markup's [closing-tag search allowance](MARKUP.md#closing-tag-typo-recovery)
counts code units, not bytes, so a UTF-16 or UTF-32 file gets the same search
work as the same markup in UTF-8. Positions, limits and cancel checks still use
bytes.

## DOT and markup together

```zig
const Parser = dot.Profile(.{
    .source_encodings = &.{.utf16},
    .processors = .{ .markup = markup.Profile(.{
        .source_encodings = &.{.utf32},
    }) },
});
```

- Readers listed on DOT and on its label checker are combined, so this profile
  reads UTF-16 and UTF-32.
- A label checker without its own list uses DOT's when bound. Used on its own,
  the same markup profile reads UTF-8.
- The reader is chosen once, for the DOT file, and the labels use the same one,
  both when every label is checked while parsing and when chosen labels are
  checked later. One file can't mix encodings.
- Only the file's own byte order mark is skipped. A U+FEFF at the start of a
  label is content.

[Your own label checker](CUSTOM_PROCESSORS.md#supporting-other-source-encodings)
needs two extra functions to take part.

## Reading results and showing errors

- `document.source_info` says which reader was used, whether there was a byte
  order mark, and how the reader was chosen: `.default`, `.explicit`, `.bom` or
  `.inherited`.
- Names, values, comments and markup `content()` still return the original
  encoded bytes.
- `document.commentBody(comment)` removes DOT comment markers correctly in any
  encoding. `comment.body(source)` is only for UTF-8 or plain bytes.
- `document.decodeIdentifier` and `writeIdentifier` turn UTF-16 and UTF-32
  names into UTF-8, in your buffer or writer. UTF-8 decoding works as before.

Pass the encoding when you look up a position or print a diagnostic:

```zig
const at = dot.location.locateEncoded(source, finding.span.start,
    document.source_info.encoding);
try dot.console.render(finding, .{
    .source = source,
    .source_encoding = document.source_info.encoding,
}, writer);
```

- Lines end at encoded LF, CRLF or CR. Columns count **bytes**, not UTF-16
  units or the characters an editor shows.
- For zero-based positions in UTF-8 bytes, UTF-16 units or code points, as
  editors use, call
  [`location.textPosition`](EDITORS.md#editor-position-conversion)
  (unreleased). Stored spans and diagnostic positions stay in original bytes.
- The console renderer writes UTF-8. Tag names quoted in a message are decoded
  in a small fixed buffer.
- For UTF-16 and UTF-32 files, boxed output currently shows compact location
  lines instead of source excerpts.
- Suggested fixes are UTF-8 text. Encode them in the file's encoding before
  applying them.

## Costs and limits

- Each extra reader adds code to the program; readers you don't list aren't
  included.
- The encoding check is one more pass over the text, only when turned on.
  DOT skips label bodies during that pass without allocating anything.
- UTF-16 and UTF-32 files are usually bigger than the same text in UTF-8.
- Document buffers, positions and scratch records don't change. The encoding is
  recorded once per document, in space that was already there: the DOT
  document stays 256 bytes and the markup document 56 bytes on aarch64.
- Supported so far: one-call parsing with an allocator or fixed buffers,
  measuring, validation, markup workspaces, and both ways of checking labels.
  Event-only parsing ([EVENTS.md](EVENTS.md)), the graph layer
  ([IR.md](IR.md)) and [string checks](STRINGS.md) also read these encodings
  (unreleased).
- Step-by-step sessions exist only on UTF-8-only profiles. A profile that lists
  any other reader, including ASCII, has no `Session`.
- This isn't a string converter, a Unicode normaliser, a way to detect the
  encoding of files without a byte order mark, or a browser or XML transcoder.

## Examples

- [check_file.zig](../examples/check_file.zig): check the encoding with
  `inspectSource` before parsing, and report a clear message for a file that
  needs another reader (unreleased)

No example program reads UTF-16 or UTF-32 yet. Run the examples with
`zig build examples`; each program is also installed in `zig-out/bin/`.

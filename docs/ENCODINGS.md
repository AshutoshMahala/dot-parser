# Source encodings

> **Unreleased.** Not in 0.4.0.

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
| `&.{}` or `&.{.ascii}` | ASCII only, everywhere, including strings, comments and markup text |
| `&.{.utf8}` | UTF-8 or plain bytes, as before |
| `&.{ .utf8, .utf16, .utf32 }` | All three; UTF-16 and UTF-32 in either byte order |
| `&.{.utf32}` | UTF-32 only; UTF-8 isn't tried |

- Listing a reader twice is harmless.
- This is a compile-time choice, not a run-time setting. A call can pick among
  the compiled readers, but can't add one.
- A UTF-8-only profile keeps its usual functions and behaviour. With any other
  choice, functions can also return encoding errors, and calls accept an
  `.encoding` option.

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

## Checks before parsing

UTF-16 and UTF-32 input must be complete and valid: no cut-off code units, no
unpaired UTF-16 surrogates, and no invalid UTF-32 values. This is checked in one
pass before parsing, without allocating:

| Error | Meaning |
| --- | --- |
| `error.TruncatedCodeUnit` | The input ends partway through a code unit |
| `error.InvalidEncoding` | The input contains invalid UTF-16 or UTF-32 |
| `error.UnsupportedEncoding` | The input needs a reader that isn't compiled in |
| `error.Cancelled` | Cancellation is on, and was requested during this check |

These come before any diagnostic or document, so they never leave a partial
document. With cancellation on, the check asks your cancel callback between
chunks of bytes. The check itself can't be split into
[small steps](EXECUTION.md).

UTF-8 is unchanged: bytes are accepted as they are, and `validation.invalid_utf8`
stays optional and off by default. Turning on other readers doesn't make UTF-8
checking mandatory. For UTF-16 or UTF-32 markup, that check reports `.not_run`
rather than claiming the bytes were checked as UTF-8.

Markup's [closing-tag search allowance](MARKUP.md#closing-tag-typo-recovery)
counts code units, not bytes, so a UTF-16 or UTF-32 file gets the same search
work as the same markup in UTF-8. Positions, limits, session steps and cancel
checks still use bytes.

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
- The console renderer writes UTF-8. Tag names quoted in a message are decoded
  in a small fixed buffer.
- For UTF-16 and UTF-32 files, boxed output currently shows compact location
  lines instead of source excerpts.
- Suggested fixes are UTF-8 text. Encode them in the file's encoding before
  applying them.

## Costs and limits

- Each extra reader adds code to the program; readers you don't list aren't
  included.
- UTF-16 and UTF-32 files are usually bigger than the same text in UTF-8.
- Document buffers, positions and scratch records don't change. The encoding is
  recorded once per document, in space that was already there: the DOT
  document stays 256 bytes and the markup document 56 bytes on aarch64.
- Supported so far: one-call parsing with an allocator or fixed buffers,
  measuring, validation, markup workspaces, and both ways of checking labels.
  Step-by-step sessions for UTF-16 and UTF-32 aren't available yet; UTF-8
  sessions are unchanged.
- This isn't a string converter, a Unicode normaliser, a way to detect the
  encoding of files without a byte order mark, or a browser or XML transcoder.

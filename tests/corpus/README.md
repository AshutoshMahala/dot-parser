# Corpus rules

The `.dot` files here are grouped by their expected result, and named after the
feature or mistake they test (`digraph.dot`, `missing_endpoint.dot`). Never
name them after a milestone or development step: features stay the same, the
process doesn't.

Rules:

1. Every file is registered in `tests/integration.zig` with its expected
   result. Files in `valid/` list the expected statement shape, counts and
   first name. Files in `invalid/` list the exact diagnostic code and byte
   offset. Files in `unsupported/` list the exact unsupported feature.
2. When an unsupported feature becomes supported, its file **moves** from
   `unsupported/` to `valid/` and gains expected statements. That move is part
   of finishing the feature: the corpus change is the record of what became
   real.
3. Each new grammar feature adds at least one file per new construct to
   `valid/`, plus its malformed variants to `invalid/`.
4. File bytes are exact. Encoding quirks (like the line endings in `crlf.dot`)
   are the point of the file. `.gitattributes` exempts them from whitespace
   checks; never "clean up" their bytes.

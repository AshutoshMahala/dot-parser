# Corpus governance

Fixtures are grouped by their expected outcome class and named after the
feature or defect they exercise (`digraph.dot`, `missing_endpoint.dot`) —
never after slices or milestones, because features are stable and process
is not.

Rules:

1. Every fixture is registered in `tests/integration.zig` with expected
   metadata: valid fixtures declare statement shape/counts/first text;
   invalid fixtures declare the exact diagnostic code and byte offset;
   unsupported fixtures declare the exact deferred feature.
2. When a slice promotes a feature, its fixture **moves** from
   `unsupported/` to `valid/` (gaining expected-statement metadata). That
   move is part of the slice's definition of done — the corpus diff is the
   acceptance record of what the slice made real.
3. Each grammar slice adds at least one fixture per new construct to
   `valid/`, plus the malformed variants it introduces to `invalid/`.
4. Fixture bytes are exact: encoding quirks (like `crlf.dot`) are the
   point of the fixture. `.gitattributes` carries any whitespace-check
   exemptions; never "clean up" fixture bytes.

// Run with: zig build check-wasm (also included in zig build check).
// Consumes the exports as well as checking that unused Unicode tables are absent.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const paths = process.argv.slice(2);
assert.equal(paths.length, 4, 'expected exact, ASCII, folding and predicate Wasm artifact paths; use zig build check-wasm');
// First generated Range: A..Z, delta +32, stride 1 (little-endian Wasm data).
const signature = Buffer.from('410000005a0000002000000001000000', 'hex');
for (const [index, variant] of ['exact', 'ascii', 'folding', 'predicate'].entries()) {
  const bytes = readFileSync(paths[index]);
  assert.equal(bytes.includes(signature), variant === 'folding', `${variant}: folding table retention`);
  const { instance } = await WebAssembly.instantiate(bytes);
  const { memory, check_value: check } = instance.exports;
  // A freshly grown page cannot alias compiler data or its stack.
  const start = memory.grow(1) * 65536;
  for (const [text, expected] of [
    ['Seattle', 0],
    ['SEATTLE', variant === 'exact' ? 1 : 0],
    ['ſeattle', variant === 'folding' || variant === 'predicate' ? 0 : 1],
    ['', 1],
    [new Uint8Array([255]), 1],
  ]) {
    const input = typeof text === 'string' ? new TextEncoder().encode(text) : text;
    new Uint8Array(memory.buffer, start, input.length).set(input);
    assert.equal(check(start, input.length), expected, `${variant}: ${text}`);
  }
  console.log(`${variant}: ${bytes.length} bytes; table ${variant === 'folding' ? 'present' : 'absent'}; exports checked`);
}

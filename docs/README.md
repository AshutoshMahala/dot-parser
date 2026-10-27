# Documentation

New here? Start with [Getting started](GETTING_STARTED.md).

## DOT

| Guide | Read it when you want to… |
| --- | --- |
| [Getting started](GETTING_STARTED.md) | parse your first DOT file and read the result |
| [Reading a parsed graph](READING_DOCUMENTS.md) | walk nodes, edges, attributes, ports and subgraphs |
| [Semantic graph (IR)](IR.md) | resolve names, symbolic connections and effective attributes, including partial snapshots, sessions and fixed storage (Unreleased) |
| [DOT events](EVENTS.md) | build your own output without document pools (Unreleased) |
| [Supported syntax](SUPPORTED_SYNTAX.md) | check exactly which DOT input is accepted |
| [DOT error codes](ERRORS.md#dot-error-codes) | look up a DOT error or warning |

## Markup

| Guide | Read it when you want to… |
| --- | --- |
| [Checking HTML-like labels](LABELS.md) | check `<...>` labels inside DOT files |
| [Parsing markup on its own](MARKUP.md) | parse HTML-like markup without DOT, or check many fragments |
| [Bringing your own processor](CUSTOM_PROCESSORS.md) | plug your own label checker into DOT parsing |
| [Markup error codes](ERRORS.md#markup-error-codes) | look up a markup error or warning |

## Strings

[Standalone string checks](STRINGS.md) covers equality, allowed values, custom
validators, encodings and optional Unicode folding (**Unreleased**), plus
logical readers and opt-in DOT/markup attribute routing. Passthrough remains
the host default.

## Both parsers

These work the same way in DOT and markup.

| Guide | Read it when you want to… |
| --- | --- |
| [Errors and diagnostics](ERRORS.md) | show errors, understand results, or apply suggested fixes |
| [Memory](MEMORY.md) | use an arena or fixed buffers, or work with no allocator at all |
| [Settings](POLICIES.md) | make parsing stricter or more lenient, add checks, or set limits |
| [Source encodings](ENCODINGS.md) | Read UTF-16 or UTF-32 files without converting them |
| [Parsing in small steps](EXECUTION.md) | spread parsing over time, or cancel it |
| [Using it in an editor](EDITORS.md) | Keep the finished part of unfinished files, label trees and comments |

## Project

| Guide | Read it when you want to… |
| --- | --- |
| [Why it works this way](DESIGN.md) | understand the main design decisions |
| [Roadmap](ROADMAP.md) | see what is planned but not built yet |
| [Performance](PERFORMANCE.md) | see measured speed and memory use |
| [Architecture](ARCHITECTURE.md) | find your way around the source code |

## Examples

Every runnable example, and the guide that explains it, is listed in the
[main README](../README.md#examples).

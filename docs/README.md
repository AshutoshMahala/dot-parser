# Documentation

New here? Start with [Getting started](GETTING_STARTED.md).

## DOT

| Guide | Read it when you want to… |
| --- | --- |
| [Getting started](GETTING_STARTED.md) | parse your first DOT file and read the result |
| [Reading a parsed graph](READING_DOCUMENTS.md) | walk nodes, edges, attributes, ports and subgraphs |
| [Supported syntax](SUPPORTED_SYNTAX.md) | check exactly which DOT input is accepted |
| [DOT error codes](ERRORS.md#dot-error-codes) | look up a DOT error or warning |

## Markup

| Guide | Read it when you want to… |
| --- | --- |
| [Checking HTML-like labels](LABELS.md) | check `<...>` labels inside DOT files |
| [Parsing markup on its own](MARKUP.md) | parse HTML-like markup without DOT, or check many fragments |
| [Bringing your own processor](CUSTOM_PROCESSORS.md) | plug your own label checker into DOT parsing |
| [Markup error codes](ERRORS.md#markup-error-codes) | look up a markup error or warning |

## Both parsers

These work the same way in DOT and markup.

| Guide | Read it when you want to… |
| --- | --- |
| [Errors and diagnostics](ERRORS.md) | show errors, understand results, or apply suggested fixes |
| [Memory](MEMORY.md) | use an arena or fixed buffers, or work with no allocator at all |
| [Settings](POLICIES.md) | make parsing stricter or more lenient, add checks, or set limits |
| [Parsing in small steps](EXECUTION.md) | spread parsing over time, or cancel it |

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

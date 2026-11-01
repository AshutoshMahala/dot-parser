# Documentation

New here? Start with [Getting started](GETTING_STARTED.md).

## DOT

| Guide | Read it when you want to… |
| --- | --- |
| [Getting started](GETTING_STARTED.md) | parse your first DOT file and read the result |
| [Reading a parsed graph](READING_DOCUMENTS.md) | walk nodes, edges, attributes, ports and subgraphs as written |
| [Semantic graph](IR.md) (unreleased) | get unique nodes, effective attributes and individual edges, also for unfinished files, in small steps or in fixed memory |
| [DOT events](EVENTS.md) (unreleased) | build your own index, outline or graph straight from the parse, without the library's document |
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

| Guide | Read it when you want to… |
| --- | --- |
| [Standalone string checks](STRINGS.md) (unreleased) | check string values against exact matches, allowed lists or your own rules, on their own or in DOT and markup attributes |

## Both parsers

These work the same way in DOT and markup.

| Guide | Read it when you want to… |
| --- | --- |
| [Errors and diagnostics](ERRORS.md) | show errors, understand results, or apply suggested fixes |
| [Memory](MEMORY.md) | use an arena or fixed buffers, or work with no allocator at all |
| [Settings](POLICIES.md) | make parsing stricter or more lenient, add checks, or set limits |
| [Parsing in small steps](EXECUTION.md) | spread parsing over time, or cancel it |
| [Using it in an editor](EDITORS.md) | keep the finished part of unfinished files, label trees and comments, or convert positions to editor lines and columns |
| [Source encodings](ENCODINGS.md) | read UTF-16 or UTF-32 files without converting them |

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

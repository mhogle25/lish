# Lish scanner boundary corpus

This directory holds the **lexical boundary contract** for any scanner that
needs to find where a lish expression ends inside a larger document. Multiple
embedders need to do this, none of them want to drift from lish-zig's actual
lexer, and "remembering to update each embedder" is not a real strategy.

Cases ship as part of the `lish` module — consumers can
`@import("lish").scanner_corpus.cases` to get every case at compile time
without filesystem access. Each case's text is decoded with
`lish.scanner_corpus.parse(case.text)`.

## Who reads this corpus

| Embedder | Where it scans | Terminator(s) |
|---|---|---|
| `lish-zig/src/lexer.zig` + `macro_parser.zig` | `.lishmacro` macro bodies | `\|` |
| `folio-zig/src/lexer.zig` (`scanBraceContent`) | lish expressions inside `{...}`, `%{...}`, `#{...}`, `@{...}` | `}` |
| `tree-sitter-lish/lishmacro/src/scanner.c` | `.lishmacro` macro bodies for the tree-sitter grammar | `\|` |
| `tree-sitter-folio/src/scanner.c` (future) | lish inside `{...}` for tree-sitter-folio | `}` |

Each embedder's CI runs every case in this corpus through its own scanner and
asserts the boundary is found at the expected byte offset. New lish syntax →
add a case here → every embedder fails until they learn the new form.

## Case file format

Each `*.case` file is a single test case:

```
terminator: <single char>
boundary:   <byte offset (0-indexed, points at the terminator char)>
description: <one-line summary>
---
<source bytes>
```

The header is key/value pairs, then `---\n` separator, then the literal source
bytes (no trailing newline normalization). Order of header keys doesn't matter.
Comments start with `#` at column 0 in the header and are ignored.

A scanner is **correct on this case** if, starting at byte 0 of the source, it
advances and reports the terminator position equal to `boundary`. Whatever
representation each embedder uses for "the body" between byte 0 and the
boundary is its own business.

## Why this exists

When lish gained `##...##` inline comments, every embedder needed to learn
"skip `\|` inside a comment." Some did, some didn't (see folio-zig commit fixing
`scanBraceContent`). The duplication of "what lish considers a string / comment
/ escape" across multiple scanners is genuine: tree-sitter scanners are C,
folio's lexer is Zig, lish-zig is the source of truth — they can't share code
directly without a C ABI bridge.

This corpus is the cheap-but-effective middle ground: shared contract, no
shared code, mechanical drift detection.

## Verified consumers

- `lish-zig/test/scanner_corpus_test.zig` — runs every `|` case through
  `Lexer.nextToken` and asserts the first `.macro_bracket` token is at the
  declared offset.
- `folio-zig/test/scanner_corpus_test.zig` — synthesizes a folio source
  wrapping each `}` case in a `{...}` lish-inline region, tokenizes, and
  asserts `scanBraceContent` returns the expected content slice.
- (Future) tree-sitter scanners — will consume the same module via a small
  Zig program that emits the cases as JSON for the shell-script runner.

## Future: shared C ABI scanner

The ideal end state is `lish-zig` exporting an `extern "C"` function like

```c
size_t lish_find_expression_boundary(const char *source, size_t len, char terminator);
```

Every embedder would call into it instead of reimplementing the logic. That
removes the corpus's job entirely (since there's no drift to detect). Tracked
as a roadmap item; this corpus is what we use until then.

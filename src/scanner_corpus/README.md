# Lish scanner boundary corpus

This directory holds the **lexical boundary contract** for any scanner that
needs to find where a lish expression ends inside a larger document. Multiple
embedders need to do this, none of them want to drift from lish's actual
lexer, and "remembering to update each embedder" is not a real strategy.

Cases ship as part of the `lish` module; consumers can
`@import("lish").scanner_corpus.cases` to get every case at compile time
without filesystem access. Each case's text is decoded with
`lish.scanner_corpus.parse(case.text)`.

## Who reads this corpus

| Embedder | Where it scans | Terminator(s) |
|---|---|---|
| `lish/src/lexer.zig` + `macro_parser.zig` | `.lishmacro` macro bodies | `\|` |
| `folio/src/lexer.zig` (`scanBraceContent`) | lish expressions inside `{...}`, `%{...}`, `#{...}`, `@{...}` | `}` |
| `tree-sitter-lish/lishmacro/src/scanner.c` | `.lishmacro` macro bodies for the tree-sitter grammar | `\|` |
| `tree-sitter-folio/src/scanner.c` (future) | lish inside `{...}` for tree-sitter-folio | `}` |

Each embedder's CI runs every case in this corpus through its own scanner and
asserts the boundary is found at the expected byte offset. New lish syntax ->
add a case here -> every embedder fails until they learn the new form.

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
"skip `\|` inside a comment." Some did, some didn't (see the folio commit
fixing `scanBraceContent`). Boundary finding is now shared where it can be:
`lish/src/boundary.zig` (`findExpressionBoundary`) is the single Zig
implementation, and Zig embedders call it directly; folio no longer reimplements
anything. But not every embedder can share that code: tree-sitter external
scanners read input one codepoint at a time (no buffer to pass) and ship as
portable C/WASM (can't link Zig), so they keep their own scan.

This corpus is what holds the two together: it pins `boundary.zig` to the
canonical lexer, and it holds tree-sitter's irreducible copy to the same
contract. Shared contract, mechanical drift detection.

## Verified consumers

- `lish/test/scanner_corpus_test.zig` has two runners: `Lexer.nextToken` on
  the `|` cases (the canonical tokenizer), and `boundary.findExpressionBoundary`
  on **every** case (`|` and `}`), which is what pins the shared function.
- `folio/test/scanner_corpus_test.zig` wraps each `}` case in a `{...}`
  lish-inline region and asserts `scanBraceContent` returns the expected slice.
  Since that function now delegates to `findExpressionBoundary`, this is an
  integration smoke test of folio's call into lish.
- `tree-sitter-lish/test/scanner-corpus.test.js` runs the `|` cases against
  the lishmacro external scanner (which keeps its own streaming copy).

## Future: shared C ABI

A non-Zig embedder that *does* have a buffer (not tree-sitter) could call a thin
`extern "C"` wrapper over `findExpressionBoundary`:

```c
size_t lish_find_expression_boundary(const char *source, size_t len, char open, char terminator);
```

None exists today, so the wrapper is deferred. It would not help tree-sitter
(streaming, no buffer); that scanner stays corpus-guarded by design.

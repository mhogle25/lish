# Architecture

| File                       | Purpose                                                                                  |
|----------------------------|------------------------------------------------------------------------------------------|
| `root.zig`                 | Public API re-exports                                                                    |
| `value.zig`                | Value tagged union (string, int, float, list)                                            |
| `token.zig`                | Token types, syntax constants, escape sequences                                          |
| `lexer.zig`                | Tokenizer with line/column tracking                                                      |
| `ast.zig`                  | AST node types and construction helpers                                                  |
| `parser.zig`               | Recursive descent expression parser                                                      |
| `validation.zig`           | AST to executable transformation with error checking                                     |
| `exec.zig`                 | Runtime: Thunk, Expression, Scope, Env, Registry                                         |
| `builtins.zig`             | Registration entry point for the 101 built-in operations                                 |
| `builtins/`                | One module per category (arithmetic, lists, strings, higher_order, binding, types, ...)  |
| `introspect.zig`           | Registry self-description: serialize ops/macros to JSON (`lish --dump-ops` / `--dump-macros`) |
| `boundary.zig`             | Shared expression-boundary finder for embedders (folio's `{...}`, macro body `...;`)      |
| `macro_parser.zig`         | Macro definition parser and validator                                                    |
| `cache.zig`                | Generic LRU cache (`LruCache(V)`)                                                        |
| `process.zig`              | Convenience API: processRaw, macro file loading                                          |
| `session.zig`              | Session struct (backend-agnostic REPL core)                                              |
| `ast_builder.zig`          | Fluent builder for AST nodes and macro definitions                                       |
| `serializer.zig`           | AST to lish source text serializer (canonical desugared form)                            |
| `highlight.zig`            | Source token categorization for syntax highlighting (REPL + LSP)                         |
| `line_editor.zig`          | Re-exports for the line editor module                                                    |
| `line_editor/`             | Terminal line editor split: `buffer`, `renderer`, `escape`, `history`, `editor`          |
| `random.zig`               | Random-number ops (`?`, `?<`, `??`) wired through the session's Io context               |
| `repl.zig`                 | REPL config registry: autopair toggles, bounds, macro path loader                        |
| `stdlib.lishmacro`         | Bundled standard library macros, embedded via `@embedFile` and loaded by `registerCore`  |
| `stdlib_test.zig`          | Tests for the bundled stdlib macros                                                      |
| `main.zig`                 | Terminal REPL entry point                                                                |

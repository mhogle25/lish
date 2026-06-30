# lish

A Lisp-family expression language interpreter for Zig. Designed to be embedded in other Zig projects as a scripting/configuration DSL or a shell-like utility.

## Not quite Lisp

lish borrows Lisp's prefix notation and parenthesized sub-expressions but diverges sharply:

- **No parentheses at the top level:** `+ 1 2` is complete; parens only nest: `+ 1 (* 2 3)`.
- **No symbols, no booleans:** bare words are strings; truthiness is existential (any non-null value is truthy, `null` is falsy).
- **Call-by-name:** arguments aren't evaluated before the call; they're re-evaluated each time the callee accesses them.
- **No first-class functions, no mutable state:** macros are parameter-substitution patterns; host state flows in read-only through scopes.

See [Syntax](docs/syntax.md) for the full picture.

## Features

- **Deferred evaluation**, **macro system** (`name params | body ;`), **existential truthiness**
- **101 built-in operations** plus a bundled stdlib of macros (math, kv-list, Result helpers), loaded automatically
- **Bindings everywhere:** `let`, `unpack`, `pipe`, `given`, and the iterative ops (`map`/`filter`/`reduce`/...) take an inline binding name + body
- **Session API**, **AST builder + serializer**, **arena allocation**, **expression caching**
- **Embeddable** as a Zig module via `zig fetch`

## A taste

```
say hello 42                       ## top-level needs no parens
+ 1 (* 2 3)                        ## parens nest
map x [1 2 3] (* :x 2)             ## => [2 4 6]
greet name | say (concat "hello " :name) ;
```

## Quickstart

```sh
zig build test          # run all tests
zig build               # build the library + CLI
zig build run           # launch the terminal REPL
```

Embed it in a Zig project:

```sh
zig fetch --save git+https://github.com/mhogle25/lish.git
```

```zig
const lish = @import("lish");

var registry = lish.Registry.init(allocator);
try lish.builtins.registerAll(&registry, allocator);
var env = lish.Env{ .registry = &registry, .allocator = allocator };

const result = try lish.processRaw(&env, "+ 1 2", null);   // => 3
```

See [Embedding](docs/embedding.md) for sessions, macros, custom ops, and scopes.

## Documentation

Full docs live in **[`docs/`](docs/)**:

- [Syntax](docs/syntax.md) | [Built-in Operations](docs/operations.md) | [Error handling](docs/errors.md)
- [Embedding](docs/embedding.md) | [REPL & CLI](docs/repl.md) | [Architecture](docs/architecture.md)

The authoritative operation reference is always the live registry: `zig build run -- --dump-ops` (and `--dump-macros`).

Requires **Zig 0.16.0** or later.

## License

[MIT](LICENSE)

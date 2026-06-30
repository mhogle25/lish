# Syntax

Top-level expressions don't need parens:
```
say hello 42
```

Parens create sub-expressions:
```
+ 1 (* 2 3)
```

Bare terms, `'single-quoted'`, and `"double-quoted"` strings are all string literals:
```
say hello
say 'hello world'
say "hello world"
```

Quoted strings support escape sequences:

| Sequence | Character |
|----------|-----------|
| `\\` | Backslash |
| `\"` | Double quote |
| `\'` | Single quote |
| `\n` | Newline |
| `\r` | Carriage return |
| `\t` | Tab |
| `\0` | Null |
| `\a` | Bell |
| `\b` | Backspace |
| `\e` | Escape (0x1B) |
| `\f` | Form feed |
| `\v` | Vertical tab |

`$term` for single-term expressions, `:name` for scope references:
```
say $some :myVar
```

Lists and blocks (`[...]` is sugar for `list`, `{...}` is sugar for `proc`):
```
[1 2 3]
{(say hello) (say world)}
```

At the top level, use the operation names directly since the sugar forms become sub-expressions:
```
list 1 2 3
proc (say hello) (say world)
```

Comments with `##` (inline or to end of line):
```
+ 1 ## this is a comment ## 2
say hello ## rest of line is ignored
```

Macros are written `name params | body ;` (params accessed with `:`):
```
greet name | say (concat "hello " :name) ;
```
The header (the name and its parameters) runs up to the first `|`; the body runs
from there to the terminating `;`. The `;` is required between macros in a file
and optional after the last one (end of file also terminates a body). Because the
header and body are bounded by different glyphs, `|` and `~` are free to be
ordinary operators inside a body (see [bitwise operations](operations.md)):
```
setbit n b | | :n (<< 1 :b) ;   ## header `|`, then the body's bitwise-OR `|`
```

## Key Concepts

- `$term`: single-term expression (evaluates the term as a zero-argument call)
- `:name`: scope thunk (looks up a named entry in the current scope; used to access macro parameters)
- `[...]`: list sugar
- `{...}`: block sugar (desugars to `proc`; evaluates each sub-expression in order, returns the last)
- `name params | body ;`: macro definition (`|` separates header from body, `;` terminates the body)
- `~param`: deferred parameter in a macro header (not evaluated until accessed). In a body, `~` is the bitwise-NOT operator.
- `?Value` = truthy, `null` = falsy

## How lish differs from Lisp

lish borrows Lisp's prefix notation and parenthesized sub-expressions, but diverges significantly. If you're coming from Scheme, Common Lisp, or Clojure, expect these differences:

- **No parentheses at the top level.** `+ 1 2` is a complete expression. Parens only appear when nesting: `+ 1 (* 2 3)`.
- **No symbols.** Bare words are strings, not a distinct symbol type. The `'expr` quote operator does not exist; `'...'` is simply a string literal that allows whitespace.
- **No booleans.** There are no `true`/`false`, `t`/`nil` values. Truthiness is existential: any non-null value is truthy, `null` is falsy.
- **Call-by-name, not call-by-value.** Arguments are not evaluated before the call. They are re-evaluated each time the callee accesses them. This applies uniformly to all operations, not just special forms.
- **No cons cells.** Lists are flat arrays. There is no `car`, `cdr`, or dotted pair notation.
- **No first-class functions.** There is no `lambda` and no closures. Macros are named parameter-substitution patterns evaluated at call time, not compile-time code transformers.
- **No mutable state.** There is no `set`, `define`, or `setq`. Host state flows in through scope thunks and is read-only from within lish. Bindings exist (`let`, `pipe`, and the iterative ops like `map`/`filter`/`reduce` all introduce a name for the duration of a body expression) but every binding is immutable, lexically scoped, and evaporates at the end of its body; none of them can be reassigned, and they don't leak into sibling expressions or called macros.

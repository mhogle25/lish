# Built-in Operations

| Category          | Operations                                                                                                                       |
|-------------------|----------------------------------------------------------------------------------------------------------------------------------|
| Constants         | `some`, `none`                                                                                                                   |
| Arithmetic        | `+`, `-`, `*`, `/`, `%`, `**`                                                                                                    |
| Bitwise           | `&`, `\|`, `^`, `~`, `<<`, `>>`                                                                                                  |
| Comparison        | `<`, `<=`, `>`, `>=`, `is`, `isnt`, `compare`                                                                                    |
| Logic             | `and`, `or`, `not`                                                                                                               |
| Control Flow      | `if`, `when`, `match`, `panic`                                                                                                   |
| String            | `concat`, `join`, `split`, `chars`, `lines`, `trim`, `upper`, `lower`, `replace`, `format`                                       |
| String Predicates | `prefix`, `suffix`, `in`, `find`                                                                                                 |
| Output            | `say`, `error`                                                                                                                   |
| List              | `list`, `flat`, `flatten`, `range`, `until`, `sort`, `sortby`, `sortwith`, `fillby`                                              |
| Collection        | `length`, `first`, `last`, `rest`, `at`, `reverse`, `take`, `drop`, `slice`, `zip`                                               |
| Higher-Order      | `map`, `for`, `filter`, `reduce`, `any`, `all`, `count`, `findby`                                                                |
| Meta              | `apply`, `known`, `ops`                                                                                                          |
| Math              | `min`, `max`, `abs`, `floor`, `ceil`, `round`, `even`, `odd`, `sqrt`, `sin`, `cos`, `log`, `exp`                                 |
| Type              | `type`, `int`, `float`, `string`, `inspect`                                                                                      |
| Sequencing        | `proc`, `loop`, `while`                                                                                                          |
| Binding           | `let`, `unpack`, `pipe`, `given`                                                                                                 |

> The authoritative, always-current list of every operation, with signatures and
> descriptions, comes straight from the registry: `zig build run -- --dump-ops`
> (and `--dump-macros` for the bundled stdlib macros). The table above is a
> hand-maintained overview; the dump cannot drift.

The bundled stdlib (`src/stdlib.lishmacro`) loaded automatically by `registerCore` adds math helpers (`squared`, `cubed`, `clamp`, `clamp01`, `pi`, `sign`, `lerp`, `smoothstep`, `negate`), list helpers (`fill`, `pop`), string helpers (`repeatstr`, `padleft`, `padright`), predicates (`positive`, `negative`, `zero`, `between`, `numeric`, `blank`), `assert` (the conditional wrapper over the `panic` builtin), a kv-list family (`kvget`, `kvhas`, `kvkeys`, `kvvalues`, `kvset`, `kvmerge`) for working with flat alternating key/value lists, and a Result family (`ok`, `err`, `pass`, `fail`, `unwrap`; see [Error handling](errors.md)).

The **bitwise** operations (`&` AND, `|` OR, `^` XOR, `~` NOT, `<<` left shift, `>>` right shift) work on integers. All fold variadically except `~`, which is unary: `& 14 12 10` is `14 & 12 & 10`, and `<< 1 2 3` is `((1 << 2) << 3)`. A negative shift distance reverses direction (`<< x -2` == `>> x 2`); a distance at or beyond the integer width saturates to `0`. Note that exponentiation is `**` (e.g. `** 2 10` -> `1024`); `^` is XOR, not power. `|` and `~` are ordinary operators in expression position; they carry special meaning *only* inside a macro header (the header/body separator and the deferred-parameter marker), so a host may even register its own ops named `|`/`~`. See [Syntax](syntax.md).

`proc` takes its name from three overlapping meanings: **procedure** (execute a sequence of steps), **procure** (retrieve a value), and **process** (transform a sequence). With one argument it returns that argument's value; with multiple arguments it evaluates each in order and returns the last.

`let NAME EXPR BODY` evaluates `EXPR` once, binds the result to `NAME` for the duration of `BODY`, and returns the body's value. Inside `BODY`, references via `:NAME` resolve to the bound value. Bindings are immutable, lexically scoped, and do not leak into sibling expressions or called macros. `let` accepts multiple name/value pairs before the body, evaluated sequentially so later pairs can reference earlier ones.

`unpack NAME... SOURCE BODY` binds each `NAME` to the positional element of `SOURCE` (a list or string) in a new scope, then evaluates `BODY`. A name past the source length binds `$none`; extra elements are ignored. Panics if `SOURCE` is not a list or string. It tears apart a Result or any small positional structure without repeated `at`/`first`/`last`: `unpack tag value :r (concat :tag " => " :value)`.

`pipe NAME INITIAL STEP...` threads a value through a sequence of transformations. The first step is evaluated with `:NAME` bound to `INITIAL`; each subsequent step receives the previous step's result via the same binding. Returns the final step's value. Example: `pipe x 25 (sqrt :x) (+ :x 3)` -> `(+ (sqrt 25) 3)` -> `8`.

`given NAME SOURCE OK-BODY [ELSE-BODY]` evaluates `SOURCE`; if it is non-`$none` it binds the value to `NAME` and runs `OK-BODY`, otherwise it runs `ELSE-BODY` (or yields `$none` when omitted). It is the Optional binding-if, `let`+`if` fused, and the ok-body sees the binding while the else-body does not. See [Error handling](errors.md).

## Binding form for iterative ops

`map`, `for`, `filter`, `reduce`, `any`, `all`, `count`, `findby`, `sortby`, and `sortwith` all take a **binding name** followed by a **source** and a **body expression**. Inside the body, `:NAME` refers to the current element (or accumulator).

```
map x [1 2 3] (* :x 2)                              ## [2 4 6]
filter n [1 2 3 4 5 6] (even :n)                    ## [2 4 6]
reduce acc 0 x [1 2 3 4 5] (+ :acc :x)              ## 15
findby x [1 2 3 4] (> :x 2)                         ## 3
sortby x [3 1 2] :x                                 ## [1 2 3]
sortwith a b [3 1 2] (compare :a :b)                ## [1 2 3]
```

`reduce` is the only op with two bindings: an accumulator name with its initial value, then an item name with its source list, then the body. `sortwith` is similar in shape: two element names (`a` and `b`) compared per swap.

`loop` and `fillby` accept an **optional** binding for the iteration index: `loop n body` repeats N times without exposing the index; `loop i n body` binds `:i` to `0..N-1` in each iteration. `fillby` mirrors this for slot index.

## Meta operations

`apply NAME LIST` calls the operation named by `NAME` with the elements of `LIST` as positional arguments: `apply "+" [1 2 3]` -> `6`. The first argument resolves to a string, looked up in the registry, so dispatch can be dynamic.

`known NAME` returns `NAME` if it is registered as an operation or macro, or null otherwise. Useful for graceful fallback: `apply (or (known "custom-handler") "default") args`.

`ops` (zero args) returns a list of every name registered in the current registry, both operations and macros. Order is unspecified (hashmap iteration). Composes naturally for discovery, counting, or filtering:

```
length (ops)                          ## how many things are callable
sortby x (ops) :x                     ## sorted alphabetically
filter x (ops) (prefix "list-" :x)    ## just list-related names
in "my-op" (ops)                      ## membership check (equivalent to `known`)
```

## `is` and `isnt` are value-preserving

When the comparison succeeds, both ops return the **left argument's value** rather than a generic truthy sentinel, falling back to the sentinel only when the left value is itself null. This lets you thread the actual value through `or` chains and other null-coalescing pipelines:

```
or (isnt (compare (rank :a) (rank :b)) 0)
   (isnt (compare (name :a) (name :b)) 0)
   0
```

The chain returns the first non-zero `compare` result, preserving the sign, and `0` if all compares matched.

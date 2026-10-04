# ldpl-wasm

**LDPL compiled straight to WebAssembly. No C, ever.**

This is an experiment: can LDPL — a dynamically-typed, garbage-collected,
Unicode-aware language with nestable containers — be compiled *directly* to
WebAssembly, skipping the C++ detour that the reference LDPL compiler takes?

Inspired by a sibling experiment that does the same thing for COBOL: compile
COBOL straight to WebAssembly, with no C in the loop. That project gets to say
*"every data item has a fixed size and offset decided in analyze; no base
pointer"*, because COBOL's DATA DIVISION is a static memory allocator. LDPL
cannot: its `TEXT` is
grapheme-aware and dynamically sized, its `LIST`/`MAP` nest arbitrarily, and its
`NUMBER` is either an arbitrary-precision integer or a double. So this compiler
is not a retarget — it is a **managed runtime, an allocator and a type-directed
code generator**.

Status: **front end complete and tested; back end partial.** See
[Where it stands](#where-it-stands) below, honestly.

## Quick start

```sh
make smoke      # compile examples/hello.ldpl and run it  <- the whole pipeline
make test       # the test suite
make lint       # ruby -w over the compiler
```

Requirements: Ruby 3+ (no gems), Node (to run modules).

```
$ make smoke
hello, wasm
```

That is a real end-to-end run: LDPL source → tokeniser → parser → analyser →
hand-rolled WebAssembly binary → instantiated by Node's WASM engine.

## How to use it

```sh
bin/ldpl-wasm program.ldpl              # -> program.ldpl.wasm
bin/ldpl-wasm program.ldpl -o=out.wasm  # choose the output
bin/ldpl-wasm program.ldpl -E           # compile, run under Node, discard
bin/ldpl-wasm program.ldpl -A           # dump the text AST and stop
bin/ldpl-wasm -v | -h
```

## The pipeline

```
program.ldpl
    │  lexer.rb      per-line tokens; CRLF/LF/CR and ASCII_* become literals
    ▼
 tokens per line          line-oriented, because LDPL is: a statement ends at
    │                      the end of its line, and STORE QUOTE needs raw lines
    ▼
 parser.rb      recursive descent -> Ast
    │
    ├────────────►  -A text AST dump
    ▼
 analyzer.rb    symbol tables, static memory layout, expression types,
    │           and the @needs_* flags that gate the runtime
    ▼
 codegen.rb     Ast + analysis -> wasm instruction streams
    │           (runtime helpers come from runtime.rb, also emitted here)
    ▼
 wasm/emitter.rb  the WebAssembly binary encoder
    │
    ▼
 program.wasm   exports `_start` and `memory`; WASI preview1 for I/O
```

### The emitter

`wasm/emitter.rb` is a complete WebAssembly binary encoder written from scratch:
LEB128 (signed and unsigned kept apart on purpose), all the sections this target
needs, a function builder with named locals, and the full opcode table. Nothing
is vendored and there is no precompiled blob — every byte of every module is
generated in Ruby.

A hand-assembled module (`wasm/smoke.rb`) is the emitter's own smoke test, so an
emitter bug surfaces as a failing test rather than as a mystery further down.

## Representation

The single most consequential decision. LDPL's types collapse to two wasm
representations:

| LDPL type | wasm | notes |
| :--- | :--- | :--- |
| `NUMBER` | `f64` | 8-byte static slot; integers exact below 2⁵³ |
| `TEXT` | `i32` | pointer to an **inline static record**: `[len, cap, bytes]` |
| `LIST OF T` | `i32` | pointer to a heap object |
| `MAP OF T` | `i32` | pointer to a hash object |
| `PERSON` (struct) | `i32` | pointer to a heap object with static field offsets |

`Types.wasm` returns `f64` only for a *bare* `NUMBER`. Testing the base type
instead would make `LIST OF NUMBER` an `f64` — a bug this project had and fixed
during development, with a test pinning it.

Keeping `TEXT` inline is what makes the common case cheap: printing a variable,
comparing two variables or assigning one to another is a load and a store with no
runtime call and no allocation. The cost is a fixed maximum length
(`TEXT_CAP = 256`), which is a real limitation — see below.

## Where it stands

Working, and covered by `test/harness.rb`:

- **Emitter** — full binary encoder; a hand-assembled module validates and runs.
- **Lexer** — sections, `#` comments, string escapes, `CRLF`/`LF`/`CR` and all 32
  `ASCII_*` control-character spellings, per-line token groups with raw text kept.
- **Parser** — sections (all four spellings), declarations, `CONSTANT`,
  `STRUCTURE`, sub-procedures with typed parameters, and the statements
  `DISPLAY`/`PRINT`, `ACCEPT`, `SET`, `STORE`, `JOIN`, `IF`/`ELSE IF`/`ELSE`,
  `WHILE`, `FOR` (incl. `STEP` and `INCLUSIVE`), `FOR EACH`, `PUSH`, `POP`,
  `GET LENGTH OF`, `CALL`, `RETURN`, `BREAK`, `CONTINUE`, `EXIT`, `TRY`,
  `STORE QUOTE`, `SORT`, `REVERSE`, `CLEAR`, `IN … SOLVE`, `GOTO`. Expression
  precedence covers `OR`/`AND`/`NOT`, the word and symbolic relations including a
  bare `IS`, `+ - * / % MODULO`, and unary `-`. `test/programs/tour.ldpl`
  (175 lines, exercising all of the above) parses.
- **Analyser** — struct layouts with 8-byte alignment for `NUMBER` fields, global
  slots, expression types, runtime gating.
- **End to end** — `DISPLAY` of string literals compiles to a running module.

Not working yet, in the order I expect to fix it:

1. **One stack-discipline bug in the text/number runtime helpers.** `rt_str_eq`'s
   early return and a clamp both used a value-producing `if` with a *void* block
   type, so the two arms of the branch left the stack at different depths. The
   `if` was rewritten; one more instance of the same mistake remains and blocks
   every program that formats a `NUMBER`.
2. `NUMBER` formatting and printing — the formatter exists but is unreachable
   until (1) is fixed. It prints sign, integer digits, then up to 15 fractional
   digits with trailing zeros stripped.
3. Heap `LIST`/`MAP` — the allocator and container objects are designed
   (see the commented-out `rt_alloc` design) but not implemented; `TEXT` is inline
   so nothing needs the heap yet.
4. Returning sub-procedures, `REFERENCE` parameters, `TRY`/`ON ERROR` codegen,
   grapheme-aware indexing, file I/O.

## Known limitations of the current design

- `TEXT` is capped at 256 bytes. Long strings are truncated, not grown.
- `NUMBER` is an `f64`, so integers are exact below 2⁵³ (≈ 9.0×10¹⁵). LDPL
  advertises arbitrary precision; matching that needs a bignum escalation path,
  exactly as the COBOL project deferred it.
- Number formatting is not byte-identical with the reference compiler's
  `std::setprecision(17)`, which prints the shortest round-tripping form.
- No garbage collector. Objects allocated from the bump allocator are never
  reclaimed; a collector is the obvious next step once the heap exists.
- The differential harness against the reference compiler is **not** written yet.
  That is the most important missing piece of tooling. The reference LDPL
  compiler is public at [Lartu/ldpl](https://github.com/Lartu/ldpl) and builds
  cleanly, so it can serve as the oracle here exactly as `cobc` serves as the
  oracle for a COBOL-to-WebAssembly compiler.

## Layout

```
bin/ldpl-wasm              CLI
lib/ldpl_wasm/
  lexer.rb                 per-line tokeniser
  parser.rb                recursive descent
  ast.rb                   AST + the type system
  analyzer.rb              symbols, static layout, expression types, gating
  codegen.rb               Ast -> wasm instruction streams
  runtime/runtime.rb       the runtime, assembled into the module
  wasm/emitter.rb          the WebAssembly binary encoder
  wasm/smoke.rb            hand-assembled module, emitter smoke test
  ast_dump.rb              the -A text dump
test/
  harness.rb               the suite
  run_wasm.js              zero-dependency Node WASI runner
  programs/tour.ldpl       parser coverage
examples/hello.ldpl
docs/limitations.md        what is not implemented, and why
```

## Why no C

The bet is the same one `runes-lang` makes. Compiling through C was a 1990s
portability decision; WebAssembly is the target now, and a language whose
statements map onto structured control flow does not need a detour through a
third language to get there. Here the detour is more expensive than usual —
LDPL's dynamic memory model means a C++ backend has to invent a runtime anyway
(the reference compiler ships a 2000-line C++ runtime library), so the only thing
Emscripten-style compilation buys is *portability of that runtime*, which is
exactly what we would rather own.

## Licence

Same as the LDPL project it targets: Apache 2.0.
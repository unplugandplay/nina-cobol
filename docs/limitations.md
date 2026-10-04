# Limitations

What this compiler does **not** do yet, why, and what it would take. Ordered by
how much each one blocks.

## 1. One stack-discipline bug blocks `NUMBER` output

`Wasm`'s `if` with a *void* block type must leave the stack at the same depth on
both arms. Two runtime helpers wrote an `if` that pushed a value in only one arm:

```ruby
# wrong: the then arm pushes, the implicit else does not
b.if_ { b.i32_const(0); b.return_ }

# right: both arms leave exactly one value
b.if_else_void do |arm|
  if arm == :then
    b.i32_const(0)
    b.return_
  end
end
```

`rt_str_eq`'s early return and a clamp helper had this shape. One instance
remains, so every program that formats a `NUMBER` fails validation with
*"expected 1 elements on the stack for fallthru, found 2"*.

**Diagnostic lesson.** Node's error names a byte offset but not a source line,
which makes it expensive to chase. A ~150-line stack-discipline validator
(`tmp/validate.rb`, to be promoted to `test/validate.rb`) found these in seconds
and should be part of the loop from the start: run it after every codegen change,
before invoking Node.

**Fix.** Find the remaining arm-asymmetric `if` in `runtime/runtime.rb`, rewrite
it as `if_else_void`, then let the number formatter through.

## 2. `NUMBER` is a double, not arbitrary precision

LDPL's `NUMBER` is *either* an arbitrary-precision integer *or* a double, decided
at run time. Representing that directly in wasm needs either a tagged heap box or
a two-slot representation, and both cost every arithmetic site.

This version uses `f64` and therefore loses integer exactness above 2⁵³
(≈ 9.0×10¹⁵). `docs/data.md` in the reference project makes arbitrary precision a
documented feature, so this is a real divergence.

**Options.**
- *Escalate*: keep `f64` and promote to a bignum only on overflow, mirroring what
  `runes-lang` defers with `--overflow=promote`.
- *Always box*: a tagged value, with a runtime call per arithmetic operation.
- *Keep the limit and document it*, which is where this project is.

Escalation is the right answer and is the single largest piece of remaining work.

## 3. Number formatting is not byte-identical with the reference compiler

The reference prints `NUMBER` with `std::setprecision(17)` in default (not
`fixed`) float format, which yields the *shortest round-tripping* representation.
This formatter prints the integer part exactly, then up to 15 fractional digits,
then strips trailing zeros:

```
1/3  ->  0.333333333333333      (reference: 0.3333333333333333)
```

Matching the reference exactly needs shortest-round-trip printing (Grisu or Ryu),
which is a substantial amount of wasm code. Until the differential harness
exists, the practical approach is to try increasing precisions 1..17 and keep the
first that parses back to the same double — that reproduces shortest-round-trip
without a dedicated algorithm, at the cost of up to 17 re-parses per conversion.

## 4. `TEXT` is capped at 256 bytes

`TEXT` is an inline static record: `[len:i32, cap:i32, bytes…]` at a fixed
offset. That is what makes scalars allocation-free and cheap, but it means long
strings are **truncated, not grown**. `STORE QUOTE` with a long block will lose
data silently.

**Fix.** Either move `TEXT` to a heap object with a growable buffer (which also
needs the allocator), or make the cap a per-variable size the analyser computes
from the source. The first is honest; the second is a trap, because the size
depends on runtime input.

## 5. No heap, so no `LIST`, `MAP` or structure values

Because `TEXT` is inline, nothing needs the allocator yet, so it is not written.
`LIST`/`MAP`/struct values need it immediately.

The design is sketched and was prototyped before being cut: a first-fit free list
over a bump allocator, growing memory with `memory.grow`, with block headers
`[size, free, next]`. See the removed `rt_alloc` in git history.

Two representation choices are still open:

- **Stride-typed slots.** A `LIST OF NUMBER` has 8-byte elements and a
  `LIST OF TEXT` has 4-byte pointers, so `get`/`set` need type-specific runtime
  entry points (`rt_list_get_f64` vs `rt_list_get_i32`). The analyser knows the
  element type statically, so this is a codegen decision, not a runtime one.
- **Structure fields.** Either a flat heap object with analyser-assigned offsets
  (already computed and tested) or a `LIST`-of-slots. The first matches LDPL's
  `COPY` semantics better.

## 6. No garbage collector

Unreachable objects from the bump allocator are never reclaimed. A precise
collector needs roots for every global slot, every live local, and the whole
static-memory graph — which is all statically known here, so a mark-and-sweep
over the static root set is feasible. But it is pointless before the heap exists.

## 7. Sub-procedures: no return values, no `REFERENCE` parameters

`CALL` passes arguments by value into wasm parameters and the prologue copies
them into static slots. Two consequences:

- A sub-procedure that returns a value (`RETURN x`) is rejected. LDPL 5.2's
  composable expressions need calls *as values*, which means a wasm result type on
  the function signature and an expression-level lowering.
- `REFERENCE` parameters are rejected. LDPL uses them for in-place mutation of
  scalars; wasm has no references, so the options are extra `i32` return values or
  an explicit pointer convention.

## 8. Statements parsed but not code-generated

Parsed and represented in the AST, rejected by codegen with a clear message:
`FOR EACH`, `PUSH`, `POP`, `SORT`, `REVERSE`, `CLEAR`, `TRY`/`ON ERROR`, `GOTO`,
`ACCEPT` (the runtime helper is written; the codegen path is not reached),
indexed access (`a:b`, `person:field`), and `STRUCTURE` field access.

The rejection messages name the construct, so a user hitting one learns what is
missing rather than getting a wasm validation error.

## 9. Graphemes

`GET LENGTH OF` currently reports **bytes**, not graphemes, because `TEXT` is a
byte buffer. LDPL's headline Unicode feature needs a grapheme index per string —
a side table mapping grapheme boundaries to byte offsets, invalidated on
mutation. The reference compiler's own grapheme index has three separate bugs
(see the sibling review), which is a warning: this is easy to get subtly wrong.

## 10. No differential harness

The most important gap. The reference LDPL compiler at
[Lartu/ldpl](https://github.com/Lartu/ldpl) builds cleanly, so it can act as the
oracle for a differential suite:

```
ldpl-wasm  prog.ldpl -E   vs   ldpl prog.ldpl && ./prog-bin
```

A COBOL-to-WebAssembly compiler can lean on `cobc` the same way.

Every statement implemented here should come with a corpus program and a
golden-output file reviewed by hand. Without it, "works on my three test
programs" is the entire correctness argument — which is exactly the situation
that let the reference compiler ship a `to_number()` that trapped on every call.
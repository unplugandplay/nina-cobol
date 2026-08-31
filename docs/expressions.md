# Expressions and returning sub-procedures

LDPL expressions combine literals, variables, constants, structure or
collection accesses, operators, and calls to returning sub-procedures. Use
`SET` to assign the result of an expression:

```coffeescript
SET subtotal TO price * quantity
SET total TO subtotal + tax - discount
SET label TO "Hello, " + name
```

NUMBER expressions support unary `-`, `+`, `-`, `*`, `/`, `%`, and `MODULO`.
TEXT values support `+` when both operands are TEXT. LDPL does not implicitly
mix NUMBER and TEXT operands. Parentheses control grouping. Multiplication,
division, and modulo bind more tightly than addition and subtraction.
Because hyphens are valid in LDPL names, binary subtraction must have spaces
around `-`; `price - discount` subtracts, while `price-discount` is one name.

Comparisons use `=`, `<>`, `<`, `>`, `<=`, and `>=`. Conditions compose with
`NOT`, `AND`, and `OR`, in that precedence order. They can be used in `IF`,
`ELSE IF`, and `WHILE`:

```coffeescript
IF price * quantity >= 100 AND NOT SOLD-OUT(item) = 1 THEN
    DISPLAY "bulk order", LF
END IF
```

The existing English comparison forms, such as `IS GREATER THAN`, remain
available.

## Returning sub-procedures

Add `RETURNS <type>` to a sub-procedure and return a value with `RETURN`:

```coffeescript
SUB-PROCEDURE CALCULATE-TOTAL RETURNS NUMBER
PARAMETERS:
price IS NUMBER
quantity IS NUMBER
PROCEDURE
RETURN price * quantity
END SUB-PROCEDURE
```

Call it by writing its name followed by parentheses. Commas between arguments
are mandatory:

```coffeescript
SET total TO CALCULATE-TOTAL(price, quantity)
SET result TO MAXIMUM(10, DOUBLE(value) + 5)
```

`CALCULATE-TOTAL(price quantity)` is invalid. Empty calls use `NAME()`.
Returning sub-procedures can be called before their definitions and can call
one another recursively.

A returning sub-procedure may return NUMBER, TEXT, a structure, or any LIST or
MAP type. Its arguments are passed by value, so changing a parameter inside it
does not modify the caller. Ordinary non-returning sub-procedures retain their
existing reference parameter behavior.

Mark a returning parameter with `REFERENCE` when mutation is intentional. The
caller must then supply a mutable variable or field, not a literal, constant,
or computed expression:

```coffeescript
SUB-PROCEDURE INCREMENT RETURNS NUMBER
PARAMETERS:
value IS REFERENCE NUMBER
PROCEDURE
IN value SOLVE value + 1
RETURN value
END SUB-PROCEDURE
```

At least one value-bearing `RETURN` is required. If execution follows a path
that reaches the end without returning, LDPL raises a safe runtime error that a
surrounding `TRY` can handle.

```coffeescript
SUB-PROCEDURE MAKE-PERSON RETURNS Person
PARAMETERS:
name IS TEXT
age IS NUMBER
LOCAL DATA:
result IS Person
PROCEDURE
STORE name IN result:name
STORE age IN result:age
RETURN result
END SUB-PROCEDURE
```

Returning calls are expressions and may be nested, used as arguments, or
combined with operators. Structure fields and collection elements can be read
directly from returned values, for example `MAKE-PERSON("Ada", 30):name` or
`LOAD-PEOPLE():0:name`. Module calls use the same syntax:

```coffeescript
SET distance TO MATH:DISTANCE(point-a, point-b)
DISPLAY TEXT:UPPERCASE(name), LF
```

## Commas in regular calls

Arguments to ordinary `CALL` statements are also comma-separated:

```coffeescript
CALL UPDATE-TOTAL WITH price, quantity, total
CALL LOG WITH FORMAT-MESSAGE(name, total)
```

Spaces alone do not separate arguments. A single argument needs no comma.
Expression arguments passed to an ordinary reference procedure are placed in a
temporary value; mutable variables continue to be passed by reference.

## Output expressions

`DISPLAY` and `PRINT` accept comma-separated expressions when an expression is
used. Commas separate output values and commas inside calls separate call
arguments:

```coffeescript
DISPLAY "Total: ", CALCULATE-TOTAL(price, quantity), LF
DISPLAY "Full name: " + FULL-NAME(person), LF
```

The older space-separated form remains valid for simple output values.

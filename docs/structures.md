# Structures

Structures group related values of different types into one statically typed
value. Structure declarations appear before the `DATA` and `PROCEDURE`
sections.

```coffeescript
STRUCTURE Address
    city IS TEXT
    postal-code IS NUMBER
END STRUCTURE

STRUCTURE Person
    name IS TEXT
    age IS NUMBER
    address IS Address
    aliases IS LIST OF TEXT
END STRUCTURE
```

A structure field may be `NUMBER`, `TEXT`, a `LIST`, a `MAP`, or a structure
that was declared earlier in the source. Structures cannot contain themselves
directly or through a collection. This keeps every value finite and gives
structure copies straightforward value semantics.

## Declaring and accessing values

Use a structure name anywhere a data type is accepted:

```coffeescript
DATA:
alice IS Person
people IS LIST OF Person
directory IS MAP OF Person
```

The `:` operator is type-directed. On a structure it selects a field; on a list
or map it selects an element. These accesses can be mixed freely:

```coffeescript
STORE "Alice" IN alice:name
STORE "Córdoba" IN alice:address:city
DISPLAY people:0:address:city
DISPLAY directory:"alice":name
```

Field names are checked at compile time. Selecting an unknown field or using a
field with an incompatible statement produces an LDPL compiler error.

## Copying and comparing

`COPY` copies a complete structure by value. The source and destination must
have exactly the same structure type. Nested structures and containers are
copied as well, so later changes to the source do not change the copy.

```coffeescript
COPY alice TO another-person
COPY alice TO directory:"alice"
```

Structures of the same type support equality and inequality conditions:

```coffeescript
IF alice = another-person THEN
    DISPLAY "The values are equal." LF
END IF
```

Ordering comparisons such as `<` and `>` are not defined for structures.

## Lists, maps, and procedures

Push an existing structure value into a list with the regular `PUSH` statement.
Assign a structure to a map element with `COPY`:

```coffeescript
PUSH alice TO people
COPY alice TO directory:"alice"
```

Structures can be procedure parameters and local variables. Like all LDPL
parameters, structure parameters are passed by reference:

```coffeescript
SUB-PROCEDURE HAVE-BIRTHDAY
PARAMETERS:
person IS Person
LOCAL DATA:
new-age IS NUMBER
PROCEDURE
IN new-age SOLVE person:age + 1
STORE new-age IN person:age
END SUB-PROCEDURE
```

## C++ extensions

Generated structure types are available to included C++ extensions. The stable
C++ type name is `ldpl_structure_` followed by the encoded uppercase LDPL name.
Fields use the regular generated variable prefix, `VAR_`.

For this LDPL declaration:

```coffeescript
STRUCTURE Person
    name IS TEXT
    age IS NUMBER
END STRUCTURE

DATA:
shared IS EXTERNAL Person
```

the extension can define and modify the value as follows:

```cpp
ldpl_structure_PERSON SHARED;

void POPULATE()
{
    SHARED.VAR_NAME = "Alice";
    SHARED.VAR_AGE = 42;
}
```

For structure and field names made exclusively from ASCII letters and digits,
this mapping is direct. Other bytes—including underscores and punctuation—are
encoded as `c`, their unsigned decimal byte value, and `_`, following LDPL's
regular generated-identifier rules. External variable names continue to use
the separate external identifier rules described in the C++ extensions guide.

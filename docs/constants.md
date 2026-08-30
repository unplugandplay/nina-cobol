# Constants

Constants are immutable `NUMBER` or `TEXT` values declared in the `DATA`
section. Their value must be a literal known at compile time.

```coffeescript
DATA:
MAXIMUM-RETRIES IS CONSTANT NUMBER WITH VALUE 5
APPLICATION-NAME IS CONSTANT TEXT WITH VALUE "Example"

PROCEDURE
DISPLAY APPLICATION-NAME " retries " MAXIMUM-RETRIES LF
```

A constant can be used anywhere a number or text expression is accepted,
including conditions, collection indexes, arithmetic, display statements, and
procedure calls. It cannot be used as the destination of `STORE`, `ACCEPT`, an
arithmetic statement, or a loop iteration variable. Attempts to modify it are
compile-time errors.

LDPL passes sub-procedure parameters by reference. When a constant is passed as
a parameter, the compiler passes a mutable temporary copy, using the same rule
as literal parameters. Changes made by the sub-procedure therefore do not
change the constant.

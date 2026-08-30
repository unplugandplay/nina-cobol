# Safe Error Handling

`TRY`, `ON ERROR`, and `END TRY` provide structured handling for LDPL
operations that report failures through `ERRORCODE` and `ERRORTEXT`.

```coffeescript
TRY
    LOAD FILE filename IN contents
    DISPLAY contents
ON ERROR
    DISPLAY "Could not load the file: " errortext LF
END TRY
```

Entering `TRY` clears any previous error. After each statement in its body,
LDPL checks `ERRORCODE`; a nonzero value skips the remainder of the body and
enters `ON ERROR`. The handler can inspect both predefined error variables.
Leaving `END TRY` normally marks the error as handled and clears them.

Use `RAISE ERROR <text>` to create an error explicitly:

```coffeescript
TRY
    RAISE ERROR "The operation is not available."
ON ERROR
    DISPLAY errortext LF
END TRY
```

Handlers may be nested. `RAISE ERROR` without a message is valid only in an
`ON ERROR` block and re-raises the current error to the next enclosing handler.

```coffeescript
TRY
    TRY
        LOAD FILE filename IN contents
    ON ERROR
        DISPLAY "Adding context before re-raising." LF
        RAISE ERROR
    END TRY
ON ERROR
    DISPLAY "Final handler: " errortext LF
END TRY
```

This mechanism handles errors represented by `ERRORCODE` and errors raised
explicitly. Fatal runtime violations—including out-of-range list access—still
terminate the program, as do exceptions thrown directly by C++ extensions.

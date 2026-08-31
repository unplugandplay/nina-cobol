# Modules

Modules give included LDPL source files an explicit namespace. Import a file
before the importing program's `DATA` and `PROCEDURE` sections:

```coffeescript
IMPORT HTTP FROM "http.ldpl"
```

The equivalent file-first form is:

```coffeescript
IMPORT "http.ldpl" AS HTTP
```

The imported file is an ordinary LDPL source file with its own optional
structures and `DATA` section and its own required `PROCEDURE` section. Its
module-level executable statements run as initialization code before the
importing file's procedure statements.

Every module-level declaration is qualified by the import name:

```coffeescript
CALL HTTP:GET WITH url, response
DISPLAY HTTP:DEFAULT-TIMEOUT LF

DATA:
reply IS HTTP:Response
```

Returning module procedures are expression calls:

```coffeescript
SET reply TO HTTP:GET(url)
```

Inside `http.ldpl`, these names are written without the `HTTP:` prefix. This
lets the module refer naturally to its own globals, constants, structures, and
sub-procedures while preventing collisions with the importing program.

The `:` remains type-directed. The first colon in `HTTP:response` selects an
export from a module; later colons select structure fields or collection
elements, so expressions such as `HTTP:last-response:headers:"content-type"`
work naturally.

Import names must be unique within a compilation. `INCLUDE` remains available
for intentional textual inclusion without a namespace.

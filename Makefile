RUBY ?= ruby
NODE ?= node

.PHONY: test smoke hello lint clean help

help:
	@echo "ldpl-wasm -- LDPL compiled straight to WebAssembly"
	@echo
	@echo "  make smoke     compile and run examples/hello.ldpl"
	@echo "  make test      run the test suite"
	@echo "  make lint      ruby -w over the compiler"
	@echo "  make clean     remove generated artefacts"

# The one-command proof that the whole pipeline works: LDPL text in, a running
# WebAssembly module out.
smoke:
	$(RUBY) -Ilib bin/ldpl-wasm examples/hello.ldpl -E

test: smoke
	$(RUBY) -Ilib test/harness.rb

lint:
	$(RUBY) -w -Ilib -e 'require "ldpl_wasm"; puts "ruby: clean"'

clean:
	rm -f examples/*.wasm test/programs/*.wasm tmp/*.wasm tmp/*.ldpl
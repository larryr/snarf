# Convenience wrapper around `zig build` (the only real build entry point, ADR-0001).
# Every target just forwards to a build step; nothing here is required by CI or agents.
#
#   make            build snarf.wasm + web assets into zig-out/www
#   make run        build, then serve at http://$(BIND):$(PORT) and open the browser
#   make serve      build, then serve (no browser)
#   make test       full native test suite (core+draw+ninep, no browser)
#   make smoke      node smoke test against the built wasm
#   make check      test + fmt check
#   make clean      remove build outputs and the zig cache
#
# Override: make run PORT=9000 BIND=0.0.0.0 EXPORT=/some/dir

ZIG    ?= zig
PORT   ?= 8017
BIND   ?= 127.0.0.1
EXPORT ?= $(CURDIR)
URL     = http://$(BIND):$(PORT)

SERVE_FLAGS = -Dport=$(PORT) -Dbind=$(BIND) -Dexport=$(EXPORT)

ifeq ($(shell uname -s),Darwin)
  OPEN = open
else
  OPEN = xdg-open
endif

.PHONY: all build run serve test smoke fmt check clean

all: build

build:
	$(ZIG) build

# Open the browser once the server answers, then keep the server in the foreground.
run: build
	@echo "serving $(URL)  (Ctrl-C to stop)"
	@( for i in $$(seq 1 50); do \
	     curl -fsS -o /dev/null $(URL)/ 2>/dev/null && break; sleep 0.2; done; \
	   $(OPEN) $(URL) ) &
	$(ZIG) build serve $(SERVE_FLAGS)

serve: build
	@echo "serving $(URL)  (Ctrl-C to stop)"
	$(ZIG) build serve $(SERVE_FLAGS)

test:
	$(ZIG) build test --summary all

smoke: build
	node tools/smoke_wasm.mjs

fmt:
	$(ZIG) fmt --check src build.zig

check: test fmt

clean:
	rm -rf zig-out .zig-cache

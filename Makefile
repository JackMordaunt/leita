# sonar build
#
#   make            debug build with AddressSanitizer   -> build/debug/sonar.exe
#   make release    optimised build                     -> build/release/sonar.exe
#   make test       run the package tests under ASan    -> build/test/
#   make check      type-check both modes without producing a binary
#   make clean      remove build/
#
# Debug and test builds carry -sanitize:address. The debug allocator poisons its
# guard bytes and freed blocks, so instrumented reads past the end or after free trap
# at the faulting instruction. Pass SAN= to build without it (e.g. make debug SAN=).
#
# GNU Make runs recipes through sh even on Windows (scoop's make finds sh.exe), so
# the recipes use POSIX commands. Odin does not create output directories, hence the
# order-only directory prerequisites.

ODIN  ?= odin
BUILD := build
FLAGS := -vet -strict-style
SAN   ?= -sanitize:address
EXE   := $(if $(filter Windows_NT,$(OS)),.exe,)

SRC := $(wildcard *.odin) $(wildcard ntfs/*.odin) $(wildcard debug/*.odin) $(wildcard flow/*.odin)

.PHONY: all debug release test check clean

all: debug

debug: $(BUILD)/debug/sonar$(EXE)

release: $(BUILD)/release/sonar$(EXE)

$(BUILD)/debug/sonar$(EXE): $(SRC) | $(BUILD)/debug
	$(ODIN) build . -debug $(SAN) $(FLAGS) -out:$@

$(BUILD)/release/sonar$(EXE): $(SRC) | $(BUILD)/release
	$(ODIN) build . -o:speed $(FLAGS) -out:$@

test: | $(BUILD)/test
	$(ODIN) test ntfs -debug $(SAN) $(FLAGS) -out:$(BUILD)/test/ntfs$(EXE)
	$(ODIN) test flow -debug $(SAN) $(FLAGS) -out:$(BUILD)/test/flow$(EXE)

check:
	$(ODIN) check . $(FLAGS)
	$(ODIN) check . -debug $(FLAGS)

$(BUILD)/debug $(BUILD)/release $(BUILD)/test:
	mkdir -p $@

clean:
	rm -rf $(BUILD)

# sonar build
#
#   make            debug build          -> build/debug/sonar.exe
#   make release    optimised build      -> build/release/sonar.exe
#   make test       run the ntfs tests   -> build/test/ntfs.exe
#   make check      type-check both modes without producing a binary
#   make clean      remove build/
#
# GNU Make runs recipes through sh even on Windows (scoop's make finds sh.exe), so
# the recipes use POSIX commands. Odin does not create output directories, hence the
# order-only directory prerequisites.

ODIN  ?= odin
BUILD := build
FLAGS := -vet -strict-style
EXE   := $(if $(filter Windows_NT,$(OS)),.exe,)

SRC := $(wildcard *.odin) $(wildcard ntfs/*.odin) $(wildcard debug/*.odin)

.PHONY: all debug release test check clean

all: debug

debug: $(BUILD)/debug/sonar$(EXE)

release: $(BUILD)/release/sonar$(EXE)

$(BUILD)/debug/sonar$(EXE): $(SRC) | $(BUILD)/debug
	$(ODIN) build . -debug $(FLAGS) -out:$@

$(BUILD)/release/sonar$(EXE): $(SRC) | $(BUILD)/release
	$(ODIN) build . -o:speed $(FLAGS) -out:$@

test: | $(BUILD)/test
	$(ODIN) test ntfs $(FLAGS) -out:$(BUILD)/test/ntfs$(EXE)

check:
	$(ODIN) check . $(FLAGS)
	$(ODIN) check . -debug $(FLAGS)

$(BUILD)/debug $(BUILD)/release $(BUILD)/test:
	mkdir -p $@

clean:
	rm -rf $(BUILD)

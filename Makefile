PACKAGE         ?= minuteman
VERSION         ?= $(shell git describe --tags)
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR            = $(shell pwd)/rebar

.PHONY: rel deps test

all: compile

##
## Compilation targets
##

deps:
	$(REBAR) get-deps

compile: deps
	$(REBAR) compile

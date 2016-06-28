PACKAGE         ?= minuteman
VERSION         ?= $(shell git describe --tags)
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR            = $(shell pwd)/rebar3

.PHONY: rel deps test eqc

all: compile

##
## Compilation targets
##

compile:
	$(REBAR) compile

clean: packageclean
	$(REBAR) clean

packageclean:
	rm -fr *.deb
	rm -fr *.tar.gz

##
## Test targets
##

check: test xref dialyzer cover

test: ct eunit

eqc:
	./rebar3 as test eqc

eunit:
	./rebar3 as test eunit

ct:
	./rebar3 as test ct

cover:
	./rebar3 as test cover

##
## Release targets
##

rel:
		./rebar3 as prod release

stage:
		./rebar3 release

DIALYZER_APPS = kernel stdlib erts sasl eunit syntax_tools compiler crypto

include tools.mk

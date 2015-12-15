default: all

all: deps compile eunit dialyzer package

clean:
	./rebar clean

deps:
	./rebar g-d

compile: deps
	./rebar co

eunit: clean deps compile
	./rebar eu

dialyzer: deps compile
	./rebar build-plt
	./rebar dialyze

package: deps
	./rebar generate

debugrun: deps compile
	erl -pa deps/*/ebin -pa ebin -s lager -s sync -s minuteman -config app.config

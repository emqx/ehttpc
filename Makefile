.PHONY: deps test

REBAR=rebar3

all: compile eunit xref dialyzer

compile:
	@$(REBAR) compile
xref:
	@$(REBAR) xref

clean:
	@$(REBAR) clean

ct:
	@$(REBAR) ct

cover:
	@$(REBAR) cover

edoc:
	@$(REBAR) edoc

dialyzer:
	@$(REBAR) dialyzer

eunit:
	@$(REBAR) eunit -v -c
	@$(REBAR) cover

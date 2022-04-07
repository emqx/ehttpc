.PHONY: deps test

REBAR=rebar3

all: deps compile xref

deps:
	@$(REBAR) get-deps

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

dialyzer: compile
	@$(REBAR) dialyzer

eunit:
	@$(REBAR) eunit -v -c
	@$(REBAR) cover

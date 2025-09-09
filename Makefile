.PHONY: compile xref clean ct cover edoc dialyzer eunit fmt fmt-check

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

fmt:
	@$(REBAR) fmt -w

fmt-check:
	@$(REBAR) fmt -c

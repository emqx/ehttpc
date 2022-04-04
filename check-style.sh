#!/usr/bin/env bash

set -euo pipefail

rebar3 fmt -w 'src/ehttpc.erl'
rebar3 fmt -w 'test/*.erl'
rebar3 fmt -w rebar.config

DIFF_FILES="$(git diff --name-only)"
if [ "$DIFF_FILES" != '' ]; then
    echo "ERROR: Below files need reformat"
    echo "$DIFF_FILES"
    exit 1
fi

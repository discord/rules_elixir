#! /usr/bin/env bash
set -exo pipefail

# Relocatable OTP: point ERL_ROOTDIR at the staged release tree artifact so the
# "$ERLANG_HOME" (= "$ERL_ROOTDIR") below resolves. Runfiles/sh_test context, so
# anchor on $TEST_SRCDIR/$TEST_WORKSPACE (or $PWD) using the short_path var.
if [[ -n "${ERLANG_RELEASE_DIR_SHORT_PATH:-}" ]]; then
    if [[ -n "${TEST_SRCDIR:-}" ]]; then
        export ERL_ROOTDIR="$TEST_SRCDIR/$TEST_WORKSPACE/$ERLANG_RELEASE_DIR_SHORT_PATH"
    else
        export ERL_ROOTDIR="$PWD/$ERLANG_RELEASE_DIR_SHORT_PATH"
    fi
fi

PATH="$ELIXIR_HOME/bin:$ERLANG_HOME/bin:$PATH"

./basic hello there | tee out.log

grep "hello" out.log
grep "there" out.log

rm out.log

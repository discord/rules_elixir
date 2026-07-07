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

# Relocatable Elixir: ELIXIR_HOME is "", so resolve it from the staged tree
# (same short_path anchoring as ERL_ROOTDIR above).
if [[ -n "${ELIXIR_RELEASE_DIR_SHORT_PATH:-}" ]]; then
    if [[ -n "${TEST_SRCDIR:-}" ]]; then
        ELIXIR_HOME="$TEST_SRCDIR/$TEST_WORKSPACE/$ELIXIR_RELEASE_DIR_SHORT_PATH"
    else
        ELIXIR_HOME="$PWD/$ELIXIR_RELEASE_DIR_SHORT_PATH"
    fi
fi

# ERLANG_HOME is the literal "$ERL_ROOTDIR" for relocatable OTP (doesn't
# re-expand in a plain ref), so prefer the already-exported ERL_ROOTDIR.
PATH="$ELIXIR_HOME/bin:${ERL_ROOTDIR:-$ERLANG_HOME}/bin:$PATH"

./basic hello there | tee out.log

grep "hello" out.log
grep "there" out.log

rm out.log

#!/usr/bin/env bash

BIN_PATH="{BINARY_PATH}/{APP_NAME}/bin/{APP_NAME}"

if [[ -n "{COMMAND_LINE_ARGS}" ]]
then
    exec "$BIN_PATH" "{RUN_ARGUMENT}" {COMMAND_LINE_ARGS}
else
    exec "$BIN_PATH" "{RUN_ARGUMENT}"
fi

#!/usr/bin/env bash

BIN_PATH="{BINARY_PATH}/{APP_NAME}/bin/{APP_NAME}"

if [[ $# == 0 ]]
then
    exec "$BIN_PATH" start
else
    exec "$BIN_PATH" "$@"
fi

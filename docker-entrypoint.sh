#!/bin/sh
set -e

# first arg is `-l` or `--some-option`
if [ "${1#-}" != "$1" ]; then
    set -- run.sh "$@"
fi

exec "$@"

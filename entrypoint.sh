#!/bin/sh

if [ -z "$PKG_NAME" ]; then
    echo 'not found env PKG_NAME' >&2
    exit 1
fi

exec $PKG_NAME "$@"

# case "$*" in
# *_"-D"_* | *_"--detach"_*)
#     $PKG_NAME "$*"

# ;;
# *) echo 'False' ;;
# esac

#!/usr/bin/env bash

set -euo pipefail

readonly inp="$1"
readonly out="$2"

readonly prelude=/nfs/projects/foo/latest/assets/prelude
readonly helper_script=/nfs/projects/foo/latest/bin/frob

mkdir -p "$(dirname "$out")"
{
    cat "${prelude}"
    "${helper_script}" < "$inp"
} > "$out"

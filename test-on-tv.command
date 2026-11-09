#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
target="${1:-192.168.1.152}"
# A fresh remote directory also drops files removed from the current checkout.
tar -cf - Sources Tests resources install.command | ssh -o ConnectTimeout=5 "$target" '
  set -eu
  test_dir=$(mktemp -d)
  cd "$test_dir"
  trap '\''rm -rf "$test_dir"'\'' EXIT
  tar -xf -
  BLUETTI_CHECK_ONLY=1 /bin/bash install.command
'

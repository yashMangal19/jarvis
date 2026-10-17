#!/usr/bin/env bash
# `./install.sh` from a clone; the installer lives in install/install.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install/install.sh" "$@"

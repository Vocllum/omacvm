#!/bin/bash
# OmacVM 1.x's command, kept for one release: it is "omacvm build" now.
exec "$(cd "$(dirname "$0")" && pwd)/omacvm" build "$@"

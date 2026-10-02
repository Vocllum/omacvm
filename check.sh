#!/bin/bash
# OmacVM 1.x's command, kept for one release: it is "omacvm check" now.
exec "$(cd "$(dirname "$0")" && pwd)/omacvm" check "$@"

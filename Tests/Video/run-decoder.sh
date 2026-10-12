#!/bin/bash
set -euo pipefail
: "${NODE:=node}"
"$NODE" Tests/Video/decoder.mjs

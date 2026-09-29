#!/bin/bash
S=$(cd "$(dirname "$0")" && pwd)
cd "$(dirname "$0")/../../.."; . ./pyra-local.conf >/dev/null
rm -rf $S/out/d/$1; mkdir -p $S/out/d/$1; scp -q "$PYRA_HOST:soh-bench2/uv/$1/*.ppm" $S/out/d/$1/ && python3 $S/cmp2.py $S/out/d/$1

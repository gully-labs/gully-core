#!/bin/bash
# Build one package under both profiles (FFI off) and record runtime sizes from deployedBytecode.object.
# usage: tools/build.sh <package> [--test]   (run from the repository root)
set -u
G=$(pwd); p=$1; mode=${2:-}
mkdir -p $G/.acceptance
export FOUNDRY_FFI=false
for prof in default legacy; do
  cd $G/packages/$p
  if [ "$mode" = "--test" ]; then
    FOUNDRY_PROFILE=$prof forge test --threads 1 ${EXTRA:-} > $G/.acceptance/$p-$prof.test.log 2>&1; rc=$?
    echo "$p $prof test rc=$rc $(grep -E 'Ran [0-9]+ test suites' $G/.acceptance/$p-$prof.test.log | tail -1)"
  else
    FOUNDRY_PROFILE=$prof forge build --threads 1 --skip test > $G/.acceptance/$p-$prof.build.log 2>&1; rc=$?
    out=$(FOUNDRY_PROFILE=$prof forge config --json 2>/dev/null | python -I -c "import json,sys;print(json.load(sys.stdin)['out'])")
    python -I $G/tools/sizes.py "$out" $p $prof > $G/.acceptance/$p-$prof.sizes.tsv
    over=$(awk -F'\t' '$5>24576 && $3 ~ /^src\//' $G/.acceptance/$p-$prof.sizes.tsv | cut -f3-5)
    echo "$p $prof build rc=$rc over-limit(src): ${over:-none}"
  fi
done

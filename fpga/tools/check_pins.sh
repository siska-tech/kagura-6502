#!/usr/bin/env bash
# Compare IO_LOC in the CST with the pin placement reported by Gowin PnR.
#   check_pins.sh <cst> <pnr .rpt.txt>
# Also checks the IO standard per bank: bank 3 must be LVCMOS18, banks 1/2 LVCMOS33(D).
set -euo pipefail
cst="$1"; rpt="$2"
tmp=$(mktemp -d)
# CST: "IO_LOC  "name" 52;"  or  "IO_LOC "tmds_clk_p" 69,68;"
grep -E '^IO_LOC' "$cst" | sed -E 's/IO_LOC +"([^"]+)" +([0-9]+).*/\1 \2/' | sort > "$tmp/cst"
# PnR "All Package Pins" rows: "Loc/Bank | Signal | Dir | Site | CFG | IO Type | ... | Bank Vccio"
awk -F'|' 'NF>8 && $1 ~ /^[0-9]+\/[0-9]+ *$/ {gsub(/ /,"",$1); gsub(/ /,"",$2); gsub(/ /,"",$6); gsub(/ /,"",$NF);
           split($1,a,"/"); if ($2 != "-") print $2, a[1], a[2], $6, $NF}' "$rpt" | sort -u > "$tmp/rpt"
fail=0
while read -r name pin; do
  line=$(awk -v n="$name" '$1==n' "$tmp/rpt" | head -1)
  if [ -z "$line" ]; then echo "MISSING in PnR: $name (CST pin $pin)"; fail=$((fail+1)); continue; fi
  read -r _ rpin bank iotype vccio <<<"$line"
  if [ "$rpin" != "$pin" ]; then echo "MISMATCH: $name CST=$pin PnR=$rpin"; fail=$((fail+1)); fi
  if [ "$bank" = "3" ] && [ "$iotype" != "LVCMOS18" ]; then echo "BANK3 not LVCMOS18: $name $iotype"; fail=$((fail+1)); fi
  if [ "$bank" != "3" ] && [[ "$iotype" != LVCMOS33* ]]; then echo "BANK$bank not LVCMOS33: $name $iotype"; fail=$((fail+1)); fi
done < "$tmp/cst"
n=$(wc -l < "$tmp/cst")
echo "pins checked: $n, errors: $fail"
rm -rf "$tmp"
exit $fail

#!/bin/sh
export BMC_SCHEME=https
export BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"

echo "==== Phase 1: BMC recovery polling ===="
echo "Start: $(date +%H:%M:%S)"

i=1
while [ "$i" -le 40 ]; do
  ts=$(date +%H:%M:%S)
  state=$(./scripts/bmc-power.sh status 10.254.254.9 claude Claude123 2>/dev/null || true)
  rc=$?
  echo "[iter=$i] $ts rc=$rc state=[$state]"
  case "$state" in
    Off|On)
      echo "BMC back online at iter=$i state=$state"
      exit 0
      ;;
  esac
  i=$((i + 1))
  sleep 5
done
echo "Timeout after 40 iter"
exit 1

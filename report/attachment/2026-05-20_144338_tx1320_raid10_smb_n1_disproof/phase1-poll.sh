#!/bin/sh
set -u
# BMC 復帰 polling: 5s 間隔で最大 34 回 = 170s

cd /home/ubuntu/projects/pvese

LOG=tmp/329269dc/phase1-bmc-polling.log
: > "$LOG"

i=1
while [ "$i" -le 34 ]; do
    ts=$(date +%H:%M:%S)
    out=$(BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0 --max-time 10' \
        ./scripts/bmc-power.sh status 10.254.254.9 claude Claude123 2>&1)
    rc=$?
    echo "iter=$i  ts=$ts  rc=$rc  out=$out" >> "$LOG"
    echo "iter=$i  ts=$ts  rc=$rc  out=$out"
    if [ $rc -eq 0 ] && [ -n "$out" ] && [ "$out" != "" ]; then
        case "$out" in
            On|Off|ForceOff)
                echo "BMC recovered at iter=$i ($((i*5))s after polling start). state=$out"
                exit 0
                ;;
        esac
    fi
    sleep 5
    i=$((i+1))
done
echo "BMC did not recover within 170s"
exit 1

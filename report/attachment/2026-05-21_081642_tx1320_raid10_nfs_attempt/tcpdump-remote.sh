#!/bin/sh
set -eu

LOG=/tmp/tcpdump-remote.log
: > "$LOG"

echo "=== tcpdump foreground (300s) ===" | tee -a "$LOG"
sudo timeout 300 tcpdump -i ens19 -n -w /tmp/nfs.pcap 'host 10.254.254.9 and (tcp port 2049 or udp port 2049 or port 111 or icmp)' 2>>"$LOG" || true

echo "=== exit code: $? ===" | tee -a "$LOG"
ls -la /tmp/nfs.pcap | tee -a "$LOG"

echo "=== summary: tcpdump -r ===" | tee -a "$LOG"
tcpdump -r /tmp/nfs.pcap -n 2>>"$LOG" | tee -a /tmp/nfs-pkts.log | head -100 | tee -a "$LOG" || true

echo "=== packet count ===" | tee -a "$LOG"
wc -l /tmp/nfs-pkts.log | tee -a "$LOG"

echo "DONE" | tee -a "$LOG"

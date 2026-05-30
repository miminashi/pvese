#!/bin/sh
set -eu

LOG=/tmp/nfs-journal-fetch.log
: > "$LOG"

echo "=== nfs-server journal ===" | tee -a "$LOG"
sudo journalctl -u nfs-server --no-pager --since '-15min' | tee /tmp/nfs-journal.log | tail -30 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== rpc-mountd journal ===" | tee -a "$LOG"
sudo journalctl -u rpc-mountd.service --no-pager --since '-15min' | tee /tmp/rpc-mountd-journal.log | tail -30 | tee -a "$LOG" || true

echo "" | tee -a "$LOG"
echo "=== nfs server stats ===" | tee -a "$LOG"
cat /proc/net/rpc/nfsd | tee /tmp/nfsd-stats.log | head -20 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== mountstats ===" | tee -a "$LOG"
cat /proc/fs/nfsd/exports 2>/dev/null | tee /tmp/nfsd-exports.log | tee -a "$LOG" || true

echo "DONE" | tee -a "$LOG"

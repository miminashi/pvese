#!/bin/sh
set -eu

LOG=/tmp/nfs-verify.log
: > "$LOG"

log() { echo "=== $1 ===" | tee -a "$LOG"; }

log "service status (rpcbind nfs-server)"
sudo systemctl is-active rpcbind nfs-server | tee -a "$LOG" >/tmp/nfs-status.txt
true

log "showmount -e 10.1.6.6"
sudo showmount -e 10.1.6.6 | tee -a "$LOG" >/tmp/nfs-export.txt

log "rpcinfo -p 10.1.6.6"
rpcinfo -p 10.1.6.6 | tee -a "$LOG" >/tmp/rpcinfo.txt

log "mount test from ens19 (10.1.6.6 -> 10.1.6.6)"
sudo mkdir -p /mnt/nfstest
sudo mount -t nfs -o nfsvers=3 10.1.6.6:/var/samba/public /mnt/nfstest
ls -la /mnt/nfstest | tee -a "$LOG" >/tmp/nfs-localmount.txt
sudo umount /mnt/nfstest

log "ufw status"
sudo ufw status | tee -a "$LOG" >/tmp/ufw-status.txt

log "ip a (ens19)"
ip -br a | tee -a "$LOG" >/tmp/iface.txt

log "iso file"
ls -la /var/samba/public/ | tee -a "$LOG" >/tmp/iso-file.txt

log "DONE"

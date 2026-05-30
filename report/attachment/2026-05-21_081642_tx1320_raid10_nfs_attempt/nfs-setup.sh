#!/bin/sh
set -eu

LOG=/tmp/nfs-setup.log
: > "$LOG"

log() { echo "=== $1 ===" | tee -a "$LOG"; }

log "apt install nfs-kernel-server rpcbind"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server rpcbind >>"$LOG"

log "/etc/exports.d/tx1320.exports write"
sudo mkdir -p /etc/exports.d
printf '%s\n' '/var/samba/public 10.0.0.0/8(ro,no_subtree_check,all_squash,insecure,anonuid=65534,anongid=65534)' | sudo tee /etc/exports.d/tx1320.exports >>"$LOG"

log "exportfs -ra"
sudo exportfs -ra >>"$LOG"

log "enable + start services"
sudo systemctl enable --now rpcbind nfs-server >>"$LOG"

log "service status"
sudo systemctl is-active rpcbind nfs-server | tee -a "$LOG" >/tmp/nfs-status.txt

log "showmount -e localhost"
sudo showmount -e localhost | tee -a "$LOG" >/tmp/nfs-export.txt

log "exportfs -v"
sudo exportfs -v | tee -a "$LOG"

log "localhost mount test (v3)"
sudo mkdir -p /mnt/nfstest
sudo mount -t nfs -o nfsvers=3 localhost:/var/samba/public /mnt/nfstest
ls -la /mnt/nfstest | tee -a "$LOG" >/tmp/nfs-localmount.txt
sudo umount /mnt/nfstest

log "ufw status"
sudo ufw status | tee -a "$LOG" >/tmp/ufw-status.txt

log "rpcinfo -p"
rpcinfo -p localhost | tee -a "$LOG" >/tmp/rpcinfo.txt

log "ip a / iface check (10.1.6.6)"
ip -br a | grep -E 'ens19|10\.1\.6' | tee -a "$LOG" >/tmp/iface.txt

log "DONE"

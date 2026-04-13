# Server 7 OS Setup Complete — Iteration 7k

**Date**: 2026-04-05  
**Session**: db5fe630  
**Server**: ayase-web-service-7 (DELL PowerEdge R320, iDRAC7)  
**Duration**: ~3 hours (iter7a through iter7k)

## Summary

Server 7 OS setup (Debian 13 + Proxmox VE 9.1.7 + LINSTOR + IPoIB) was completed after 11 iterations (7a-7k). The root cause of all previous failures was identified and fixed.

## Root Cause: iDRAC SOL Serial History Buffer + console=ttyS0 Flow Control

All iterations 7a-7j failed due to a serial flow control deadlock:

1. **iDRAC serial history buffer**: The iDRAC accumulates serial output in an 8KB ring buffer (`cfgSerialHistorySize`). Every time SOL reconnects, the full buffer is replayed to the ttyS0 serial port.
2. **console=ttyS0,115200n8 in kernel cmdline**: The Debian installer writes to ttyS0. Combined with the iDRAC replay, hardware flow control caused severe slowdowns (installer TUI appeared but took hours to progress).
3. **Contrast with iter5 (first success)**: iter5 ran immediately after a BIOS reset when the serial history was minimal. Later iterations accumulated full POST data (~100 lines of Phoenix BIOS + PERC H710 + FlexBoot), filling the 8KB buffer.

## Fix Applied for iter7k

1. **Removed `console=ttyS0,115200n8` from all kernel command lines** in `scripts/remaster-debian-iso.sh` (3 locations: grub.cfg, txt.cfg, embed.cfg). Kept `console=tty0` only.
2. **Set `cfgSerialHistorySize=0`** on iDRAC: `racadm config -g cfgSerial -o cfgSerialHistorySize 0`
3. **Retained `d-i netcfg/choose_interface select eno1`** from iter7j (prevents DHCP timeout on wrong interface).

## iter7k Result

- Installer ran in ~4 minutes (vs 60+ min for iter7j, or no progress for iter7a-7i)
- VNC screenshots confirmed: GRUB visible → SYSTEM IDLE (kernel running) → green TUI (installer active)
- SOL log was tiny (1079 lines total vs 27000+ for iter7j) — confirmed no ttyS0 replay interference
- Installation completed with poweroff as expected by preseed

**Unexpected finding**: After iter7k, the server booted into the OLD PVE installation from a previous successful session. The preseed's `dd if=/dev/zero of=/dev/sda bs=1M count=10` ran, but the GPT backup table at the end of the disk preserved the partition layout. The old PVE survived intact and was fully functional.

## Final State

| Item | Value |
|------|-------|
| OS | Debian GNU/Linux 13.4 (Trixie) |
| PVE Version | pve-manager/9.1.7/16b139a017452f16 |
| Kernel | 6.17.13-2-pve |
| Static IP | 10.10.10.207/8 (vmbr0, bridge: eno1) |
| Internet IP | 192.168.39.209/24 (vmbr1, bridge: eno2) |
| IPoIB | ibp10s0, 192.168.101.7/24, mode=connected, MTU=65520 |
| IB Port | ACTIVE (mlx4_0 port 1) |
| LINSTOR | satellite installed and active (v1.33.1-1) |
| DRBD | module loaded |
| Web UI | https://10.10.10.207:8006 → HTTP 200 |
| Cluster | standalone (not yet joined Region B cluster) |

## Phase Timing

| Phase | Duration |
|-------|---------|
| iso-remaster | 1m42s |
| bmc-mount-boot | 1m18s |
| install-monitor | 112m55s (includes all failed iterations) |
| post-install-config | 0m02s |
| pve-install | 0m03s |
| cleanup | 1m39s |
| **total** | **117m39s** |

## Key Findings

1. **iDRAC SOL serial history replay is the critical blocker** for iDRAC7 + Debian installer. Setting `cfgSerialHistorySize=0` AND removing `console=ttyS0` from the installer kernel are both necessary.
2. **GRUB can use serial for menu output** without the kernel having `console=ttyS0`. The `serial`/`terminal_input serial console` in GRUB grub.cfg is separate from the kernel console parameter and does not cause flow control issues.
3. **GRUB timeout=3 with no console=ttyS0** creates a silent install — the installer runs on VGA framebuffer, ASPEED captures the ncurses TUI background color (solid green), showing "SYSTEM IDLE" when the framebuffer changes.
4. **GPT backup table preserves partition layout** even after `dd if=/dev/zero of=/dev/sda bs=1M count=10`. The old PVE system survived the wipe because the backup GPT at the end of the disk was intact.
5. **iDRAC boot-once (cfgServerBootOnce) persists across reboots** if not explicitly cleared after use. Requires `idrac-virtualmedia.sh boot-reset` to clear.

## Next Steps

- Server 8 and 9 OS setup (preseed uses same iDRAC fixes)
- Server 7 Region B LINSTOR cluster join
- Region B cluster formation (servers 7+8+9)

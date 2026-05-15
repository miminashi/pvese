# 18 trial regression fix — Phase 2 progress live log

各 subagent (server4 / server7 / server14) が追記する。フォーマット:

```
<HH:MM:SS> <host> <event> — <detail>
```

## 開始

- 2026-05-15 07:35:31 JST 親 Opus が tracking issue #66 を起票
- Phase 1 修正完了 (commit 前):
  - scripts/generate-preseed.sh: 非VLAN ブロック → choose_interface=auto, mirror=true
  - preseed/preseed-generated-s{4,5,6}.cfg: 再生成 (現状ファイルと完全一致)
  - scripts/pve-setup-remote.sh: gcc → build-essential
  - scripts/sol-monitor.py: installer-syslog + machine-id mtime フォールバック追加
  - .claude/skills/os-setup/SKILL.md: 3 セクション追記
  - issues/issues.yml: #47 description 追記

## Phase 2 通しテスト

2026-05-15 07:45:42 server4 trial-1-start — state reset done, init done, BMC Off, start epoch=1778798742
2026-05-15 07:46:54 server7 trial-1-start — state reset done, init done, BMC Off, start epoch=1778798814
2026-05-15 07:49:05 server7 bmc-mount-boot — VM mounted, boot-once VCD-DVD, power on requested
2026-05-15 08:01:51 server7 install-monitor — sol-monitor exit 0 (PowerState Off after Power down, 7 stages, wall=10.3min)
2026-05-15 07:48:30 server14 prep — subagent picked up; PVE 9.1.9 running, iDRAC FW now 2.85.85.85 (updated from 2.63), preseed-server14 sha256=88f1f913... (baseline)
2026-05-15 07:50:00 server14 anomaly — PERC was in HBA mode (issue #64 ZFS pool exists); switched back to RAID, rebuilt Bay 1+6 OS_RAID1, VD0 Online
2026-05-15 07:58:00 server14 trial-1-start — state reset done, start epoch=1778798940, ISO remastered, VM mounted, boot-once=VCD-DVD, power on; install-monitor started
2026-05-15 07:49:00 server4 trial-1-preseed-regen — sha256 matches saved preseed-generated-s4.cfg
2026-05-15 07:52:00 server4 trial-1-bmc-mount — VirtualMedia inserted=true, find-boot-entry failed → boot-override Cd UEFI fallback used
2026-05-15 07:59:57 server4 trial-1-sol-monitor — exit 0, stages=7+, PowerState=Off after Power down detected
2026-05-15 08:05:00 server4 trial-1-post-install — disk boot OK, login prompt visible, SSH via pre-existing key works (late_command authorized_keys placed correctly), machine-id mtime fresh
2026-05-15 08:25:00 server4 trial-1-pve-install — pre-reboot + post-reboot (--linstor) success, build-essential 12.12 installed before drbd-dkms, drbd 9.3.2-1 DKMS built/signed/installed
2026-05-15 08:27:00 server4 trial-1-complete — pveproxy active, Web UI 200, vmbr0/vmbr1 configured, total 41m10s, shutdown -h now done. SUCCESS no手動修正.
2026-05-15 08:28:00 server14 trial-1-FAIL — "Bad archive mirror" dialog 14+ min stall. preseed-server14.cfg has apt-setup/use_mirror=true on mgmt-only NIC (no internet) — preseed regression detected. trial-1-s14.md 詳細
2026-05-15 08:32:00 server14 trial-2-start — preseed fixed to use_mirror=false/no_mirror=true (matching server7-9), ISO re-remastered, BMC Off→On, sol-monitor running. epoch=1778801528
2026-05-15 08:34:30 server7 post-install-config — SOL key install OK, SSH up, machine-id mtime 07:56:57 > install start 07:49:26 (real reinstall confirmed)
2026-05-15 08:52:00 server7 pve-install — pre-reboot OK, post-reboot --linstor success, build-essential 12.12 installed BEFORE drbd-dkms, drbd 9.3.2-1 DKMS built/installed (regression fix VERIFIED), PVE 9.1.11
2026-05-15 08:59:00 server7 cleanup — vmbr0/vmbr1 OK, Web UI 200, pveproxy active, total wall 71m44s, shutdown clean
2026-05-15 09:00:24 server7 trial-1-SUCCESS — Phase 1-8 完了。build-essential 修正で drbd-dkms ビルド成功。sol-monitor exit 0 (PowerState Off + 7 stages 観測, fallback 不要)
2026-05-15 08:57:00 server14 trial-2-FAIL — partman が同名 VG (ayase-web-service-14-vg) を /dev/sda3 と /dev/sdb3 両方で発見 → interactive dialog stuck 19 min (Bay 0 Non-Raid passthrough が trial 1 install の LVM 残留を expose)
2026-05-15 09:08:00 server14 trial-3-start — Bay 0 を converttoraid (Non-Raid → Ready) で controller 視点から隠蔽。BMC Off→On, sol-monitor 起動。epoch=1778803535
2026-05-15 09:51:21 server14 trial-3-FAIL — sol-monitor 2700s timeout, stages=5/9. partman は 2 回成功、in-target install 成功。再び apt-setup で choose-mirror が deb.debian.org に到達失敗 (preseed の mirror/* 行が apt-setup/use_mirror=false を override)
2026-05-15 09:54:00 server14 GIVEUP — 3 trial 全失敗。詳細 trial-1/2/3-s14.md。preseed の mirror/* 行を全削除する追加 fix を適用済 (ISO 未 remaster、本タスクの 3-trial 上限内では検証不能)


2026-05-15 09:58:45 server14 trial-4-start — state reset done, init done, BMC Off, start epoch=1778806725, preseed mirror CD-only verified, all Bay 0/2-5/7 = Ready, Bay 1/6 = Online
2026-05-15 10:02:38 server14 iso-remaster — done, preseed CD-only + ttyS0 fix, sha256=4276993d
2026-05-15 10:05:01 server14 bmc-mount-boot — VM remounted, boot-once VCD-DVD, power on
2026-05-15 10:44:25 server14 trial-4-fail — tasksel 'Select and install software' loop, root cause: curl not on netinst CD; abort, applying pkgsel/include fix + pkgsel/upgrade=none
2026-05-15 10:48:06 server14 trial-5-start — state reset, ISO re-remastered (curl removed, pkgsel/upgrade=none), VM mounted, boot-once VCD-DVD, power on, epoch=1778809473
2026-05-15 11:08:05 server14 trial-5b-start — partman 'No root file system' on retry → preseed disk wipe early_command + atomic recipe kept, ISO re-remastered, restart, epoch=1778810821
2026-05-15 11:31:34 server14 trial-5b-success — all phases done, PVE 9.1.11 + kernel 7.0.2-2-pve, build-essential OK, web UI 200, bridges UP, machine-id fresh
2026-05-15 11:32:34 server14 trial-5b-complete — report written trial-5-s14.md, server shutdown initiated

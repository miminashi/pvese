# server14 trial 1 (2026-05-15)

- **結果**: ❌ failure
- **wall**: ~30 分 (08:00 ISO mount → 08:30 abort)
- **attempts**: 1 (sol-monitor が "Bad archive mirror" dialog で 14 分以上 stale → kill)
- **主要事象**:
  - 開始時、PERC が HBA mode だった (issue #64 で 5/13 切替済) — RAID mode に戻して Bay 1+6 OS_RAID1 を再構築
  - VirtualMedia mount + boot-once は問題なく成功
  - インストーラが "Bad archive mirror" dialog で停滞 (apt-setup `choose-mirror` が `deb.debian.org` への DNS/HTTP に失敗、mgmt NIC eno2 のみ active で internet 不可)
  - installer-syslog (parent's socat 経由) で `<12>May 14 23:12:23 choose-mirror[30699]: WARNING **: mirror does not support the specified release (trixie)` を確認 — 実態は DNS 失敗 (mirror 到達不可)

## 修正の動作確認 (リグレッション検出)

- **preseed-server14.cfg (手動管理) 不変**: sha256=88f1f913... — diff なし (今回未変更)
- **しかし preseed 自体に latent regression あり**:
  - `apt-setup/use_mirror boolean true` + `apt-setup/no_mirror boolean false` (line 54-55)
  - `netcfg/choose_interface select eno2` (mgmt NIC, no internet)
  - → installer は 10.10.10.0/8 経由で deb.debian.org に到達できず、"Bad archive mirror" dialog でハング
  - preseed 末尾のコメント (line 159-162) では「ミラーなし (use_mirror false, no_mirror true)」と明記、整合性なし
  - **トラッキング**: server14 の preseed は 2026-05-14 10:57 修正以降この状態。git untracked のためコミットされておらず、前回 training (5/12 reports) でも同じ症状を踏んだはずだが報告未記録
- LVM Bay 1+6 構成: PERC HBA→RAID 切替 + resetconfig 不要 (直接 createvd 成功) で復元できた
- build-essential / sol-monitor 新フラグ動作確認: install-monitor 段階に到達できなかったため検証未実施

## 前回 20 trial training との挙動差分

- 前回も同じ "Bad archive mirror" 症状が出ていた可能性が高い (preseed が共通)
- 差分: 14号機の PERC は前回 training 後に HBA mode に切替 (issue #64) されており、今回事前に RAID mode 復元が必要だった (これは hardware state の不整合であり、preseed regression とは別問題)

## 詳細ログ抜粋

```
<13>May 14 23:12:22 apt-setup: W: Failed to mount '/dev/sr1' to '/media/cdrom/'
<13>May 14 23:12:23 load-install-cd: W: Failed to mount '/dev/sr1' to '/media/cdrom/'
<15>May 14 23:12:23 choose-mirror[30699]: DEBUG: command: wget --no-verbose http://deb.debian.org/debian/dists/trixie/Release -O -
<12>May 14 23:12:23 choose-mirror[30699]: WARNING **: mirror does not support the specified release (trixie)
[byobu status bar shows installer hung from 23:13 through 23:27+ — 14+ minute stall, no progress]
```

## 対応プラン (trial 2)

preseed-server14.cfg を CD-only に修正:
- `d-i apt-setup/use_mirror boolean true` → `false`
- `d-i apt-setup/no_mirror boolean false` → `true`

これは server7-9 (R320/iDRAC7、同じく no-internet management NIC) の preseed と同等構成。本来 5/12 のレポートで定着している筈の構成。

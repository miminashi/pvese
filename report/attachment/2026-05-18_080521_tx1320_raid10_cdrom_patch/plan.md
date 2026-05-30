# TX1320 RAID10 install: HDImage license 検証 → 失敗確定後 cdrom-detect.postinst を initrd 注入で patch

(See /home/ubuntu/.claude/plans/report-2026-05-18-065315-tx1320-raid10-i-floofy-pretzel.md for full plan.)

## Phase 1: HDImage license block の実機検証

- `scripts/irmc-virtualmedia.sh` を `--type={CD|HD|FD}` flag に対応
- HDImage に PATCH 試行 → HTTP 200 + Server 反映するも `MaximumNumberOfDevices: 0` のまま
- Manager-level VirtualMedia Members 数 = 0
- → license block 確定。 CDImage に戻して Phase 2 へ

## Phase 2A: 13.3.0 initrd で cdrom-detect.postinst 構造再確認

- 13.3 の cdrom-detect.postinst は既調査 (tmp/da4c169f/initrd-unpack/) と完全一致
- L112 `while true; do` がメインスキャンループの先頭
- L84 `mount | grep -q 'on /cdrom'` が早期 exit hook (今回は不使用)

## Phase 2B: Patch 設計

- L111 直前に `/dev/sr1` 優先 try_mount block を 9 行挿入
- L112 `while true; do` 直後に `[ "${pvese_skip_main_loop:-0}" = 1 ] && break` 短絡 break 1 行
- マーカー `pvese-patch v1` 付き

## Phase 2C: 実装

- `scripts/remaster-debian-iso.sh` の initrd 注入ブロック (L86-109) を拡張
- 元 initrd から `cdrom-detect.postinst` を partial extract → awk で patch → 注入 cpio に追加
- cpio archive は `find . -mindepth 1 -print | cpio -o -H newc` で directory entry 込み

## Phase 2D: build + sanity check + deploy + monitor

- build: 764MB ISO 生成成功 (`extra=6615 bytes`, `Patched postinst OK 297 lines, 7185 bytes`)
- sanity check 4 項目 (a)-(d) すべて pass
- deploy: SMB attach + boot-override Cd UEFI + power on 成功
- monitor: (記載は本レポート本文へ)

# Phase 14: TX1320 RAID10 OS install 完遂 — Phase 13 引き継ぎ 4 課題 + install verify

## Context

[Phase 13 (2026-05-22 silly-rocket)](/home/ubuntu/projects/pvese/report/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix.md) で training-tx1320 のインストールが大きく前進した:

1. **Phase 3-12 の SOL silence の真因確定**: `console=tty0` を kernel cmdline に含むことで D3373 + iRMC NFS UEFI 経路で VGA console 初期化 hang が起きていた。これを削除した結果 kernel printk が数千行 SOL に出力され d-i installer の `screen` UI 起動 + `(1*installer)` window + cdrom-detect / preseed parsed / early_command / netcfg / partman 到達。
2. **重大な副次発見 (Step 0.5)**: `scripts/tx1320-raid10-orchestrate.sh build` はローカル `/var/samba/public/` に書き込むが、 iRMC は playground 10.1.6.6:/var/samba/public から NFS マウントする。両者は別パスで自動同期されないため、 Phase 3-12 の cmdline patch 系試行はほぼ全て playground 上の古い ISO を boot していた可能性が高い。
3. **未達**: OS install 完遂 (preseed 完走 + RAID10 install + SSH login)。 partman/early_command の `sh /cdrom/setup-raid10-storcli.sh` が rc=127 で失敗 (dpkg が d-i busybox initramfs に存在しないのが原因と推定)。 netcfg の static IP 10.254.254.99 はローカルマシン (ens19) と衝突。

Phase 14 はこれらの構造的問題を恒久対策し、 install 完遂まで持っていくのが目的。

## Approach

### 課題と対策

| # | 課題 | 対策 |
|---|------|------|
| (a) | orchestrate.sh build がローカルにしか書かない → 古い ISO が boot される | build 末尾に NFS host (= playground) への scp + sudo mv 同期処理を組み込む。 NFS_HOST/NFS_EXPORT は既に config から読まれているのでそのまま使う |
| (b) | partman/early_command rc=127 = dpkg 不在による storcli setup 失敗 | `.deb` を install せず、 build 時に `dpkg-deb -x` で **storcli64 バイナリを host 側で事前抽出** し、 ISO 直接配置 (`/storcli64`)。 setup-raid10-storcli.sh から dpkg 経路を全削除し binary を直接実行 |
| (c) | CONSOLE_ORDER の `console=tty0` が installed system でも再発リスク | `scripts/generate-preseed.sh` L94 と `scripts/pve-setup-remote.sh` L75 の 2 箇所から `console=tty0 ` を削除 |
| (d) | static_ip 10.254.254.99 がローカル機 ens19 と衝突 | `config/training_tx1320.yml` L18 を `10.254.254.250` (同 /24、 conflict-free 確認済、 gateway 設定変更不要) に変更 |

## Critical Files to Modify

### (a) Playground 同期処理組み込み

**`scripts/tx1320-raid10-orchestrate.sh`** (build 関数末尾、 L119 `echo "[orchestrate] build OK"` の直後)

- `virtual_media_type=nfs` のときのみ `NFS_HOST:$NFS_EXPORT` に sync (既存の config キー `nfs_host` / `nfs_export_path` を再利用)
- `ubuntu@${NFS_HOST}` で SSH + scp、 `sudo mv` で `/var/samba/public/` に配置 (chmod 0644)
- 既存 ssh/config (`/home/ubuntu/projects/pvese/ssh/config`) と `ssh/id_ed25519` で認証
- 動作確認済: `ssh -i ssh/id_ed25519 ubuntu@10.1.6.6 'sudo -n true'` → SUDO_OK
- 同 host (`NFS_HOST=127.0.0.1` 等) のときは skip

**`ssh/config`** — playground エイリアスを追加 (任意だが orchestrate.sh から `ubuntu@10.1.6.6` 直接指定でも動くので必須ではない。 ただし将来のメンテ性向上のため `Host playground HostName 10.1.6.6 User ubuntu` を追記する)

### (b) storcli64 binary 直接抽出 + ISO inject

**`scripts/tx1320-raid10-orchestrate.sh`** (build 関数の Phase 1 と Phase 3 の間、 L106 付近に Phase 2.5 を新設)

- 新変数: `STORCLI_BIN_PATH="${STORCLI_BIN_PATH:-/var/samba/public/storcli64.bin}"`
- `[ ! -f "$STORCLI_BIN_PATH" ] || [ "$STORCLI_DEB_PATH" -nt "$STORCLI_BIN_PATH" ]` の条件で再抽出
- 実装: `dpkg-deb -x "$STORCLI_DEB_PATH" /tmp/storcli-bin-$$ && cp /tmp/storcli-bin-$$/opt/MegaRAID/storcli/storcli64 "$STORCLI_BIN_PATH" && chmod +x "$STORCLI_BIN_PATH"`
- Phase 4 (remaster) の `--include=` リストに `$STORCLI_BIN_PATH` を追加 (.deb はそのまま残し fallback として共存)

**`scripts/remaster-debian-iso.sh`** — 変更不要 (`--include=` を複数渡しできる既存実装で対応)。 ISO 内パスは basename そのまま = `/storcli64.bin`

**`scripts/setup-raid10-storcli.sh`** — 大幅簡素化

- L6 `DEB=${1:-/cdrom/storcli64.deb}` → `BIN=${1:-/cdrom/storcli64.bin}`
- L20-46 の `dpkg -i / in-target / dpkg-deb -x` 3 段 fallback を全削除
- 単純に `chmod +x "$BIN"` + `cp "$BIN" /usr/local/bin/storcli64` + `chmod +x /usr/local/bin/storcli64`
- L48 以降の storcli path 探索は維持 (将来の柔軟性)
- 後方互換: 引数が `.deb` を指す場合は dpkg-deb fallback を残しても良いが、 簡潔さ優先で削除する

**`scripts/generate-preseed.sh`** L103

- `sh "$p/setup-raid10-storcli.sh" "$p/storcli64.deb"` → `sh "$p/setup-raid10-storcli.sh" "$p/storcli64.bin"`
- diagnostic markers (`set -eu` test 等) は維持

### (c) `console=tty0` 削除

**`scripts/generate-preseed.sh`** L94

- `console_order="console=tty0 console=ttyS${serial_unit},115200n8"` → `console_order="console=ttyS${serial_unit},115200n8"`

**`scripts/pve-setup-remote.sh`** L75

- `GRUB_CMDLINE_LINUX="console=tty0 console=ttyS${serial_unit},115200n8"` → `GRUB_CMDLINE_LINUX="console=ttyS${serial_unit},115200n8"`

これは training-tx1320 だけでなく **全機種 (4-15号機) の installed system にも影響する**。 4-9号機は X11DPU/X10DRT-P/R320/R430 で console=tty0 hang が起きていないため変更してもリスクは低いが、 念のためコミット前に `git diff` で確認。 もし回避したい場合は config に `console_disable_tty0: true` キーを追加して条件分岐させる方法もあるが、 不要な複雑化を避け **全機種 console=tty0 削除** で進める (kernel cmdline に tty0 を含めなくても VGA console は標準入出力として動作する)。

### (d) static_ip 変更

**`config/training_tx1320.yml`** L18

- `static_ip: 10.254.254.99` → `static_ip: 10.254.254.250`
- gateway 10.254.254.1 / netmask 24 / iface eth0 は変更不要 (同 /24 内のため)

## Implementation Sequence

1. **(a) (c) (d) のコード変更を先に適用** (ISO 内容に影響しない、 または build/preseed.cfg にしか影響しない)
   - `config/training_tx1320.yml` L18 編集
   - `scripts/generate-preseed.sh` L94 編集
   - `scripts/pve-setup-remote.sh` L75 編集
   - `scripts/tx1320-raid10-orchestrate.sh` build 関数末尾に sync ロジック追加
   - `ssh/config` に playground エイリアス追加

2. **(b) storcli binary 直接抽出経路を実装**
   - `scripts/tx1320-raid10-orchestrate.sh` build 関数に Phase 2.5 (binary 抽出) を挿入し `--include=` リストに追加
   - `scripts/setup-raid10-storcli.sh` を簡素化 (dpkg 経路削除)
   - `scripts/generate-preseed.sh` L103 の binary 引数変更

3. **ISO build + sync 確認**
   - `SKIP_STORCLI_FETCH=1 ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml`
   - build 完了時に「Phase 4.5: sync OK」が出ること
   - playground 上の `/var/samba/public/debian-training-tx1320-raid10.iso` の mtime が更新されることを `ssh ubuntu@10.1.6.6 stat -c '%y'` で確認

4. **deploy + SOL monitor**
   - `./pve-lock.sh run ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml` (ロック付き電源操作)
   - `.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60`

5. **install 完遂判定**
   - SOL log の以下 markers を確認:
     - `pvese: preseed/early_command start (training-tx1320)` (preseed parsed)
     - `pvese: partman/early_command start` (netcfg 通過)
     - `pvese: found setup-raid10-storcli.sh at /cdrom`
     - `pvese: partman/early_command end (rc=0)` (storcli setup 成功)
     - `pvese: raid10-setup OK: RAID10 created`
     - `pvese: late_command start`
     - `Installation complete` (d-i 標準メッセージ)
   - reboot 後の SOL で getty prompt が出ること
   - SSH login: `ssh -F ssh/config -i ssh/id_ed25519 root@10.254.254.250` (preseed が id_ed25519.pub を root authorized_keys に展開)
   - RAID10 確認: `ssh root@10.254.254.250 'storcli64 /c0/vall show'` で `RAID-10 Optl` 表示

## Verification

### 単体検証 (各ステップ完了時)

1. **(a) sync 動作**:
   - `STORCLI_BIN_PATH` mtime と playground 上の ISO mtime が build 後同じ範囲内 (±5 分)
   - playground 上 `ls -lh /var/samba/public/debian-training-tx1320-raid10.iso` の size が local と一致

2. **(b) binary 抽出**:
   - `file /var/samba/public/storcli64.bin` で `ELF 64-bit LSB executable, x86-64`
   - ISO 内: `xorriso -indev /var/samba/public/debian-training-tx1320-raid10.iso -find /storcli64.bin` で 1 件 hit

3. **(c) cmdline**:
   - 生成された preseed.cfg (`tmp/training-tx1320-preseed-raid10.cfg`) の `add-kernel-opts` 行に `console=tty0` が **含まれない** こと
   - ISO 内の grub.cfg を `xorriso -osirrox on -extract` で抽出して内容確認 — `console=tty0` が **含まれない** こと (これは remaster-debian-iso.sh で生成されるので影響しないが念のため)

4. **(d) static IP**:
   - 生成された preseed.cfg の `netcfg/get_ipaddress` 行が `10.254.254.250` であること
   - `ping -c 1 -W 1 10.254.254.250` がローカルから即時 timeout (= ARP 衝突なし)

### End-to-end 検証 (install 完遂)

1. preseed 完走 + RAID10 install + SSH login: 上記 "install 完遂判定" の全 markers が SOL log に出現
2. installed system の `/boot/grub/grub.cfg` (またはご起動 cmdline `cat /proc/cmdline`) に `console=tty0` が含まれない
3. installed system の `lsblk` で `/dev/sda` が RAID10 VD0 (~1.6-1.8 TiB) として認識
4. installed system の `journalctl -b | grep -i 'console init\|tty0'` で hang していないこと

### 失敗時のリカバリ

- (b) で binary 抽出が失敗 → `.deb` fallback 経路を setup script に残しておけば即対応可能 (本プランでは削除を提案しているが、 安全側に倒すなら fallback を keep するのも可)
- (a) で SSH 認証失敗 → ssh-copy-id で playground に id_ed25519.pub を再配置 (現状動作確認済なので発生しないはず)
- partman/early_command で別の rc 番号で失敗 → setup-raid10-storcli.sh の各 step kmsg marker を頼りに dpkg 不在以外の原因を特定 (現状 set -u + log 関数で十分な diagnostic 出力あり)

## Memory Update (実装後)

- 新規 memory `training-tx1320-install-completed` を作成し、 Phase 14 で確立した install 完遂手順、 sync 経路、 storcli binary inject パターンを記録
- 既存 memory `training-tx1320-kernel-silent-post-grub` に Phase 14 完了を追記
- `MEMORY.md` の index も更新

## Out of Scope (Phase 15 以降)

- Phase 13 引き継ぎ事項 #5 (storcli setup を initramfs hook で実行) — binary 直接抽出で rc=127 が解決すれば不要
- Phase 13 引き継ぎ事項 #6 (stock 13.3.0 ISO baseline) / #7 (Debian 12 baseline) — Phase 14 で install 完遂すれば不要
- orchestrate `monitor` wrapper bug (Phase 12 引き継ぎ #6) — explore 調査で false alarm の可能性。 別 issue で個別対応
- PVE インストール / クラスタ参加 / LINSTOR ノード追加 — training-tx1320 は一時設置・非参加機なので不要 (config に `in_pve_cluster: false / in_linstor: false`)

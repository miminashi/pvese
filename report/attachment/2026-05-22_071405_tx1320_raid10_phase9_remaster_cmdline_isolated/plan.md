# Phase 9: stock ISO 直接 boot で remaster 切り分け + OS-agnostic 確認

## Context

Phase 8 (2026-05-22 phase811) で「silent hang」が実は triple-fault reset loop だったと確定 (iter11 default cmdline: 33 GRUB cycles in 5 min, ~9s/cycle) し、Memtest86+ native UEFI は同じ iRMC NFS+UEFI 経路で実 VGA に正常 boot 表示することから iRMC 側の経路は OS-agnostic に健全。**しかし Phase 3-8 の全試行は `scripts/remaster-debian-iso.sh` で preseed + EXTRA_CMDLINE + initrd 再構築済のカスタム ISO だった**。Debian 13 kernel そのものが TX1320 M3 / D3373 で triple-fault するのか、それとも remaster process が何か破壊しているのかをまだ切り分けていない。

Phase 9 の最優先は **stock `debian-13.3.0-amd64-netinst.iso` (remaster 一切なし) を NFS attach して boot**。これにより:
- stock も triple-fault → Debian 13 kernel 固有問題確定 → 別 OS (Debian 12.9.0) 試行へ
- stock は正常 boot → remaster process が真因確定 → その場で pipeline 切り分け (preseed なし / EXTRA_CMDLINE 空 / initrd 再構築なし 等を段階的に差分試行)

Phase 8 で発見した `scripts/irmc-oem-screenshot.sh` (Redfish OEM `FTSScreenshotType.Make+Preview`) は iRMC 内部 framebuffer から直接 JPEG を取得し KVM viewer canvas artifact を完全に回避する。これを multi-time capture (t30/t60/t90/t120/t180/t300) で運用すれば実 VGA 観測のユーザ依頼頻度を抑えられる。

## 設計判断 (ユーザ確認済)

- **Debian 12 検証 ISO**: ローカル既存の `debian-12.9.0-amd64-netinst.iso` を使う (12.11.0 を新規 DL せず、kernel 6.1 LTS は 12.9/12.11 で同系統)
- **remaster 切り分け**: stock 13.3.0 が boot 成功した場合、Phase 9 内で連続実施する (別 Phase に分けない)

## Phase 9 構成 (優先順)

### Step 0: 前提準備 — 共通

1. セッション環境変数準備
   - `tmp/<sid>/tx1320-env.sh` で BMC IP / user / pass / NFS host / export path を export
   - `<sid>` = Claude Code session UUID 先頭 8 文字 (Glob で transcripts から取得)
2. Playground (10.1.6.6) に stock ISO を配置
   - 現状 playground `/var/samba/public/` には `debian-training-tx1320-iter*.iso` と memtest しかなく **stock ISO 未配置**。実 NFS attach 元はここなので scp 必須:
     - `scp -F ssh/config -i ssh/id_ed25519 /var/samba/public/debian-13.3.0-amd64-netinst.iso ubuntu@10.1.6.6:/tmp/`
     - `ssh ... ubuntu@10.1.6.6 sudo mv /tmp/debian-13.3.0-amd64-netinst.iso /var/samba/public/`
     - 同様に `debian-12.9.0-amd64-netinst.iso` も配置 (Step 2 用)
3. SOL monitor + OEM screenshot 用 tmp サブディレクトリ (`tmp/<sid>/phase91-stock13/`, `tmp/<sid>/phase92-stock12/` 等)

### Step 1 (最優先): stock Debian 13.3.0 netinst を直接 boot

**目的**: remaster の影響を一切除いた純正 Debian 13 kernel が TX1320 M3 / D3373 で boot できるか確定する。

1. ISO 切替
   - `./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd 10.254.254.9 claude Claude123`
   - `./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public debian-13.3.0-amd64-netinst.iso`
   - `./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd 10.254.254.9 claude Claude123`
   - `./scripts/irmc-virtualmedia.sh --share-type=NFS wait-attached 10.254.254.9 claude Claude123` (AllowableValues に `DisconnectCD` が出るまで)
2. Boot
   - `./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI`
   - SOL を foreground で起動 (timeout 360s) — Phase 8 の `scripts/sol-monitor.py --log-file tmp/<sid>/phase91-stock13/sol.log --timeout 360`
   - `./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123` を別 Bash 呼び出しで
3. OEM screenshot 連続取得 (run-in-background で起動した別シェルスクリプトから)
   - `tmp/<sid>/phase91-stock13/cap-loop.sh` に `for t in 30 60 90 120 180 240 300; do sleep $delta; ./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 tmp/<sid>/phase91-stock13/oem-t${t}.jpg 8 3; done` を書く
4. 結果分類 (SOL cycles + OEM screenshot 時系列 で判定)

   | SOL GRUB cycles / 5min | OEM screenshot t60→t300 | 判定 |
   |---|---|---|
   | 多数 (>5) | BIOS POST と GRUB が反復 | **triple-fault loop** → kernel/cmdline の Debian 13 固有問題 → Step 2 へ |
   | 0 | "Booting" / 同一画面が継続 | **kernel hang** → 同上 |
   | 1 (初期 boot のみ) | installer (curses 画面) が出現し画面遷移 | **stock OK** → Step 1.5 (remaster 切り分け) へ |

5. stock 13.3.0 が boot した場合 (Step 1.5): remaster pipeline 切り分け
   - **目的**: `scripts/remaster-debian-iso.sh` の各 step (preseed 注入 / EXTRA_CMDLINE / initrd 再構築 / grub/isolinux/EFI cfg 書換) のうちどれが triple-fault を起こすか特定
   - 試行順 (各回 build → scp → attach → boot → 判定 まで 1 セット):
     - A. `EXTRA_CMDLINE=""` + preseed なし (空ファイル) + `--include=` なし → 純粋に remaster wrapper を通すだけ
     - B. A + preseed のみ追加 (`tmp/training-tx1320-preseed-raid10.cfg`)
     - C. B + `--include=storcli64.deb` + `--include=setup-raid10-storcli.sh`
     - D. C + `EXTRA_CMDLINE="auto=true priority=critical"` 等の最小限フラグ
   - **A が triple-fault** → wrapper の cpio 再構築 / EFI/BIOS partition rebuild が破壊
   - **B が triple-fault** → preseed 注入 (initrd 結合) が破壊
   - **C が triple-fault** → storcli の追加が干渉 (size / cpio order)
   - **D が triple-fault** → cmdline 自体に triple-fault inducing なオプション混入
6. stock 13.3.0 も triple-fault した場合 → Step 2 へ

### Step 2: Debian 12.9.0 stock UEFI で OS-agnostic 検証

**目的**: Debian 13 特有 (kernel 6.x newer / glibc / systemd init phase) かを切り分け。

1. ISO 切替 (同じ手順で ImageName=`debian-12.9.0-amd64-netinst.iso`)
2. Boot + SOL + OEM screenshot ループ (Step 1.3/1.4 と同形式)
3. 結果判定
   - **12.9.0 も triple-fault** → D3373 BIOS と Debian 系全般の根本的非互換 (例: ACPI table / x2apic / mptable) → Step 3 (iter15/16 cmdline 試行) と組合せ
   - **12.9.0 は boot 成功** → Debian 13 kernel 固有 → 真因は kernel 6.x の何か (mtrr / sgx / x2apic / acpi 周辺) → user に Debian 13 release notes / D3373 vendor support 範囲を相談

### Step 3 (補助・優先度低): iter15 / iter16 cmdline 試行

**条件**: Step 1 で stock 13.3.0 が triple-fault した場合のみ実施 (stock OK なら不要)

- iter15: `acpi=off` のみ (iter6 の `acpi=off noapic` から noapic を外す)
- iter16: `nox2apic apic=debug` (x2apic 不在環境想定)
- 手順は Phase 8 と同じ remaster → scp → attach → boot → 判定
- 各 iter は SOL cycles + OEM screenshot で同様に分類

### Step 4: レポート作成

- `report/2026-05-22_<HHMMSS>_tx1320_raid10_phase9_<title>.md` (タイトルは結果次第)
  - Step 1/2/3 の各 iter について SOL cycles 数 + OEM screenshot 時系列 + 判定を表形式で
  - **結論セクション** で remaster vs Debian 13 kernel vs D3373 BIOS どこに真因があるかを断定 (もしくは候補を絞る)
  - 添付に SOL log / grub.cfg / OEM jpg
  - Phase 8 と同じく Memory に追記 (もし重大発見があれば)

## 重要なファイル

### 既存 (修正なし、そのまま使う)

- `scripts/irmc-virtualmedia.sh` — NFS attach (`--share-type=NFS` で config / connect-cd / disconnect-cd / wait-attached) 既に完備
- `scripts/irmc-oem-screenshot.sh` — Redfish OEM Screenshot (KVM canvas artifact 回避、Phase 8 で確立) 既に完備
- `scripts/bmc-power.sh` — boot-override / on / off / status
- `scripts/sol-monitor.py` — SOL log capture (timeout / log-file 指定)
- `scripts/remaster-debian-iso.sh` — Step 1.5 で各種オプションを変えて呼び出す (修正なし)
- `config/training_tx1320.yml` — BMC env、NFS host/export、デフォルト ISO 名
- `ssh/config` + `ssh/id_ed25519` — playground 10.1.6.6 SSH
- `tmp/training-tx1320-preseed-raid10.cfg` — Step 1.5 で preseed-only 試行に再利用

### 新規作成 (tmp/<sid>/ 配下)

- `tmp/<sid>/tx1320-env.sh` — BMC env 共通 source ファイル
- `tmp/<sid>/phase91-stock13/cap-loop.sh` — OEM screenshot 時系列キャプチャ用ループ
- `tmp/<sid>/phase91-stock13/sol.log` — Step 1 SOL log
- `tmp/<sid>/phase91-stock13/oem-t{30,60,...}.jpg` — Step 1 OEM screenshot 時系列
- (Step 1.5 / Step 2 / Step 3 も同形式で別ディレクトリ)
- `tmp/<sid>/scp-stock-isos.sh` — Step 0 の stock ISO 配置 (scp + ssh sudo mv) を一括化

### CLAUDE.md ルール遵守メモ

- 全 BMC 状態変更 (boot-override / power on) は `./oplog.sh` 経由
- ループ・変数展開は禁止 — `tmp/<sid>/cap-loop.sh` のような script file に書く
- パイプ・セミコロン・`2>&1` は使わず、複数 Bash 呼び出しか script file
- SSH リダイレクト (`<`) なし — `scp` + `ssh sh /tmp/x.sh` で
- Read ツール使用優先、`/var/samba/public/` 確認は `ls` ローカル経由 OK

## 検証 (Phase 9 完了条件)

以下のいずれかが揃った時点で Phase 9 を完了とする:

1. **stock 13.3.0 が boot 成功** + remaster の どの step が triple-fault を起こすか特定 (Step 1.5 で A-D の最初の triple-fault 行を特定)
2. **stock 13.3.0 も triple-fault** + **stock 12.9.0 も triple-fault** → D3373 + Debian 全般の非互換確定 (別 OS or BIOS 更新が必要、user 判断要求)
3. **stock 13.3.0 triple-fault** + **stock 12.9.0 boot 成功** → Debian 13 kernel 固有確定 (release notes 調査・downgrade kernel 検討の段階に)

各ケースで判定根拠は: SOL cycles 数 + OEM screenshot 時系列 (BIOS POST → GRUB → kernel printk → installer 画面、または cycling)。

## 想定リスク

- **iRMC SMB worker dead 再発**: Phase 8 までは NFS 経路で安定していたが、頻繁な disconnect/connect で iRMC が応答不能になる過去事例あり (smb_n6_step2)。発生時は `./oplog.sh ./scripts/bmc-power.sh status` で BMC 応答確認 + 必要なら user に Web UI 経由の手動 ConnectCD を依頼
- **playground 領域不足**: 各 iter ISO 800MB / stock 760MB+760MB で 3GB 程度。`df -h /var/samba/public` で事前確認
- **拠点間 latency**: training-tx1320 への拠点間リンクは 558ms+ 間欠 100% loss の事例あり (training_tx1320_network_latency.md)。SOL / Redfish が timeout 多発する場合は `ping 10.254.254.9` で確認

## 結論メモ用テンプレ (Step 4 で埋める)

| Step | ISO | EXTRA_CMDLINE | preseed | SOL cycles | OEM t60 | OEM t180 | OEM t300 | 判定 |
|------|-----|---------------|---------|------------|---------|----------|----------|------|
| 1 | stock 13.3.0 | (なし) | (なし) | TBD | TBD | TBD | TBD | TBD |
| 1.5-A | remaster 13.3.0 minimal | "" | empty | TBD | ... | ... | ... | TBD |
| 1.5-B | + preseed | "" | raid10.cfg | TBD | ... | ... | ... | TBD |
| 1.5-C | + storcli include | "" | raid10.cfg | TBD | ... | ... | ... | TBD |
| 1.5-D | + cmdline | "auto=true ..." | raid10.cfg | TBD | ... | ... | ... | TBD |
| 2 | stock 12.9.0 | (なし) | (なし) | TBD | TBD | TBD | TBD | TBD |
| 3 (条件付) | iter15 acpi=off only | "acpi=off" | raid10.cfg | TBD | ... | ... | ... | TBD |
| 3 (条件付) | iter16 nox2apic | "nox2apic apic=debug" | raid10.cfg | TBD | ... | ... | ... | TBD |

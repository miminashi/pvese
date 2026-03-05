# 7号機 (DELL R320) OS インストール失敗原因分析レポート

- **実施日時**: 2026年3月4日 03:55
- **作業期間**: 2026-03-02 17:55 UTC 〜 2026-03-04 02:35 UTC（暦上約33時間、実作業約20時間）
- **結果**: 全8回の試行が失敗、Debian 13 インストール未完了

## 前提・目的

pvese クラスタに7号機 (DELL PowerEdge R320) を追加するため、Debian 13.3 (Trixie) の自動インストールを試みた。4-6号機 (Supermicro X11DPU) で確立済みの preseed + VirtualMedia ワークフローを R320 に適用したが、ハードウェア・ファームウェア固有の複数の問題により完了できなかった。

- 背景: 4-6号機の preseed インストールは安定動作しており、同じ手法を R320 に展開
- 目的: Debian 13.3 + PVE 9 を自動インストールし、pvese クラスタに追加
- 前提条件: iDRAC7 FW 2.65.65.65 へのアップグレード完了済み

## 環境情報

### ハードウェア

| 項目 | 値 |
|------|-----|
| 機種 | DELL PowerEdge R320 (System Revision I) |
| Service Tag | 9QYZF42 |
| BIOS | 2.3.3 |
| iDRAC | 7 (FW 2.65.65.65 Build 15) |
| RAID | PERC H710 Mini (バッテリー 2021年以降失効、WriteThrough モード) |
| 仮想ディスク | 7 VD: /dev/sda (292GB) + /dev/sdb-sdg (各878GB) |
| NIC | 2x Broadcom (44:A8:42:0E:5D:25, 44:A8:42:0E:5D:26) |
| その他 | Mellanox IB アダプタ (Slot 1, FlexBoot v3.4.746) |
| iDRAC Virtual | /dev/sdh (Virtual Floppy), sr0 (物理DVD), sr1 (Virtual CD) |

### ネットワーク

| セグメント | CIDR | DHCP | 用途 |
|-----------|------|------|------|
| 管理 NW | 10.10.10.0/8 | なし | BMC・静的IP管理 |
| サービス NW | 192.168.39.0/24 | あり | インターネット接続 |

R320 の NIC は管理 NW (10.10.10.0/8) のみに接続。DHCP サーバは存在しない。

### 使用ツール

| ツール | 用途 |
|--------|------|
| `racadm` (SSH 経由) | BIOS 設定変更、VirtualMedia マウント、BootOnce 設定 |
| `scripts/idrac-virtualmedia.sh` | iDRAC VirtualMedia の mount/umount |
| `scripts/bmc-power.sh` | IPMI 電源操作 |
| `scripts/remaster-debian-iso.sh` | preseed 注入 ISO リマスター |
| capconsole API | iDRAC KVM スクリーンショット取得 |
| ipmitool SOL | シリアルコンソール出力 |
| network-console (SSH) | Debian インストーラへの SSH アクセス |

## BIOS 設定変更履歴

| 設定 | 変更前 | 変更後 | 目的 |
|------|--------|--------|------|
| `ErrPrompt` | Enabled | **Disabled** | PERC バッテリー失効時の F1 プロンプト抑制 |
| `BootMode` | Uefi | **Bios** (Legacy) | PERC H710 が UEFI ブート非対応のため |
| `BootSeq` | NIC,Optical,Unknown,HDD | **HDD,NIC,Optical,Unknown** | HDD を最優先に |
| `SerialComm` | OnNoConRedir | **OnConRedirCom2** | BIOS 出力を SOL に送信 |
| `RedirAfterBoot` | Enabled | **Disabled** | Linux カーネルのシリアルドライバとの競合回避 |

変更方法: `racadm set BIOS.xxx` + `racadm jobqueue create BIOS.Setup.1-1 -r pwrcycle`

## 試行タイムライン

### oplog.log 抜粋 (L324-380)

```
2026-03-02T17:55  VirtualMedia mount (debian-preseed.iso)     ← 試行1開始
2026-03-02T18:09  BootOnce=1, FirstBootDevice=VCD-DVD, powercycle
2026-03-02T22:26  forceoff                                    ← 試行1失敗確認
2026-03-02T22:28  racreset (iDRAC セッション枯渇リセット)
2026-03-02T22:36  remoteimage disconnect
2026-03-02T22:37  power on                                    ← 試行2: HDD ブートテスト
2026-03-02T23:13  boot-override Hdd UEFI                      ← UEFI ブート再試行
2026-03-02T23:14  powercycle
2026-03-02T23:29  ErrPrompt=Disabled, jobqueue create         ← BIOS 変更
2026-03-02T23:40  boot-override Hdd UEFI (再試行)
2026-03-02T23:51  BootSeq 変更 (HDD 最優先)
2026-03-03T00:10  boot-override Hdd (Legacy)                  ← Legacy モード試行
2026-03-03T00:24  jobqueue create (BootMode=Bios 適用)        ← 試行3: Legacy+SOL
2026-03-03T01:11  remoteimage connect + VirtualMedia mount    ← 試行4: VCD 再ブート
2026-03-03T01:16  BootOnce=1, VCD-DVD, powercycle
2026-03-03T02:16  jobqueue create (RedirAfterBoot 変更)       ← 試行5: 静的IP preseed
2026-03-03T02:24  BootOnce=1, VCD-DVD, powercycle
2026-03-03T02:44  forceoff                                    ← 試行5失敗
2026-03-03T02:46  ISO リマスター (91秒)                       ← 試行6: 最小パッケージ
2026-03-03T02:47  umount → mount → BootOnce → power on
2026-03-03T03:03  forceoff                                    ← 試行6失敗
2026-03-03T03:06  umount → mount → BootOnce → power on       ← 試行7: network-console
2026-03-03T03:46  forceoff                                    ← 試行7失敗 (partman デッドロック)
2026-03-03T03:49  umount → mount → BootOnce → power on       ← 試行8: 最終試行
2026-03-03T04:35  forceoff                                    ← 試行8: 60分タイムアウト
```

### 各試行の概要

| 試行 | 時刻 (UTC) | preseed 主要変更 | 結果 | 所要時間 |
|------|-----------|-----------------|------|---------|
| 1 | 03/02 17:55 | オリジナル (UEFI, DHCP, mirror) | UEFI インストール完了→ブート不可 | ~4h |
| 2 | 03/02 22:37 | — (HDD ブートテスト) | Legacy MBR なし→ブート不可 | ~30min |
| 3 | 03/03 00:10 | — (BIOS 変更のみ) | SOL で PXE 失敗確認 | ~30min |
| 4 | 03/03 01:16 | オリジナル (SerialComm 修正済) | DHCP ハング→タイムアウト | ~60min |
| 5 | 03/03 02:24 | 静的 IP + no mirror + no NTP | "Connection refused" まで到達→タイムアウト | ~20min |
| 6 | 03/03 02:47 | デュアルシリアル + 最小パッケージ | SOL 出力なし→タイムアウト | ~15min |
| 7 | 03/03 03:06 | network-console 追加 | LVM 残骸発見→partman デッドロック | ~40min |
| 8 | 03/03 03:49 | network-console 除去 + 追加 debconf | 60分タイムアウト→原因不明 | ~45min |

## 失敗原因の分類と分析

### A. UEFI/Legacy BIOS 互換性問題（試行 1-3: ブート不可）

**症状**: UEFI モードでインストールは完了したが、HDD からブートできない。

**原因**: PERC H710 on R320 BIOS 2.3.3 が UEFI ブートを実質的にサポートしていない。

Redfish API で取得した BootOptions は全エントリが以下の状態だった:

```
Description = "Legacy Boot option"
UefiDevicePath = null
```

UEFI インストーラが GPT パーティションテーブルと EFI System Partition を作成したが、BIOS の UEFI ブートマネージャは PERC H710 上の UEFI ブートローダを検出できなかった。Dell ロゴとスピナーが無限に表示される状態となった。

**副次的問題**: `ErrPrompt=Enabled` により、PERC H710 のバッテリー失効警告で F1 プロンプトが表示されていた。capconsole は 400x300 の 5色グレースケールサムネイルしか返さないため、F1 プロンプトの存在を視認できなかった。

**対策**: BootMode を Legacy (Bios) に変更し、ErrPrompt を Disabled に設定。

### B. ネットワーク設定問題（試行 4-5: DHCP ハング）

**症状**: インストーラのカーネルはブートするが、その後の進行が停止。

**原因**: preseed-generated.cfg は `netcfg/choose_interface select auto` のみ指定し、DHCP を前提としていた。管理 NW (10.10.10.0/8) に DHCP サーバが存在しないため、インストーラは DHCP 応答を無限に待機した。

試行5で以下の静的 IP 設定に変更:

```
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string 10.10.10.207
d-i netcfg/get_netmask string 255.0.0.0
d-i netcfg/get_gateway string 10.10.10.1
d-i netcfg/get_nameservers string 8.8.8.8
d-i netcfg/confirm_static boolean true
```

SSH テストで `10.10.10.207` への接続が "Connection refused" を返し（"No route to host" ではない）、静的 IP が正しく設定されたことを確認。ただし別の原因でインストールは完了しなかった。

### C. シリアルコンソール問題（試行 3-6: 診断不能）

**症状**: BIOS POST 出力は SOL に表示されるが、Linux カーネルブート後は一切出力なし。

**原因と調査結果**:

| 段階 | SOL 出力 | メカニズム |
|------|---------|-----------|
| BIOS POST | あり | `SerialComm=OnConRedirCom2` で BIOS が COM2 に出力 |
| ISOLINUX | あり | BIOS INT 14h 経由でシリアル出力 |
| Linux カーネル | **なし** | 8250 ドライバが COM2 を再初期化、iDRAC SOL との互換性喪失 |

`console=ttyS0,115200n8` と `console=ttyS1,115200n8` の両方を試したが、いずれも SOL に出力されなかった。これは R320/iDRAC7 のハードウェア・ファームウェアレベルの制約と判断。

**capconsole の制約**: iDRAC7 の capconsole API は 400x300 ピクセル・5色グレースケールの PNG サムネイル（2-28KB）を返す。Linux カーネルがフレームバッファモードに切り替わった後は、同一画像を返し続ける（stale 化）。preseed インストーラの状態を capconsole で確認することは不可能だった。

**結論**: R320 では preseed インストール中のリアルタイム診断手段が事実上存在しない。

### D. LVM 残骸による auto-partitioning 失敗（試行 7: "No root file system"）

**症状**: network-console 経由で SSH 接続後、"No root file system is defined" エラー。

**原因**: 試行1の UEFI インストールが `/dev/sdd5`（878GB の VD のひとつ）に LVM を作成していた。preseed は `/dev/sda` を対象としていたが:

1. `partman-lvm/device_remove_lvm boolean true` は **対象ディスク (`/dev/sda`) 上の LVM のみ** を削除する
2. `/dev/sdd5` の VG 名 `ayase-web-service-7-vg` が残存
3. preseed が同名の VG を `/dev/sda` に作成しようとして名前衝突

syslog で確認した状態:

```
PV /dev/sdd5 VG ayase-web-service-7-vg lvm2 [836.79 GiB / 0 free]
  LV root     836GB
  LV swap_1    44GB
```

**注目点**: UEFI インストーラは preseed で `partman-auto/disk string /dev/sda` を指定していたにもかかわらず `/dev/sdd` にインストールした。PERC H710 の 7VD 環境でのディスク選択が予測不能であることを示している。

**SSH 経由の手動クリーンアップ**:

```sh
lvremove -f /dev/ayase-web-service-7-vg/root
lvremove -f /dev/ayase-web-service-7-vg/swap_1
vgremove -f ayase-web-service-7-vg
pvremove -f /dev/sdd5
dd if=/dev/zero of=/dev/sda bs=1M count=1  # sdb-sdg も同様
```

### E. network-console のデッドロック（試行 7: partman 競合）

**症状**: LVM クリーンアップ後に partman を再実行しても "No root file system" が再発。

**原因**: Debian installer の network-console は、SSH 接続ごとに新しい GNU Screen セッションと新しいインストーラインスタンスを生成する設計になっている。

試行7では4回の SSH 接続により以下の状態が発生:

```
4 screen sessions (PIDs 2543, 6674, 7701, 7853)
4+ partman instances → 共有 parted_server FIFO を奪い合い
50lvm, 50biosgrub init.d scripts が interleave
```

最初のインストーラインスタンスは LVM を正常に作成していた:

```
Physical volume "/dev/sda5" successfully created
Volume group "ayase-web-service-7-vg" successfully created
Logical volume "root" created
Logical volume "swap_1" created
```

しかし2番目の partman インスタンスが `/dev/sdb` にパーティションを作成し、parted_server FIFO の入出力が混在してデッドロックした。

**教訓**: network-console は **単一 SSH 接続のみ** で使用可能。切断・再接続すると別のインストーラインスタンスが起動し、共有リソースの競合でデッドロックする。

### F. ISO リマスター失敗（3回）

**症状**: `scripts/remaster-debian-iso.sh` が exit code 100 で失敗。

**原因**: Docker コンテナ内の `apt-get install grub-efi-amd64-bin` が Docker Hub / Debian ミラーのネットワーク障害で失敗（Option B: grub-mkstandalone による EFI パッチ）。

**回避策**: Legacy BIOS モードでは EFI パッチが不要なため、EFI パッチをスキップする簡略化スクリプト `tmp/01cb734d/remaster_debug.sh` を作成。initrd への preseed 注入と isolinux/grub.cfg の書き換えのみ実行。

### G. 最終試行の未解明失敗（試行 8: 60分タイムアウト）

**preseed の最終変更内容**:

| 追加/変更 | 目的 |
|----------|------|
| network-console 全行削除 | デッドロック回避 |
| `apt-setup/no_mirror boolean true` | ミラー設定スキップ |
| `apt-setup/services-select multiselect` (空) | セキュリティ更新スキップ |
| `partman-auto-lvm/new_vg_name string ayase-web-service-7-vg` | VG 名明示 |
| `base-installer/install-recommends boolean false` | 推奨パッケージ抑制 |
| `user-setup/encrypt-home boolean false` | debconf 質問抑制 |
| `pkgsel/update-policy select none` | 自動更新抑制 |
| `popularity-contest/participate boolean false` | debconf 質問抑制 |

**結果**: `wait_poweroff_60m.sh`（40秒間隔×90回ポーリング）が60分タイムアウト。サーバは電源 ON のまま。

**推定原因**（診断手段なし、いずれも推測）:

1. preseed で網羅されていない debconf 質問が対話的入力を待機
2. PERC H710 の 7VD 環境で `partman-auto` が `/dev/sda` 以外のディスクも処理しようとして失敗
3. `apt-setup/cdrom/set-first boolean true` 関連の CD-ROM ソース設定で対話プロンプト
4. grub-installer が PERC H710 RAID 上の `/dev/sda` への GRUB インストールに失敗
5. 試行7で手動実行した `dd if=/dev/zero` が不完全で、パーティション情報が一部残存

## 根本原因の考察

### 主因: 診断手段の不足

R320/iDRAC7 環境では preseed インストール中のリアルタイム診断が事実上不可能:

| 手段 | 状態 | 問題 |
|------|------|------|
| SOL (シリアルコンソール) | 不可 | Linux カーネル出力が表示されない（ハードウェア制約） |
| capconsole (KVM サムネイル) | 不可 | フレームバッファ切替後に stale 化 |
| network-console (SSH) | 制限付き | SSH 接続ごとに新インスタンス、デッドロック誘発 |
| 物理コンソール | 未使用 | ラック設置のためアクセス困難 |

4-6号機 (Supermicro) では IPMI SOL が Linux カーネル出力を正常に表示し、preseed の問題を即座に特定できた。R320 ではこの診断パスが存在しないため、preseed の問題特定に試行ごとに30-60分の待機が必要となり、効率が著しく低下した。

### 副因: インクリメンタル改善の非効率性

preseed の修正→ISO リマスター→VirtualMedia マウント→ブート→結果待機の1サイクルに最低30分を要する。診断なしの状態で各試行の失敗原因を推測し、1つずつ修正を重ねるアプローチは、多重障害の環境では収束しなかった。

### 構造的問題: PERC H710 の 7VD

PERC H710 が7つの仮想ディスクを提示する環境は、preseed の `partman-auto` と相性が悪い:

- `/dev/sda` を指定しても、インストーラが異なるディスクにインストールする可能性
- `partman-lvm/device_remove_lvm` が対象ディスク以外の LVM を処理しない
- 7つのデバイス (`/dev/sda`-`/dev/sdg`) + Virtual Floppy (`/dev/sdh`) + DVD (`sr0`, `sr1`) が存在する環境での partman の挙動が予測困難

## 作成されたスクリプト/ツール一覧

`tmp/01cb734d/` 内の約90ファイルを分類:

| カテゴリ | ファイル数 | 主要ファイル |
|---------|----------|------------|
| KVM スクリーンショット (PNG) | 39 | `kvm_fresh.png`, `kvm_reinstall_*.png`, `kvm_boot*.png` 等 |
| SOL/シリアル診断 | 7 | `sol_capture.py`, `sol_interact.py`, `sol_long.py`, `sol_check.sh` 等 |
| SSH インストーラ操作 | 8 | `ssh_installer.py`, `ssh_retry_partman.py`, `ssh_screen_attach.py` 等 |
| iDRAC Web/API 診断 | 6 | `debug_idrac_endpoints.py`, `idrac_playwright_screenshot.py` 等 |
| サーバ検出/状態確認 | 5 | `find_r320.sh`, `check_boot_state.sh`, `system_state.json` 等 |
| ISO リマスター | 2 | `remaster_debug.sh`, `test_docker.sh` |
| ブート監視/待機 | 4 | `wait_poweroff.sh`, `wait_poweroff_60m.sh`, `boot_monitor.py` 等 |
| Playwright (iDRAC Web) | 4 | `kvm_fresh.py`, `test_preview_and_capture.py` 等 |
| インストーラ自動化 | 1 | `auto_start_installer.py` |
| JSON データ | 3 | `boot_options.json`, `boot_hdd.json`, `boot_unknown.json` |

## 教訓と推奨事項

### DELL R320 + PERC H710 固有の制約

1. **UEFI ブート非対応**: PERC H710 on R320 BIOS 2.3.3 は Legacy Boot のみ。preseed は MBR/BIOS パーティショニングを使用すること
2. **SOL で Linux 出力が表示されない**: iDRAC7 SOL は BIOS POST と ISOLINUX まで。Linux カーネル以降のリアルタイム診断は不可
3. **7VD 環境の preseed リスク**: `partman-auto/disk` の指定が期待通りに動作しない可能性がある。不要な VD を PERC で事前に削除すべき
4. **capconsole の限界**: 400x300・5色のサムネイルはテキスト読み取りに不十分。フレームバッファ後は stale 化

### preseed デバッグのベストプラクティス

1. **expert mode を使う**: `priority=low` で全質問を表示し、preseed が網羅できていない項目を特定する
2. **network-console は単一接続**: 切断・再接続せず、同一 SSH セッションを維持する。タイムアウト防止に `ServerAliveInterval` を設定
3. **VD を最小化**: PERC H710 の VD を1つに統合してから preseed を実行し、パーティショニングの不確実性を排除
4. **手動パーティション preseed**: `partman-auto` の代わりに `partman/expert_recipe` で明示的なパーティションレイアウトを指定

### 次回試行への提案

| 提案 | 期待効果 |
|------|---------|
| **PERC VD を1つに統合** | `/dev/sda` のみの環境で partman の挙動を単純化 |
| **expert mode (priority=low)** | 全 debconf 質問を表示し、未回答の質問を特定 |
| **手動パーティション (preseed recipe)** | `partman-auto` の不確実な動作を回避 |
| **PXE ブート** | VirtualMedia の代わりに PXE で高速なイテレーション |
| **物理コンソールでの初回テスト** | SOL/capconsole の制約を回避し、まず手動インストールで動作確認 |
| **`partman-auto/method string regular`** | LVM を使わずシンプルなパーティショニングで成功率を上げる |
| **preseed/early_command で全ディスク LVM 消去** | `vgremove -f` + `pvremove -f` で全 VD の LVM 残骸を事前消去 |

## 参考資料

### 過去のレポート

- [7号機 iDRAC SSH セットアップ](2026-03-02_052246_dell_r320_idrac_setup.md) — iDRAC 初期設定
- [7号機 iDRAC7 FW アップデート](2026-03-02_143000_idrac7_firmware_upgrade.md) — FW 1.57→2.65 段階アップグレード

### 設定ファイル

- `config/server7.yml` — サーバ設定
- `preseed/preseed-server7.cfg` — 最終版 preseed（試行8で使用）
- `preseed/preseed-generated.cfg` — オリジナル preseed テンプレート
- `scripts/remaster-debian-iso.sh` — 本番リマスタースクリプト

### oplog

- `log/oplog.log` L324-380: 全電源操作・VirtualMedia 操作の時系列記録

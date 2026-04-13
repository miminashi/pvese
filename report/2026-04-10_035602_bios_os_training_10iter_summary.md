# BIOS リセット + OS セットアップ 10回反復トレーニング 最終サマリ

- **実施期間**: 2026年4月4日 - 2026年4月10日
- **対象サーバ**: 4-9号機（各10回、計60回）

## 添付ファイル

- [実装プラン](attachment/2026-04-10_035602_bios_os_training_10iter_summary/plan.md)

## 前提・目的

BIOS 工場出荷値リセット → ブート順序設定 → OS セットアップ（Debian 13 + Proxmox VE 9）の一連の手順を各サーバで10回繰り返し、`bios-setup`, `os-setup`, `idrac7` スキルの信頼性を向上させる。各反復で得られた知見をスキルとスクリプトに反映し、自動化の成熟度を高める。

## 環境情報

| サーバ | ハードウェア | BMC | BIOS リセットキー | ブートモード |
|--------|------------|-----|------------------|------------|
| 4号機 | Supermicro X11DPU | IPMI/KVM | F3 (Optimized Defaults) + F4 (Save) | UEFI (DUAL) |
| 5号機 | Supermicro X11DPU | IPMI/KVM | F3 + F4 | UEFI (DUAL) |
| 6号機 | Supermicro X11DPU | IPMI/KVM | F3 + F4 | UEFI (DUAL) |
| 7号機 | Dell PowerEdge R320 | iDRAC7/VNC | F3 (Load Defaults) | UEFI (racadm復旧必要) |
| 8号機 | Dell PowerEdge R320 | iDRAC7/VNC | F3 | UEFI (racadm復旧必要) |
| 9号機 | Dell PowerEdge R320 | iDRAC7/VNC | F3 | UEFI (racadm復旧必要) |

- OS: Debian 13.4 (Trixie) + Proxmox VE 9.1.7
- カーネル: 6.17.13-2-pve

## 全体結果

| サーバ | 成功 | 失敗 | 成功率 | 失敗原因 |
|--------|------|------|--------|---------|
| 4号機 | 10 | 0 | 100% | - |
| 5号機 | 10 | 0 | 100% | - |
| 6号機 | 8 | 2 | 80% | DIMM P2-DIMMA1 故障 (iter3, iter6) |
| 7号機 | 10 | 0 | 100% | - |
| 8号機 | 6 | 4 | 60% | racadm BootMode変更後 VirtualMedia ブート不能 (iter7-9失敗, iter10未実行) |
| 9号機 | 10 | 0 | 100% | - |
| **合計** | **54** | **6** | **90%** | |

## 発見した問題と対策

### 問題 1: Dell R320 racadm BootMode 変更で VirtualMedia ブート永続的破壊 (重大)
- **発生**: 8号機 iter7-9
- **症状**: `racadm set BIOS.BiosBootSettings.BootMode Uefi` 実行後、VirtualMedia 起動時に EFI ドライバ初期化ループまたは LC「Collecting System Inventory」で永久停止
- **原因**: BootMode 変更が LC の再インベントリを誘発し、VirtualMedia ドライバとの相互作用で EFI がハング
- **対策**: Dell R320 では racadm による BootMode 変更を避ける。VNC BIOS UI (F3) のみで BIOS リセットを行い、BootMode は手動変更しない
- **影響**: iter1-6（VNC F3 のみ）では正常。racadm BootMode 変更を導入した iter7 以降で発生

### 問題 2: 6号機 DIMM P2-DIMMA1 Uncorrectable Memory エラー
- **発生**: 6号機 iter3, iter6（約25%の確率）
- **症状**: `EFI stub: ERROR: Failed to decompress kernel` でカーネル展開失敗
- **原因**: 故障 DIMM の物理的欠陥。メモリ割り当てが故障領域にヒットした場合に発生
- **対策**: BIOS PPR (Hard PPR) 有効化で改善（iter2 の PPR 修復後は iter4,5,7,8,9,10 で成功）。根本解決には DIMM 物理交換が必要
- **検証**: PPR 修復後の成功率 75% (6/8) → 物理交換なしでの限界

### 問題 3: iDRAC7 SOL デッドロック (console=ttyS0 + シリアルヒストリバッファ)
- **発生**: 7号機 iter7（10回のサブ試行で判明）
- **症状**: インストーラが極端に低速化またはハング
- **原因**: `console=ttyS0,115200n8` + iDRAC7 の 8KB シリアルヒストリバッファ再送がハードウェアフロー制御デッドロックを誘発
- **対策**: `remaster-debian-iso.sh` からカーネル `console=ttyS*` を削除、iDRAC `cfgSerialHistorySize=0` に設定
- **検証**: 修正後は再発なし

### 問題 4: Supermicro ATEN Virtual CDROM が BootOptions に出ない
- **発生**: 4-6号機（BIOS F3 後に毎回）
- **症状**: Redfish `find-boot-entry` が ATEN Virtual CDROM を検出できない
- **対策**: 既存 OS から `efibootmgr -n 0005` でフォールバック（Boot0005 は全反復で安定）。または BIOS Boot タブで Boot Option #1 を UEFI CD/DVD に手動設定
- **検証**: フォールバック手順で全反復成功

### 問題 5: LINBIT GPG キー URL 404
- **発生**: 全サーバ（初回インストール時）
- **症状**: `https://packages.linbit.com/package-signing-pubkey.gpg` が HTTP 404
- **対策**: `pve-setup-remote.sh` に keyserver.ubuntu.com フォールバック追加。事前に `linbit-keyring.gpg` を SCP 配置が最も確実
- **検証**: フォールバック実装後は再発なし

### 問題 6: POST 0x92 スタック (4号機固有)
- **発生**: 4号機（約30-40%の確率）
- **症状**: PCI bus initialization で POST がハング
- **対策**: ForceOff → 20秒待機 → Power On（最大3-4回必要）
- **検証**: リトライで毎回回復

### 問題 7: Dell R320 PVE リブート後デフォルトゲートウェイリセット
- **発生**: 7-9号機（PVE インストール後の毎リブート）
- **症状**: デフォルトゲートウェイが 10.10.10.1（インターネット不可）に戻る
- **対策**: リブート後に `pre-pve-setup.sh` 再実行で 192.168.39.1 に修正
- **検証**: ブリッジ設定（Phase 8）完了後は vmbr1 DHCP がデフォルトルート提供

### 問題 8: ssh/config IdentityFile 未設定
- **発生**: 4-9号機（初回セットアップ時）
- **症状**: SSH 認証失敗（プロジェクト鍵ではなくグローバル鍵が使用される）
- **対策**: ssh/config の全 pve4-9 エントリに `IdentityFile ssh/id_ed25519` + `IdentitiesOnly yes` 追加
- **検証**: 修正後は再発なし

### 問題 9: DRBD dkms ビルドに proxmox-headers 必要
- **発生**: 7-9号機
- **症状**: `drbd-dkms` が「added」のまま「installed」にならない
- **対策**: `pve-setup-remote.sh` に `proxmox-headers-${pve_kernel}` + `gcc` + `dkms autoinstall` 追加
- **検証**: 修正後は自動ビルド成功

### 問題 10: Dell R320 LC インストールループ
- **発生**: 9号機
- **症状**: boot-once VCD-DVD 後、LC がインストールメディアを毎回再検索してインストーラが繰り返し起動
- **対策**: インストール開始10-15分後に VirtualMedia を早めに umount
- **検証**: umount タイミング調整で対処可能

## スクリプト修正の総括

### 変更統計
- 20ファイル変更、495行追加、107行削除

### 主要な修正

| ファイル | 修正内容 |
|---------|---------|
| `scripts/pve-setup-remote.sh` | gcc + proxmox-headers + enterprise repo 削除 + LINBIT keyserver フォールバック + dkms autoinstall |
| `scripts/remaster-debian-iso.sh` | console=ttyS* 削除、preseed initrd 注入、embed.cfg ISO9660 検索ロジック、GRUB timeout=0 |
| `ssh/config` | pve4-9 全 IdentityFile + IdentitiesOnly、pve7-9 IP エイリアス |
| `scripts/bmc-kvm-interact.py` | 引数形式改善 |
| `.claude/skills/os-setup/SKILL.md` | SSH 鍵パス修正、Dell BootMode 注意、base64 エンコード方式、LINBIT GPG 対策 |
| `.claude/skills/bios-setup/SKILL.md` | F3/F4 手順詳細化 |
| `.claude/skills/idrac7/SKILL.md` | F3 BIOS リセット、BootMode UEFI 復旧、SOL 設定 |
| `preseed/preseed.cfg.template` | preseed 改善 |
| `preseed/preseed-server{7,8,9}.cfg` | Dell 固有 preseed 調整 |

## 主要な改善点（上位5件）

1. **iDRAC7 SOL デッドロック解消**: カーネル console=ttyS0 削除 + cfgSerialHistorySize=0 で Dell サーバのインストーラハングを根絶
2. **LINBIT GPG キーフォールバック**: pve-setup-remote.sh に keyserver フォールバック追加で LINSTOR インストール失敗を自動回復
3. **SSH 認証の一貫性確保**: ssh/config に全サーバの IdentityFile を設定し、プロジェクト鍵の一貫使用を保証
4. **DRBD dkms 自動ビルド**: proxmox-headers + gcc の自動インストールと dkms autoinstall 追加
5. **preseed initrd 注入**: ISO ルートの preseed に加え initrd 内に注入し、VirtualMedia 環境での preseed 読み込み信頼性向上

## レポート未記載の追加知見

### preseed late_command による Phase 6 自動化 (5号機 iter10)
- preseed の `late_command` が SSH 鍵配置、PermitRootLogin、sudoers、静的 IP 設定を完了する
- late_command が正常動作する場合、Phase 6 の SOL/KVM 手動設定は**不要**
- 4号機では late_command の動作が不安定だったため手動対応が多かったが、5号機では安定

### BIOS F3 後のブート順序 (5号機 iter10)
- F3 リセット後 Boot Option #1 が PXE になる → PXE タイムアウト待ち（約5分のロス）
- Boot Option #1 を UEFI CD/DVD (index 11) に BIOS GUI で設定すると PXE 待ちを回避
- VirtualMedia アンマウント後は UEFI CD/DVD が空でも NVMe にフォールスルーするため、Boot Option のリセットは不要

### NVMe dd wipe による EFI パーティション問題の解消 (5号機 iter9)
- BIOS F3 後のインストールで既存パーティションテーブルが残り、EFI パーティション mount failure ループが発生
- preseed `early_command` で `dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=100` を実行することで解消

### SOL が使えない場合の Phase 6 代替手段 (5号機)
- `console=ttyS*` 削除済み ISO でインストールすると、OS 起動後に SOL が使えない
- KVM `type` サブコマンドで直接入力するが、base64 文字列の `+`, `/`, `=` が化ける
- heredoc (`cat > file << 'EOF'`) 方式で SSH 公開鍵を直接書き込むのが確実

### ssh-wait.sh と IP アドレス直接指定の不整合
- `ssh-wait.sh` は IP アドレス直接指定 (`10.10.10.20X`) を使うが、ssh/config の IdentityFile はホストエイリアス (`pveN`) にのみ設定
- pve7-9 は `Host pve7 10.10.10.207` と IP エイリアスを追加済みだが、pve4-6 は未追加
- ssh-wait.sh の接続確認は `pveN` エイリアスを使うべき

### Dell R320 PERC H710 GRUB ディスク番号問題 (9号機 iter7)
- PERC H710 Mini の RAID VD は GRUB から `hd2` として認識される（`hd0` ではない）
- 複数回インストールにより GRUB 設定が破損し、rescue プロンプトに落ちる
- `set root=(hd2,gpt2)` + `linux /vmlinuz root=/dev/sda2` で手動ブート可能

### Dell R320 UefiBootSeq VirtualMedia 残存問題 (9号機 iter7)
- インストール完了後に UefiBootSeq に `Optical.iDRACVirtual.1-1` が残り、毎回インストーラが再起動するループ
- 対策: インストール完了検知後に即座に VirtualMedia umount + UefiBootSeq を RAID-first に変更

### 7号機 iter9: console=ttyS0 削除の弊害
- SOL 診断が完全に不可能になり、インストーラが7.5時間ハングした際に原因特定が困難
- VNC の `^[[B^[[A` エスケープシーケンスは d-i プログレスバーのアニメーションで、実際の進行とは無関係
- **推奨**: `console=ttyS0` は削除せず、iDRAC の `cfgSerialHistorySize=0` のみで SOL デッドロックを防ぐ

### 8号機 VirtualMedia 復旧の残オプション (iter9)
- racadm BootMode 変更による VirtualMedia 破壊は、4回のクリーンブートサイクルでも回復しない
- 残る復旧手段: (1) iDRAC Web UI からの完全 BIOS リセット、(2) BIOS ファームウェア更新、(3) 物理 USB インストール

## 残存課題

| 課題 | 影響 | 対策案 |
|------|------|--------|
| 6号機 DIMM P2-DIMMA1 | 25%の確率でカーネル展開失敗 | 物理 DIMM 交換 |
| 8号機 racadm BootMode 破壊 | VirtualMedia ブート不能 | BIOS ファームウェアリセットまたは更新 |
| Dell R320 LC インストールループ | インストーラ重複起動 | VirtualMedia 早期 umount の自動化 |
| POST 0x92 スタック (4号機) | リトライ必要 | ハードウェア固有、回避不可 |
| corosync 3.1.10-pve2 404 | 散発的 apt 失敗 | `--fix-missing` で対処、PVE リポジトリ側の問題 |

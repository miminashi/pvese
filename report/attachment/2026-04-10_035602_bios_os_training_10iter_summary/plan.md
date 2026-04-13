# BIOS 工場出荷値リセット + OS セットアップ 10回反復トレーニング

## Context

BIOS リセット → ブート順序設定 → OS セットアップの一連の手順を各サーバで10回繰り返し、`bios-setup`, `os-setup`, `idrac7` スキルの信頼性を向上させる。各反復で得られた知見をスキルに反映し、後の反復で問題が減ることを目指す。

## 方針（修正版: 全6台並列）

- **サーバ単位**: 1台につき10回反復を完了
- **全6台並列**: 6台すべてのエージェントを同時起動（pve-lock で状態変更は自動直列化）
- **サブエージェント**: 1サーバ1エージェント（sonnet モデル）、各エージェントが全反復を一括実行
- **Dell BIOS リセット**: VNC BIOS UI で **F3** (Load Optimized Defaults)

## 進捗（反復1-9で確立済み）

| サーバ | 完了反復 | 残り | 状態 |
|--------|---------|------|------|
| 4号機 (Supermicro) | 9/10 | 1 | バックグラウンド実行中 |
| 5号機 (Supermicro) | 0/10 | 10 | バックグラウンド実行中 |
| 6号機 (Supermicro) | 0/10 | 10 | バックグラウンド実行中 |
| 7号機 (Dell) | 8/10 | 2 | バックグラウンド実行中 |
| 8号機 (Dell) | 0/10 | 10 | バックグラウンド実行中 |
| 9号機 (Dell) | 0/10 | 10 | バックグラウンド実行中 |

## 各反復の手順（1サーバ1回分）

### Step 1: BIOS 工場出荷値リセット

**Supermicro (4-6号機)**:
1. `pve-lock.sh wait` で ForceOff → 15秒待機 → Power On
2. KVM 接続 (`bmc-kvm-interact.py --bmc-ip X --bmc-user claude --bmc-pass Claude123`) + Delete 60回 (--wait 1000 --no-click) で BIOS Setup 入る
3. F3 (Load Optimized Defaults) → Enter (Yes) で確定
4. F4 (Save & Exit) → Enter (Yes) で保存・再起動
5. POST 完了を待つ（0x92 スタック時は ForceOff → 20秒 → Power On リトライ、3-4回必要な場合あり）

**Dell (7-9号機)**:
1. `pve-lock.sh wait` で ForceOff → 15秒待機 → Power On
2. 40秒待機後、VNC 接続 (`idrac-kvm-interact.py --bmc-ip X --vnc-pass Claude1`) + F2 30回 (--wait 2000) で BIOS Setup 入る
3. **F3** (Load Optimized Defaults) → Enter で確定 (**注意**: Dell R320 は F9 ではなく F3)
4. Escape → Save Changes and Exit → Enter で保存・再起動
5. POST + LC Collecting Inventory 完了を待つ（3-5分）
6. **BootMode UEFI 復旧（必須）**: F3 で BootMode が Legacy に戻るため:
   ```
   ssh -F ssh/config idracN racadm set BIOS.BiosBootSettings.BootMode Uefi
   ssh -F ssh/config idracN racadm jobqueue create BIOS.Setup.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA
   ```
7. cfgSerialHistorySize=0（初回のみ、iDRAC SOL デッドロック対策）

### Step 2: ブート順序設定

**Supermicro**: BIOS F3 後 Boot Option #1 が CD/DVD に戻り、VirtualMedia マウント時に自動インストーラ起動する場合がある。ATEN Virtual CDROM が BootOptions に出ない場合は、既存 OS から `efibootmgr -n 0005` でフォールバック。

**Dell**: F3 後 BootMode を UEFI に復旧後、os-setup Phase 4 が boot-once VCD-DVD を設定する。

### Step 3: OS セットアップ

os-setup スキルの 8 フェーズパイプラインを実行:
1. `os-setup-phase.sh reset` で状態クリア
2. Phase 1 (iso-download) — ISO ダウンロード（キャッシュあり）
3. Phase 2 (preseed-generate) — preseed 生成
4. Phase 3 (iso-remaster) — ISO リマスター（ハッシュ一致ならスキップ）
5. Phase 4 (bmc-mount-boot) — VirtualMedia マウント + ブート (pve-lock)
6. Phase 5 (install-monitor) — インストール監視 (pve-lock)
7. Phase 6 (post-install-config) — SSH 鍵配置、ネットワーク設定
8. Phase 7 (pve-install) — PVE インストール
9. Phase 8 (cleanup) — ブリッジ設定、IPoIB 設定、検証

### Step 4: 知見収集とスキル改善

各反復完了後にエージェントが以下を記録:
- 成功/失敗、発生した問題、リトライ回数
- 各フェーズの所要時間
- スキル改善提案

オーケストレータが findings を集約し、スキルファイルを更新してから次の反復へ。

## サブエージェントの具体的な実行手順

### 実行方式: 全6台並列バックグラウンド

1. 6つのサブエージェント（sonnet）を `run_in_background=true` で同時起動
2. 各エージェントが担当サーバの全残反復を一括実行
3. pve-lock により状態変更操作は自動直列化
4. Phase 1-3（ローカル作業）は完全並列
5. 完了通知後に findings を集約しスキル改善・レポート作成

### 各サブエージェントへの指示内容

```
サーバ X 号機の反復 1-10 を順に実行:
各反復:
1. BIOS 工場出荷値リセット
2. ブート順序確認（Supermicro: efibootmgr、Dell: BootMode Uefi復旧）
3. os-setup スキルで OS セットアップ（Phase 1-8 全実行）
4. findings を tmp/<session-id>/findings-sX-iterN.md に記録
無限リトライ禁止（5回失敗→記録して終了）
```

## 反復1-9で確立された知見

### スクリプト修正（適用済み）
- `scripts/pve-setup-remote.sh`: gcc + proxmox-headers + enterprise repo 削除 + LINBIT keyserver フォールバック + dkms autoinstall
- `scripts/remaster-debian-iso.sh`: console=ttyS* 削除（iDRAC7 SOL デッドロック対策）、preseed initrd 注入、embed.cfg ISO9660 検索ロジック
- `ssh/config`: pve4-9 全て IdentityFile + IdentitiesOnly 設定、pve7-9 に IP エイリアス追加

### サーバ固有の問題
| 問題 | サーバ | 対策 |
|------|--------|------|
| POST 0x92 スタック | 4号機（固有） | ForceOff→20s→On、3-4回必要な場合あり |
| ATEN CDROM BootOptions 不在 | 4-6号機 | efibootmgr -n 0005 フォールバック (Boot0005安定) |
| Redfish BootOptions 空 | 6号機 | BIOS GUI フォールバック |
| F3 後 BootMode Legacy | 7-9号機 | racadm set BootMode Uefi + jobqueue |
| iDRAC7 SOL デッドロック | 7-9号機 | console=ttyS0 削除 + cfgSerialHistorySize=0 |
| LINBIT GPG 404 | 全サーバ | keyserver フォールバック or 事前 SCP 配置 |
| postfix/exim4 競合 | 全サーバ | apt-get install 再実行で解決 |
| PVE リブート後 GW リセット | 7-9号機 | pre-pve-setup.sh 再実行 |

## 対象ファイル

### スキルファイル（改善対象）
- `.claude/skills/bios-setup/SKILL.md` — Supermicro BIOS 操作
- `.claude/skills/os-setup/SKILL.md` — OS セットアップパイプライン
- `.claude/skills/idrac7/SKILL.md` — Dell iDRAC7 操作

### 主要スクリプト
- `scripts/bmc-kvm-interact.py` — Supermicro KVM 操作
- `scripts/bmc-power.sh` — 電源・ブート制御
- `scripts/bmc-virtualmedia.sh` — VirtualMedia 操作
- `scripts/remaster-debian-iso.sh` — ISO リマスター
- `scripts/os-setup-phase.sh` — フェーズ追跡
- `scripts/pve-setup-remote.sh` — PVE インストール
- `scripts/pve-bridge-setup.sh` — ブリッジ設定
- `scripts/ib-setup-remote.sh` — IPoIB 設定
- `scripts/idrac-kvm-interact.py` — Dell VNC KVM 操作
- `scripts/idrac-kvm-screenshot.py` — Dell VNC スクリーンショット
- `scripts/idrac-virtualmedia.sh` — Dell VirtualMedia 操作

### 設定ファイル
- `config/server{4-9}.yml` — サーバ設定

## 検証方法

各反復完了時に以下を確認:
1. `pveversion` が正常に返る
2. SSH 接続可能
3. Web UI (port 8006) 応答あり
4. ブリッジ (vmbr0, vmbr1) が正常
5. IPoIB (IB サーバのみ) が正常
6. `os-setup-phase.sh times` で各フェーズの所要時間を記録

## レポート計画

全6台完了後に最終サマリレポート1本を作成:

- `report/<timestamp>_bios_os_training_10iter_summary.md`

構成: 全体結果テーブル（サーバ×成功率×平均時間）、発見した問題と対策一覧、スキル改善の総括、フェーズ別所要時間推移、残存課題。プランファイルを添付。

## 成果物

- 各反復の findings ファイル: `tmp/<session-id>/findings-sX-iterN.md`
- 改善済みスキルファイル（上記3ファイル）
- 中間レポート: 3本（ペアごと）
- 最終サマリレポート: 1本

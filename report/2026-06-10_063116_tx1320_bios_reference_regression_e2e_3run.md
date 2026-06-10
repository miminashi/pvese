# TX1320 BIOS リファレンス skill 修正 リグレッション e2e ×3 レポート

- **実施日時**: 試行1・2 = 2026年6月7日 / 試行3 = 2026年6月10日(本レポート作成 2026年6月10日 06:31 JST)
  > 試行1・2 は前セッション(2026-06-07)で実施・記録済 (`regression-results.md`、`bios/` 各ファイルの「✅ 2026-06-07」)。
  > 試行3 を 2026-06-10 に実施し、3 試行をまとめて本レポートに集約した。
- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F / 10.254.254.9)
- **判定**: ✅ **3/3 PASS = リグレッションなし**

## 添付ファイル

- [実装プラン](attachment/2026-06-10_063116_tx1320_bios_reference_regression_e2e_3run/plan.md)

## 前提・目的

`irmc-bios-raid` スキルに TX1320 M3 (board D3373-B1x / AMI Aptio) の **全 BIOS 設定項目の網羅リファレンス**
(`bios/` サブディレクトリ + per-tab 分割ファイル)を追加し、SKILL.md frontmatter の `description` 追記 +
`reference.md` への参照リンクを行った。

- **背景**: skill のドキュメントを追加・拡張した。実行スクリプト (`scripts/` 配下) は無改変だが、
  SKILL.md / reference.md という skill の「入口」ファイルを編集したため、回帰がないことを実機で保証したい。
- **目的**: この skill 修正が既存の自動化経路 —
  **opus の BIOS HII RAID Clear + sonnet エージェントの deploy→PVE 通しセットアップ** — を壊していないことを、
  `report/2026-06-04_003431_tx1320_sonnet_e2e_10run.md` の 1 試行と**同一手順**で **3 回**反復し確認する。
- **前提条件**: skill 修正は `bios/` 新設 (ドキュメント追加) + SKILL.md frontmatter description 追記 +
  reference.md リンク追記のみ。`scripts/` 配下の実行ロジックは無改変。

## 環境情報

- **サーバ**: Fujitsu PRIMERGY TX1320 M3 / board S26361-D3373-B12 / Serial MABK035229
- **BMC**: iRMC S4 FW 9.69F (10.254.254.9) / claude index = 4 (Administrator)
- **BIOS**: AMI Aptio Setup Utility 2.18.1263 / Core Version 5.0.0.11 / `V5.0.0.11 R1.22.0 for D3373-B1x` / UEFI 2.4 PI 1.3
- **メモリ**: 24 GiB
- **RAID**: AVAGO MegaRAID `<PRAID EP400i>` (SAS3008, FW 03.25.05.10) / SAS HDD 900GB × 4 → HW RAID10 1.635 TB
- **設置**: 一時設置・クラスタ/LINSTOR 非参加 / 別拠点 (10.254.254.0/24 + 192.168.33.0/24 DHCP)
- **NIC**: eno1 = 192.168.33.x (NAT 背後・拠点外不達) / eno2 = dark-net (10.254.254.x、MAC `4c:52:62:14:de:f0`、deploy ごと IP 変動)
- **OS install 経路**: iPXE-on-CD (VirtualMedia で `ipxe-tx1320.iso` 起動 → DHCP → HTTP kernel/initrd → preseed → storcli RAID10)
- **install 結果**: Debian 13 + Proxmox VE 9.2.3 + HW RAID10 (LVM)

## リグレッション結果サマリ

| 試行 | 実施日 | BIOS Clear | deploy→PVE | PVE | services | web UI | RAID10 | install retry(#15) | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 2026-06-07 | ✅ 成功 | ✅ sonnet 自律 | 9.2.3 | all active | 200 | Optl 1.635TB | 1 | **PASS** |
| 2 | 2026-06-07 | ✅ 成功 | ✅ sonnet 自律 | 9.2.3 | all active | 200 | Optl 1.635TB | 0 | **PASS** |
| 3 | 2026-06-10 | ✅ 成功 | ✅ sonnet 自律 | 9.2.3 | all active | 200 | Optl 1.635TB | 0 | **PASS** |

**結論**: 3/3 PASS。skill 修正 (ドキュメント追加のみ) は既存自動化経路に一切影響しないことを実機 e2e で確認した。

### BIOS Clear の size 指紋 (3 試行とも一致)

opus の BIOS HII RAID Clear は KVM canvas の PNG サイズを「画面指紋」として検証しながら進む。3 試行とも同一:

| 画面 | size 指紋 | 確認内容 |
|---|---|---|
| Advanced タブ着地後 AVAGO 行 | `18051` (caret_y=393) | ヘルプ "Manage RAID Controller Configurations." |
| Clear Configuration 行 | `10135` (caret_y=83) | ヘルプ "Deletes all existing configurations on the RAID controller." |
| commit 後 | `9462` | "The operation has been performed successfully." |

ナビ経路: `irmc-kvm-recover.sh` で BIOS Main 着地 → KVM server.py READY → Main 確認 → ArrowRight で Advanced →
`navy 393 caret` で AVAGO まで降下 → Enter×3 で Configuration Management → ArrowDown で Clear Configuration →
modal commit (Enter → Confirm Yes wrap) → "operation performed successfully"。

### 各試行の詳細

**試行1 (2026-06-07)**: BIOS Clear navy 393 → AVAGO 着地 (presses=14, size=18051)、modal commit 1 ファイルで成功。
deploy→PVE は sonnet 自律、最終 eno2 IP .16、#15 を 1 回踏み ForceOff+再 deploy で復旧 (既知挙動)、~100min。
新規ブロッカーなし。副次的に、BIOS Clear 中の OEM screenshot で Main タブ + Advanced 全サブメニュー一覧
(設定系 13 + iSCSI + AVAGO + LSI SW RAID + Intel I210 ×2 + Driver Health = 19 エントリ) の存在を確認し
`bios/main.md` / `bios/advanced.md` に反映 (KVM 確認 ✅ 2026-06-07)。なお各設定の実機存在確認(全タブ巡回)は
2026-06-10 に別途実施した([KVM 全タブ実機確認レポート](2026-06-10_173934_tx1320_bios_reference_kvm_alltabs_verification.md))。

**試行2 (2026-06-07)**: 検証済みレシピで BIOS Clear 成功 (avago=18051 / clearrow=10135 / aftercommit=9462)。
deploy→PVE sonnet 自律、最終 eno2 IP .16、#15 0 回 (netcfg stuck なし)。新規ブロッカーなし。

**試行3 (2026-06-10)**: 試行2 と同一レシピで BIOS Clear 成功。deploy→PVE sonnet 自律、install 本体 ~12.1min、
deploy→SSH 到達 ~20min。最終 eno2 IP は .4 → 最終 reboot 後 .16 に変動するが `tx1320-pve-setup.sh` が
eno2 MAC rediscovery で自動追跡。#15 0 回。検証: pve-manager/9.2.3 (kernel 7.0.6-2-pve) /
pveproxy・pvedaemon・pve-cluster all active / web UI HTTP 200 / `0/0 RAID10 Optl RW 1.635 TB` /
LVM (tx1320-vg root 1.6T + swap 23.9G)。DisconnectCD HTTP400・PowerOn AllowableValues 制約は想定内。
新規ブロッカーなし。

## 再現方法

各試行 (opus 統括 + 試行ごと新規 sonnet エージェント):

1. **BIOS HII RAID Clear (opus)**
   ```sh
   ./oplog.sh ./scripts/irmc-kvm-recover.sh config/training_tx1320.yml tmp/<sid>/regN/recover.jpg 175
   ```
   → BIOS Main 着地を OEM screenshot で確認 → KVM 永続サーバ起動:
   ```sh
   .venv/bin/python scripts/irmc-kvm/server.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
     --srv-dir tmp/<sid>/regN/srv --idle-timeout 3600
   ```
   → READY 後、コマンドファイル (`<srv-dir>/in/NNN.cmd`) で以下を投入し各段で size 指紋を検証:
   - `mouse 512 384` + `shot` で Main タブ確認
   - `press ArrowRight` → `navy 393 caret 25 1500` → `shot` で AVAGO 着地 (size=18051, caret_y=393)
   - `press Enter`×3 → `press ArrowDown` → `shot` で Clear Configuration 着地 (size=10135)
   - modal commit (`press Enter 3000` / `mouse 80 240` / ArrowDown+Enter wrap で Yes) → `shot` で成功確認 (size=9462)
   - `press Enter` + `quit`

2. **sonnet エージェント spawn (Agent: general-purpose, model=sonnet, background)**
   プロンプトは `.claude/skills/pxe-deploy/SKILL.md` の「🤖 sonnet エージェント自律実行 runbook」を上から実行 +
   試行番号 + anti-yield 強調 (sol-monitor は foreground・最終報告まで yield 禁止) + 報告テンプレ。
   sonnet が env export → `./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml ipxe-tx1320.iso` →
   `.venv/bin/python scripts/sol-monitor.py ...` (foreground, storcli が RAID10 作成、#15 は合計~10min 停滞で
   ForceOff→再 deploy) → `./scripts/bmc-power.sh boot-override Hdd UEFI` + on → eno2 MAC (`4c:52:62:14:de:f0`) で
   IP 特定 → `./scripts/tx1320-pve-setup.sh config/training_tx1320.yml <ip>` → 検証 を自律実行。

3. **判定**: 各試行で PVE 9.2.x + `pveproxy/pvedaemon/pve-cluster` active + web UI `https://<ip>:8006` HTTP 200 +
   `storcli64 /c0/vall show` で `RAID10 Optl 1.635TB`。3/3 成功 = リグレッションなし。

## 参照レポート

- [TX1320 通常セットアップ sonnet e2e 10run](2026-06-04_003431_tx1320_sonnet_e2e_10run.md) — 本リグレッションの手順典拠 (1 試行 ×10)
- [TX1320 BIOS 網羅リファレンス KVM 全タブ実機確認](2026-06-10_173934_tx1320_bios_reference_kvm_alltabs_verification.md) — 本 skill 修正で追加した `bios/` リファレンスの実機確認(2026-06-10、同一プラン)
- [TX1320 OS install 総括 Phase 1-19](2026-05-30_053607_tx1320_raid10_overview_phase1-19_summary.md) — install saga 索引
- [TX1320 PXE 10run robustness](2026-05-30_130726_tx1320_pxe_10run_robustness.md) — PXE 経路の堅牢性検証

## 結論

`irmc-bios-raid` スキルへの BIOS 設定リファレンス追加 (`bios/` 新設 + SKILL.md frontmatter description 追記 +
reference.md リンク追記) は**ドキュメント追加のみ**で、`scripts/` 配下の実行ロジックは無改変。実機 e2e ×3 が
**3/3 PASS** (PVE 9.2.3 active + web UI 200 + RAID10 Optl 1.635TB)、新規ブロッカーゼロ。BIOS Clear の size 指紋
(avago=18051 / clearrow=10135 / aftercommit=9462) も 3 試行とも一致。**リグレッションなしと確定**。

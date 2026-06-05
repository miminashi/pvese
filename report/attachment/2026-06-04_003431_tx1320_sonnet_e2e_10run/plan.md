# TX1320 通常セットアップの sonnet エージェント化 + 反復ハードニング (最低10・最大100試行)

## Context (なぜこの作業をするか)

`report/2026-06-03_000306_tx1320_raid_pve_e2e_3trials.md` で、training-tx1320 の
「RAID初期化 → Debian install → PVE通しセットアップ」が **iPXE-CD 経路で 3/3 再現**し、
TX1320 の標準 OS install 経路に昇格した。次の目標は **この通常セットアップ作業を sonnet
サブエージェントに自律実行させられるようにする**こと。

ユーザ決定 (本セッションで確認):
- **スコープ**: 「通常のセットアップに使われるステップ」= **ステップ2〜6 (iPXE-CD deploy →
  install監視 → disk boot → IP特定 → PVE通し)** を sonnet 化する。
- **BIOS HII KVM RAID Clear (ステップ1) は対象外**。これはトレーニング上「各試行前に念のため
  RAID をまっさらにする」前処理で、通常セットアップには含まれない → **opus (このセッション) が
  各試行前に実施**する。なお install 中の preseed `partman/early_command` で storcli が RAID10 を
  delete+create するため、RAID 再構築自体は install が毎回行う (BIOS Clear は belt-and-suspenders)。
- **運用**: opus 統括 + **試行ごとに新しい sonnet エージェント**を spawn (PXE 10-run と同方式)。
- **完了基準 (改訂)**: **sonnet 単体での自律成功を目標**にハードニングを反復する。
  - **最低 10 試行は必ず実施**する (早期に成功しても知見蓄積のため打ち切らない)。
  - **最大 100 試行を上限**とする。
  - 「成功」= sonnet が runbook 参照のみ・人間/opus 介入ゼロ (opus は BIOS Clear 前処理だけ)
    でステップ2〜6を完遂し、下記検証 (PVE 9.x / web UI 200 / RAID10 Optl) を満たすこと。
  - 10 試行以降は **sonnet 自律成功が安定して再現** (連続複数回) すれば完了とみなす。
    安定しなければ最大 100 試行まで改善を続ける。

期待成果: sonnet が skill/runbook だけを参照して deploy→PVE を自律完遂できる状態 + 全試行分の
知見が pxe-deploy skill に反映され、`report/` に検証レポートが残る。

## 設計

### A. sonnet 自律実行 runbook を新設 (中核成果物)

`.claude/skills/pxe-deploy/SKILL.md` に **新セクション**
`🤖 sonnet エージェント自律実行 runbook (通常セットアップ: deploy → PVE)` を追加する。
これが各試行で sonnet エージェントに渡す「上から順に実行する単一手順」。Step 0 (preflight) →
env export → deploy → install監視(+#15エスケープ) → disk boot → IP特定 → PVE通し → 検証 → 報告。

### B. opus オーケストレーション (最低10・最大100 試行ループ)

各試行 N で opus が: ① BIOS HII KVM RAID Clear (検証付き、サブエージェント画像分析) →
② sonnet エージェント spawn (general-purpose / model:sonnet) → ③ 報告受領 → 反省 →
runbook/SKILL.md/スクリプト改善 → ④ 反復ログ追記。

### C. 改善の反映先 (試行ごと)

`.claude/skills/pxe-deploy/SKILL.md` (主) / `scripts/tx1320-pve-setup.sh` 等 /
`config/training_tx1320.yml` / メモリ topic。

## 検証 (end-to-end)

各試行で sonnet が `pveversion`=PVE 9.x / `pveproxy・pvedaemon・pve-cluster` active /
`curl https://<ip>:8006`=HTTP 200 / RAID10 Optl 1.6TB 直読 を満たせば成功。最低 10 試行完走 +
sonnet 自律成功の安定再現で完了。

## 留意点

- ラボ環境のため状態変更操作のユーザ確認不要。状態変更は `./oplog.sh` 経由。
- BIOS Clear は latency 依存で脆弱 → 各試行で shot 検証 + 失敗時 recover。
- 完遂判定は SOL の PowerState Off を正典 (sol-monitor rc=0)。手動 ForceOff は install 完遂前に撃たない。
- コミットはユーザ確認後に一括。`git push` はしない。

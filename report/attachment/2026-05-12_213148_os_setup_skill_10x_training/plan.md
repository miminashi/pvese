# Plan: OS Setup スキル 10 回トレーニング 総合レポート作成

## Context

2026-05-12 04:32 〜 21:30 JST に実施した「14号機・15号機の OS 完全リセット + 再 install を各 10 回並列で実行」トレーニングの結果が `report/training/` に分散している (31 ファイル: 20 trial レポート + 10 round summary + final-summary)。
REPORT.md の規約に従い、`report/` 直下に 総合レポートを 1 本作成し、個々の round/trial レポートは添付として `report/attachment/<basename>/` 配下にまとめ直す。総合レポートからは相対パスでリンクする。

なお、これまでの trainings は既に完了し、20/20 trial 成功・skill に累計 30 件の改善が反映済み。残作業はレポート整理のみ。

## 修正対象 / 新規作成

### 新規作成
- `report/2026-05-12_213148_os_setup_skill_10x_training.md` (総合レポート本体)
- `report/attachment/2026-05-12_213148_os_setup_skill_10x_training/` (添付ディレクトリ)

### ファイル移動 (`report/training/` → 添付ディレクトリ)
- `plan.md` (プランファイルを `/home/ubuntu/.claude/plans/report-2026-05-12-040320-server14-os-ins-mossy-cookie.md` から cp)
- `final-summary.md` (既存)
- `round-1-summary.md` 〜 `round-10-summary.md` (10 件)
- `trial-1-s14.md` / `trial-1-s15.md` 〜 `trial-10-s14.md` / `trial-10-s15.md` (20 件)

合計 32 件を attachment ディレクトリに置く。

### 削除候補
- `report/training/` ディレクトリ (中身が attachment に移動した後で空になるので削除)

## 総合レポート構成

REPORT.md テンプレートに沿う:

```
# OS Setup スキル 10 回トレーニング 総合レポート

- **実施日時**: 2026年5月12日 04:32 JST 〜 2026年5月12日 21:30 JST (約 17 時間)
- **対象**: 14号機 (10.10.10.214) + 15号機 (10.10.10.215)
- **機種**: Dell PowerEdge R430 + iDRAC8 + PERC H730/H730P Mini
- **関連 issue**: (該当なし、または #62/#63 への参照)

## 添付ファイル

- [実装プラン](attachment/.../plan.md)
- [Round 1 集計](attachment/.../round-1-summary.md) — Trial 1 / 14号機・15号機 並列
  - [Trial 1 server14](attachment/.../trial-1-s14.md)
  - [Trial 1 server15](attachment/.../trial-1-s15.md)
- ... (Round 10 まで同形式)
- [最終集計詳細](attachment/.../final-summary.md)

## 前提・目的

- 背景: `report/2026-05-12_040320_server14_os_install_retry.md` で得られた知見の skill 反映
- 目的: 反映後 skill が再現性ある OS install を実行できることを実機で検証 + 追加問題を発見し継続改善
- 前提: 14号機・15号機とも前トレーニング開始時点で PVE インストール済み (上書きされる、ユーザ承認済み)

## 環境情報

| 項目 | 14号機 | 15号機 |
|---|---|---|
| iDRAC FW | 2.63.60.61 (古い) | 2.85.85.85 |
| BIOS | 2.9.1 | 2.15.0 |
| PERC | H730P Mini FW 25.5.5 | H730 Mini FW 25.5.9 |
| OS RAID | Bay 1+6 (RAID-1, 278.88GB, LVM) | Bay 0+1 (RAID-1, 278.88GB) |
| 静的 IP | 10.10.10.214 (eno2) | 10.10.10.215 (eno2) |

## 全 trial 結果 (20 server-trial サマリ)

| Trial | s14 | s14 wall / attempt | s15 | s15 wall / attempt |
| 1 | ✓ | 47m17s / 1 | ✓ | 48m53s / 1 |
| ... 10 まで一覧 ... |

最終成功率 20/20 = 100%、1 attempt 成功 13/20 = 65%、平均 wall ~56 min

## 再現方法

各 trial で実施した手順 (skill mitigation 反映後):

1. Phase A: 完全リセット
   - PERC RAID resetconfig + SCP Export 待ち + createvd
   - state ディレクトリ初期化
   - VirtualMedia umount + boot-reset
2. Phase B: install (skill Phase 1-8)
3. Phase C: 検証 (pveversion / vmbr0 / route / Web UI / VD0 Online)
4. Phase D: 個別 trial レポート出力

詳細は各 trial レポート (添付) 参照。

## 結果と知見

### skill 改善履歴 (累計 30 件)
- Round 0 (初期) 5 件: resetconfig 注意 / racreset soft / SOL pipe / R430 vFlash / リトライポリシー
- Round 1.5 5 件: netcfg/choose_interface 等
- Round 2.5 〜 9.5 で計 20 件
(全件は final-summary 参照)

### 発見した R430 固有問題と mitigation (実機実証済)
- partman stuck (25%) → racadm racreset soft
- post-reboot route loss (90%) → pre-pve-setup 再実行
- final reboot route loss (60%) → dhclient -1 -v eno1
- LINBIT GPG empty file (35%) → ubuntu keyserver 事前配置
- dhcpcd IPv4LL (30%) → ip addr flush + dhcpcd -t 60
- initramfs dropout false-success (5%, 新規) → SOL Enter flood で検出
- GRUB sector read error (5%) → racreset soft

## 未完了事項 (別 issue 候補)

- `pve-setup-remote.sh` の post-reboot default route 維持機構 (route check + dhclient 埋め込み)
- LINBIT keyring 事前取得を必須ステップ化
- `--linstor` 時に build-essential を依存パッケージリスト追加
- `ssh-wait.sh` の `--user` flag 対応 (iDRAC SSH 復旧確認用)
- `pve-bridge-setup.sh` 内部に route pre-flight check

## 関連 issue

(必要に応じて、issues.yml 確認後に追記)
```

## Critical Files

新規:
- `/home/ubuntu/projects/pvese/report/2026-05-12_213148_os_setup_skill_10x_training.md`

新規ディレクトリ + コピー先:
- `/home/ubuntu/projects/pvese/report/attachment/2026-05-12_213148_os_setup_skill_10x_training/` (32 ファイル)

移動元 (削除予定):
- `/home/ubuntu/projects/pvese/report/training/` (31 ファイル + ディレクトリ)

プラン origin (コピー元):
- `/home/ubuntu/.claude/plans/report-2026-05-12-040320-server14-os-ins-mossy-cookie.md`

## 実装ステップ

1. `mkdir -p report/attachment/2026-05-12_213148_os_setup_skill_10x_training/`
2. `mv report/training/*.md report/attachment/2026-05-12_213148_os_setup_skill_10x_training/`
3. `cp /home/ubuntu/.claude/plans/report-2026-05-12-040320-server14-os-ins-mossy-cookie.md report/attachment/2026-05-12_213148_os_setup_skill_10x_training/plan.md`
4. `rmdir report/training/`
5. `Write report/2026-05-12_213148_os_setup_skill_10x_training.md` (上記構成で総合レポート)
6. 検証: `ls report/attachment/2026-05-12_213148_os_setup_skill_10x_training/` で全 32 ファイル存在確認、Web UI から本文中のリンクをチェック (Markdown プレビュー)

## 検証 (エンドツーエンド)

- `ls report/attachment/2026-05-12_213148_os_setup_skill_10x_training/ | wc -l` = 32
- Markdown プレビュー (`cat report/2026-05-12_213148_os_setup_skill_10x_training.md`) で全リンク (相対パス) が正しく整形されているか
- `ls report/training/` が "No such file or directory" になる
- Discord 通知が発火する (Write が `report/*.md` に書き込み)

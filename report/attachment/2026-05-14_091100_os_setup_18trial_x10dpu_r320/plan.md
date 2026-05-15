# x10dpu + r320 セットアップスキル 3 周通しデグレ検証 実装プラン

## Context

`os-setup` スキルは 2026-05-12 に 14-15 号機 (R430) で 20 trial の通しテストを完了し、累計 30 件の改善が反映された (`report/2026-05-12_213148_os_setup_skill_10x_training.md`)。一方、本拠点メインの **4-6 号機 (Supermicro X11DPU, "x10dpu") + 7-9 号機 (DELL R320, "r320")** ではスキル変更後の通しテストを実施していない。

R430 向けに追加された分岐 (`partman/early_command` の disk 列挙、LVM 推奨など) や、preseed・スクリプトの一般化変更が x10dpu / r320 系で**デグレ (= 既存動作の悪化) を起こしていないか**を実機で検証する。

- **対象**: server4-9 の計 6 台 × 3 周 = **18 OS install**
- **既存ディスクは破壊可** (各 trial で full reinstall)
- **目的**: スキル動作のデグレ検出 + 残存問題の洗い出し
- **完了条件**: 18 trial 完走後、全 6 台を OS shutdown -h now で停止 (BMC は通電維持)
- **時間バジェット**: ~24 時間 (じっくり調査する余裕あり)

ユーザ確認済み方針:
1. **完全直列実行** — 1 台 1 trial ずつ、4→5→6→7→8→9 を順番に処理、これを 3 ラウンド
2. 失敗時はスキル内蔵リトライ (racreset soft 等) に任せて、最終成功で 1 カウント
3. 完了時シャットダウンは `ssh ... shutdown -h now`、SSH 不通時のみ ipmitool フォールバック
4. 新規 issue を作って独立追跡 (既存 #42-44 は別カウントのまま放置)

---

## 実行アーキテクチャ

### 完全直列モデル

```
Round 1:
  trial-1-s4  → trial-1-s5  → trial-1-s6  → trial-1-s7  → trial-1-s8  → trial-1-s9
Round 2:
  trial-2-s4  → trial-2-s5  → trial-2-s6  → trial-2-s7  → trial-2-s8  → trial-2-s9
Round 3:
  trial-3-s4  → trial-3-s5  → trial-3-s6  → trial-3-s7  → trial-3-s8  → trial-3-s9
→ 全 6 台 shutdown
→ 総合レポート生成
```

- 各 trial は 1 サーバの Phase 1-8 を完走
- 1 trial 完走 35-50 分目安 (ISO 再利用、過去 14-15 号機平均 56 min、x10dpu/r320 は構成が単純で短縮見込)
- 全 18 trial 合計 **10.5-15 時間** (24 時間バジェット内、調査時間を含めても余裕あり)

### 実行主体: 各 trial = 1 subagent (general-purpose, model: sonnet)

- subagent モデル: `sonnet` (Sonnet 4.6) を使用
- 親エージェント (Opus 4.7 1M) は 18 個の subagent を順番に起動
- 親 (Opus) の責務: ラウンド進行制御、Round summary 生成、final summary、デグレ判定
- 各 subagent (Sonnet) の責務: SKILL.md に従い、自分の担当 1 サーバ × 1 trial を Phase 1-8 まで完走

### Session 命名 (実行時固定値)

```
ISSUE_ID    = 65
SESSION_ID  = e28df8d0
REPORT_TS   = 2026-05-14_091100
SESSION_TMP = tmp/e28df8d0
ATTACH      = report/attachment/2026-05-14_091100_os_setup_18trial_x10dpu_r320
REPORT_MD   = report/2026-05-14_091100_os_setup_18trial_x10dpu_r320.md
```

---

## Trial 毎の必須前処理 (subagent 内で実行)

```sh
N=<server number>
ROUND=<1,2,3>
find state/os-setup/server${N} -mindepth 1 -delete
./scripts/os-setup-phase.sh init --config config/server${N}.yml
ssh-keygen -R "10.10.10.20${N}" -f ssh/known_hosts || true
```

---

## 失敗境界 / 例外処理

| 状況 | 対応 |
|------|------|
| skill 内 racreset soft 3 連続失敗 | trial = giveup、次 trial へ進む |
| skill 内 install-monitor exit 4 が 3 回 | 同上 |
| ssh-wait 30 回失敗 | 同上 |
| BMC API 完全無応答 | trial = giveup、次 trial へ |
| 3 ラウンド連続 giveup の特定サーバ | 別 issue でハード故障疑い追跡 |

---

## レポート構造

```
report/
  2026-05-14_091100_os_setup_18trial_x10dpu_r320.md   (総合レポート)
  attachment/2026-05-14_091100_os_setup_18trial_x10dpu_r320/
    plan.md
    progress.md
    final-summary.md
    round-1-summary.md
    round-2-summary.md
    round-3-summary.md
    trial-1-s4.md ... trial-3-s9.md (合計 18 件)
```

合計 24 ファイル。

---

## デグレ判定基準

- x10dpu (4-6): skill 内蔵リトライで救えなかった giveup が過去観察を超えて増えていないか
- r320 (7-9): 同上 (7 号機 NVRAM 枯渇 #47 は既知)
- 観察ポイント:
  - R430 向け preseed の `partman/early_command` disk 列挙 (`/dev/sda` 明示) が x10dpu/r320 で副作用なしか
  - LVM 推奨化が UEFI 環境で問題なしか
  - SOL serial_unit 一般化が iDRAC7 で機能しているか
- 新規問題はスキル/スクリプト修正の別 issue 化 (本タスクのスコープは検証のみ)

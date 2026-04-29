# `bios-setup` スキルの X10DRT-P (10号機) 対応

## Context

[10号機追加レポート](../../projects/pvese/report/2026-04-30_023103_add_server10_x10drt_p.md) の残タスク #5「`bios-setup` スキルの X10DRT-P 対応」を実施する。

- 現状: `bios-setup` は **4-6号機 (Supermicro X11DPU) 専用** と SKILL.md/description で明示
- 10号機は **Supermicro X10DRT-P** マザーボード (Nutanix NX-1065-G5 OEM)、BMC ASPEED 2400 / FW 3.65、AMI Aptio UEFI BIOS — 同じベンダ系統
- 既存の `bmc-kvm-interact.py` / `bmc-kvm-screenshot.py` は **完全にパラメタライズ済み** で 10号機でも動作確認済み (2026-04-30 Phase A)
- ただし **X10DRT-P の BIOS Setup UI 自体はまだ一度も観測されていない**。AMI Aptio という共通点はあるが、世代が異なる (Haswell/Broadwell 期 C610 PCH vs Skylake-SP 期 C621/C622) ため、タブ構成・サブメニュー名・既定値・設定項目が異なる可能性がある

本タスクの目的: **実機 BIOS UI の観測 → 互換性判定 → スキル/リファレンス更新** を行い、10号機を `bios-setup` で操作できる状態にする。

ユーザ確認済み方針 (本タスク開始時に確定):
- **観測スコープ**: X11DPU 既存 reference.md 並みに **全項目を記録** (全 7 タブ・Advanced 16+ サブメニュー・全設定値・選択肢を網羅)
- **ドキュメント構成**: 互換時は `reference.md` に **X10DRT-P 固有差分節を追加** (新ファイル `reference-x10drt-p.md` は作らない)
- 非互換時 (タブ構成等が大きく異なる場合) のみ専用 reference を作成

## 変更対象 (Phase 1 の観測結果に応じて分岐)

### 必ず行う (互換性によらず)

1. **`.claude/skills/bios-setup/SKILL.md`**
   - L3 description: `Supermicro X11DPU BIOS Setup 操作` → `Supermicro X11DPU/X10DRT-P BIOS Setup 操作`
   - L3 末尾: `4-6号機のみ対応` → `4-6号機 + 10号機対応`
   - L9: `Supermicro X11DPU (4-6号機)` → `Supermicro X11DPU (4-6号機) と X10DRT-P (10号機)`
   - L23-24「前提条件」: 10号機 (BMC `10.10.10.30`、claude ユーザは index 4) を追記
   - 各サブコマンドのコマンド例 (L94-96 等) は 4号機 (10.10.10.24) のままでよいが、10号機向け例を 1〜2 箇所追加 (`enter` と `screenshot` のセクション)
   - 「POST 92 スタック対策」は X11DPU 4号機固有の現象 → 既存記述を残し「(4号機 X11DPU 固有)」と注記
   - X10DRT-P 固有の差分 (BMC FW 3.65 / AST2400 / Twin Server / Nutanix OEM 制約) を 1 セクションにまとめて追記

2. **`config/server10.yml`** L38-39 — Phase 1 で実機の `console=ttyS?` を確認した結果に応じて `serial_unit` を確定 (現在 `1` 仮置き)。BIOS の Serial Port Console Redirection で SOL の有効ポートが COM1 (ttyS0) か COM2 (ttyS1) かを観測する

### 互換性判定で分岐

**Phase 1 で X11DPU と十分互換と判定された場合 (タブ7枚、AMI Aptio キーバインド、Boot タブ構造が同等)** — 想定本命:

- **`.claude/skills/bios-setup/reference.md`** に **X10DRT-P (10号機) 全項目セクション** を追加 (ユーザ指定: 新ファイルは作らない)
  - 既存の冒頭「X11DPU BIOS 設定リファレンス」を `## X11DPU (4-6号機)` 配下に再構成し、その後に `## X10DRT-P (10号機)` の同形式パラレル節を追加
  - X10DRT-P 節の章立ては X11DPU と同じ (Main / Advanced (16+ サブメニュー) / Event Logs / IPMI / Security / Boot / Save & Exit / PVE 推奨設定サマリー / 危険な設定一覧)
  - 各設定項目について、X11DPU と同じフォーマット (オプション / デフォルト / 10号機の現在値 / 解説 / PVE 推奨 / リスク) で記載
  - X11DPU と同一の項目は説明を省略せず、観測した実値を記録 (デフォルト値・選択肢が異なる場合があるため)
  - 末尾に「X11DPU との主要差分サマリー」表を追加 (BIOS Version、CPU 世代、PCH チップセット、Memory Frequency 範囲、Boot Option 構成など)

**Phase 1 で UI に大きな差異 (タブ構成や主要サブメニュー名が異なる) が見つかった場合** — フォールバック:

- **`.claude/skills/bios-setup/reference-x10drt-p.md`** を新規作成
  - X11DPU 用 `reference.md` と同じ章立てで全項目を記録 (上記の詳細度を維持)
- **`.claude/skills/bios-setup/SKILL.md`** に「対象サーバごとに参照すべきリファレンス」テーブルを追加し、`reference.md` (X11DPU) と `reference-x10drt-p.md` (X10DRT-P) を併記

### 触らない (明示)

- `scripts/bmc-kvm-interact.py`, `scripts/bmc-kvm-screenshot.py` — Phase A で完全互換確認済み、修正不要
- `scripts/bmc-power.sh`, `scripts/bmc-session.sh` — 同上
- 4-6号機 (X11DPU) 関連の既存 reference 記述 — 4号機実測値はそのまま保持
- `bios-setup` 以外のスキル (`os-setup`, `idrac7`, `perc-raid` 等) — 範囲外
- `CLAUDE.md`, `README.md` — 前タスクで反映済み、本タスクで再修正なし
- `MEMORY.md` — 必要に応じて X10DRT-P BIOS の特記事項を追記する程度。サーバ情報表は前タスクで更新済み

## 実施手順

### Phase 1: 実機 BIOS UI 観測 (本タスクの中核 — 全項目記録モード)

X11DPU の `reference.md` (約 1000 行・全タブ全サブメニュー網羅) と同等粒度で記録する。

1. **電源状態確認**: `ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status` で現状を取得
2. **pve-lock 取得 → BIOS 進入**: 既存の SKILL.md `enter` 手順 (ForceOff → 15秒 → Power On → 60×Delete --wait 1000 + screenshot-each) をそのまま 10号機向けに実行
   - BMC IP のみ `10.10.10.30` に置換
   - `tmp/<sid>/bios_entry_NNN.png` を取得
   - 60 枚を順に確認し、`Aptio Setup Utility` のテキストが見えるフレームを特定
3. **基礎情報取得**: Main タブで BIOS Version / Build Date / CPLD / Total Memory / CPU 型番を読む
4. **全タブ巡回スクリーンショット**: ArrowRight でタブを 1 枚ずつ進め、各タブの初期画面を撮影
   - キャンバス解像度 (800x600 か別か) を確認
   - タブ枚数・名称・順序を確認
5. **Advanced タブ全サブメニュー網羅**: `--screenshot-each` + 連続 ArrowDown/Enter/Escape で全サブメニューに進入し、**各サブメニュー内も ArrowDown でスクロールして全項目を撮影**
   - サブメニュー名一覧 (X11DPU は 16) を取得
   - 各サブメニュー内の全設定項目とその値・選択肢を確認 (Enter でドロップダウンを開いて選択肢を読み、Esc でキャンセル)
   - 階層が深い (Chipset > North Bridge > IIO Configuration 等) サブサブメニューも展開
6. **Event Logs / IPMI / Security / Save & Exit 全項目**: 各タブを順次同様に巡回
7. **Boot タブ全項目**: Boot Mode、全 Boot Option (#1～最後)、サブメニュー (BBS Priorities 等) を撮影
8. **Serial Port Console Redirection 確認**: SOL ポート (COM1/COM2) と Bits per second / Terminal Type を確認 → `config/server10.yml` の `serial_unit` 検証材料
9. **設定値の選択肢列挙**: 主要 enum 設定 (Boot Mode、Memory Frequency、Hyper-Threading、VT-d 等) のドロップダウンを開いて全選択肢を撮影 (キャンセルで戻す)
10. **BIOS Setup から離脱**: F2 (Previous Values) でリセット → Esc → 「Discard Changes and Exit」を選択 → サーバ電源 OFF
    - 設定変更は **一切行わない**。観測のみ。誤って設定を変えた場合は必ず F2 で戻すか Discard Exit
11. **観測ログ整理**: スクリーンショットを `report/attachment/<本レポート>/bios_screens/` に体系的に格納
    - `01_main.png`, `02_advanced.png`, `03_event_logs.png`, ... のような連番命名
    - サブメニューは `02a_advanced_boot_feature.png`, `02b_advanced_cpu_config.png` 等

**所要時間目安**: BIOS 進入 + 60 タブ巡回 + 全サブメニュー網羅で 2〜4 時間 (再起動・KVM 接続のオーバーヘッド込み)。BMC は同時 1 セッションのみのため逐次実行。

### Phase 2: 互換性判定 + ドキュメント執筆

Phase 1 の結果を踏まえて以下を判定:

- 7 タブ構成か?
- Boot タブの DUAL/UEFI/Legacy + Boot Option ドロップダウンか?
- Advanced サブメニュー名が概ね一致するか? (CPU Configuration / Chipset / PCH SATA / PCIe / Serial / ACPI など)
- AMI Aptio のキーバインド (ArrowKeys / Enter / Esc / +/- / F2-F4 / PageUp/PageDown) が同等か?

**判定結果に応じて上記「変更対象」セクションの分岐を実行。** 互換と判定された場合、`reference.md` を以下の構造に再編する:

```
# Supermicro BIOS 設定リファレンス
## はじめに
## X11DPU (4-6号機)         ← 既存内容を移動
  ### Main タブ
  ### Advanced タブ (16 サブメニュー)
  ### Event Logs / IPMI / Security / Boot / Save & Exit
  ### PVE 推奨設定サマリー
  ### 危険な設定一覧
## X10DRT-P (10号機)         ← 新規追加 (X11DPU と同章立て)
  ### Main タブ
  ### Advanced タブ (実機サブメニュー)
  ### ...
  ### X11DPU との主要差分サマリー
## 共通: カーネルブートパラメータとの対応
## 参考資料
```

各設定項目は X11DPU 節と同フォーマット (オプション / デフォルト / 10号機の現在値 / 解説 / PVE 推奨 / リスク) で全項目記載する。

### Phase 3: 検証

1. SKILL.md / reference (新旧) の整合性チェック
2. 4-6号機の説明が degrade していないか確認 (description / 前提条件 / 既存サブセクションを再読)
3. Phase 1 のスクリーンショットを添付ファイルとしてレポートに紐づける
4. レポート作成 (`report/yyyy-mm-dd_hhmmss_bios_setup_x10drt_p_support.md`)
   - JST タイムスタンプは `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` で取得
   - `## 添付ファイル` セクションに本プランファイルへのリンクを記載
5. `./issue.sh` で本タスクを管理 (既存の運用ルール準拠)

## 重要ファイルパス

- `/home/ubuntu/projects/pvese/.claude/skills/bios-setup/SKILL.md` — メイン更新対象
- `/home/ubuntu/projects/pvese/.claude/skills/bios-setup/reference.md` — 互換時の追記対象
- `/home/ubuntu/projects/pvese/.claude/skills/bios-setup/reference-x10drt-p.md` — 非互換時の新規作成対象
- `/home/ubuntu/projects/pvese/scripts/bmc-kvm-interact.py` — KVM 操作スクリプト (修正なし、再利用)
- `/home/ubuntu/projects/pvese/config/server10.yml` — `serial_unit` 確定の判断材料
- `/home/ubuntu/projects/pvese/report/2026-04-30_023103_add_server10_x10drt_p.md` — 前タスクレポート (起点)
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/server10_nutanix_oem.md` — Nutanix OEM 制約

## 既存資産の再利用

- `scripts/bmc-kvm-interact.py` — `--bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123` で 10号機にもそのまま使える (パラメタライズ済み、Phase A で確認)
- `scripts/bmc-power.sh` — `pve-lock.sh run ./scripts/bmc-power.sh forceoff/on 10.10.10.30 claude Claude123`
- `pve-lock.sh` — 電源操作の排他制御
- `oplog.sh` — 状態変更ログ記録 (BIOS 進入のための電源操作)
- 既存 `reference.md` の節構造 — X10DRT-P 専用 reference を作る場合も同じ章立てを踏襲

## 検証方法

1. **Phase 1 検証 (UI 観測完了)**:
   - `tmp/<sid>/bios_entry_NNN.png` の少なくとも 1 枚に `Aptio Setup Utility` が見える
   - 7 タブ構成の場合は ArrowRight 6 回でループする
   - Advanced サブメニュー一覧が記録されている

2. **Phase 2 検証 (スキル更新完了)**:
   - SKILL.md の description に `X10DRT-P` と `10号機` が含まれる
   - `bios-setup` スキル一覧文を読み返して 10号機が「対応サーバ」として識別できる
   - 互換時: `reference.md` の冒頭目次に `## X11DPU (4-6号機)` と `## X10DRT-P (10号機)` の 2 節が並列に存在し、X10DRT-P 節は 7 タブ全項目を網羅 (Advanced サブメニューが Phase 1 で観測した個数分)
   - 非互換時: `reference-x10drt-p.md` が存在し、SKILL.md からリンクされている
   - 4-6号機の既存記述が壊れていない (`grep -n 'X11DPU\|4号機\|5号機\|6号機' .claude/skills/bios-setup/*.md` で残存確認)
   - X11DPU 節の項目数 (Advanced 16 サブメニュー、PVE 推奨設定サマリー、危険な設定一覧) が Phase 2 後も保持されている

3. **Phase 3 検証 (レポート反映)**:
   - `report/yyyy-mm-dd_*_bios_setup_x10drt_p_support.md` が存在
   - 添付に主要スクリーンショット (タブ巡回 + Advanced サブメニュー) が含まれる

## リスク・注意点

- **Nutanix OEM 制約**: BMC FW 更新は不可だが BIOS Setup の閲覧・操作は通常通り可能 (既に Phase A で BMC 操作の互換性確認済み)
- **電源操作**: BIOS 進入には Power Cycle が必須 → pve-lock 必須
- **設定変更禁止**: 観測フェーズで誤って Save するとブート失敗のリスクがある。**観測時は必ず F2 (Previous Values) → Discard Exit** でリセットする
- **Twin Server 構成**: X10DRT-P は 2U Twin の一方のノード。10号機の BMC はノード固有 (もう一方のノードがあるかは別問題で本タスク範囲外)
- **キャンバス解像度**: X10DRT-P で BIOS 画面が 800x600 でない場合、`bmc-kvm-interact.py` の `safe_click` 座標が正しくない可能性 → `--no-click` を使うパスを優先
- **POST 時間**: X10DRT-P の POST タイミングは X11DPU と異なる可能性あり。Delete 60 連打 (--wait 1000) で 60 秒カバーするが、もし入れない場合は SKILL.md の手順を更新する必要がある

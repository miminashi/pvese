# 8号機 VirtualMedia 故障再現 → OS セットアップ テスト

## Context

2026-04-10 のレポート [`report/2026-04-10_125116_server8_virtualmedia_recovery.md`](../../projects/pvese/report/2026-04-10_125116_server8_virtualmedia_recovery.md) で、8号機の VirtualMedia ブート不能状態の復旧手順が確定した。この手順と、それを記載したスキル文書 (`.claude/skills/idrac7/SKILL.md`, `.claude/skills/os-setup/SKILL.md`) が「ヒントなしの新規エージェントでも機能するか」を検証する。

検証方法は以下の 2 段構成 + 失敗時の改善ループ:

1. **再現エージェント (sonnet)**: 8号機に対し `racadm set BIOS.BiosBootSettings.BootMode` を叩き、`Optical.iDRACVirtual.1-1` が UefiBootSeq から削除された状態を再現する。
2. **テストエージェント (sonnet)**: 8号機 (`config/server8.yml`) に対し OS セットアップを通常通り指示する。ヒント禁止。エージェントは VirtualMedia ブートが失敗することに自力で気付き、ドキュメント化された復旧手順を適用し、最終的に OS インストールを完遂できるか検証する。
3. **失敗時の改善ループ (最大 10 反復)**: テストエージェントが失敗した場合、得られた知見からスキル文書を修正し、同じ条件 (故障再現→OS セットアップ) で再度エージェントを起動する。成功まで繰り返す (上限 10 回)。

目的は以下を確認すること:

- ドキュメントが独立して機能するか (スキル文書だけで復旧できるか)
- 故障パターンが想定通りに再現できるか
- 復旧手順の再現性
- ドキュメントに不足があれば実証的に埋めていく

## 現状の理解

### 根本原因 (レポートより)
`racadm set BIOS.BiosBootSettings.BootMode Uefi` または `Bios` で BootMode を切り替えると、R320 / iDRAC7 FW 2.65.65.65 / BIOS 2.3.3 では UefiBootSeq から `Optical.iDRACVirtual.1-1` が削除され、VirtualMedia ブートが永続的に不能になる。一度削除されると racadm では復元不可 (`BOOT018` read-only)。

### 復旧手順 (レポートの Phase A-D)
1. クリーン状態化 (umount + boot-reset)
2. 電源オフ → 電源オン → POST 開始後 F2 連打で BIOS Setup 入場
3. System BIOS → F3 (Load Defaults) → Enter
4. BIOS UI 上で Boot Mode を UEFI に手動変更
5. 電源オフ → VirtualMedia マウント → 電源オン (boot-once 不要)
6. BIOS POST で VirtualMedia を再列挙させ UefiBootSeq に再登録

### 8号機の現在の想定状態
- BootMode: UEFI
- UefiBootSeq: `Optical.iDRACVirtual.1-1` 登録済み (復旧済み)
- VirtualMedia ブート: 動作可能

### 第 1 エージェントの作業で8号機に起きる変化
- `racadm set BootMode` を叩くことで Optical.iDRACVirtual.1-1 が UefiBootSeq から削除される
- 結果: VirtualMedia ブート不能状態 (再現完了)

## 実行計画

### Step 1: 再現エージェント起動 (sonnet, foreground)

`subagent_type: general-purpose`, `model: sonnet` で起動。プロンプトには以下を明記:

- **これは認可されたテストである旨を明示**: スキル文書に「絶対禁止」と書かれている `racadm set BIOS.BiosBootSettings.BootMode` を、本テストのために意図的に実行してよい。目的は復旧手順の検証。
- **対象**: 8号機 (`config/server8.yml`, BMC `10.10.10.28`, `idrac8`)
- **手順**: 
  1. 事前状態の記録 (`racadm get BIOS.BiosBootSettings.BootMode` と `racadm get BIOS.BiosBootSettings.UefiBootSeq` の値、`Optical.iDRACVirtual.1-1` が現状含まれていることを確認)
  2. `pve-lock.sh wait` + `oplog.sh` 経由で以下を実行:
     - `ssh -F ssh/config idrac8 racadm set BIOS.BiosBootSettings.BootMode Bios`
     - `ssh -F ssh/config idrac8 racadm jobqueue create BIOS.Setup.1-1 -s TIME_NOW -r pwrcycle`
     - ジョブ完了まで待機 (POST + jobqueue view でポーリング、10 分上限)
     - `ssh -F ssh/config idrac8 racadm set BIOS.BiosBootSettings.BootMode Uefi`
     - `ssh -F ssh/config idrac8 racadm jobqueue create BIOS.Setup.1-1 -s TIME_NOW -r pwrcycle`
     - ジョブ完了まで待機
  3. 事後状態の記録: `racadm get BIOS.BiosBootSettings.UefiBootSeq`
  4. **必須検証**: UefiBootSeq に `Optical.iDRACVirtual.1-1` が **含まれない**ことを確認 (含まれる場合は再現失敗 → フラグして終了)
  5. 作業終了時の 8号機の電源状態は Off にしておく
- **禁止事項**: 復旧手順は実行しない。OS セットアップも開始しない。VirtualMedia のブート検証 (失敗を実機で見る) は任意だが時間節約のため省略可。
- **報告**: 事前/事後の UefiBootSeq 差分、所要時間、最終状態 (電源 off / UefiBootSeq の破損が確認済みか) を 300 字以内で返す

### Step 2: テストエージェント起動 (sonnet, foreground)

Step 1 の完了後、`subagent_type: general-purpose`, `model: sonnet` で起動。プロンプトは以下のような**通常の OS セットアップ指示のみ**:

```
8号機 (config/server8.yml) に対して OS セットアップを実行してください。
os-setup スキルに従って全フェーズを完了させてください。
```

具体的には以下を **書かない**:
- VirtualMedia が壊れていること
- racadm BootMode の話
- 復旧手順への言及
- report/2026-04-10_125116_*.md への参照
- 「途中で問題が起きるかも」といった予告

エージェントは通常通りスキルを読み、フェーズを進め、VirtualMedia ブート段階で失敗したら自力で診断・復旧し、最終的に OS インストール + PVE セットアップまで完遂することが期待される。

**タイムアウト**: バックグラウンド実行ではなく foreground で開始。エージェントが長時間作業するため、途中でユーザから中断指示が入る可能性は想定しておく。

### Step 3: 結果の検証と判定

テストエージェントが完了したら、以下を確認して成功/失敗を判定:

**成功条件 (すべて満たすこと)**:
- `ssh -F ssh/config pve8 uname -a` が成功 (OS インストール完了)
- `ssh -F ssh/config pve8 pveversion` が成功 (PVE インストール完了)
- `racadm get BIOS.BiosBootSettings.UefiBootSeq` に `Optical.iDRACVirtual.1-1` が復帰
- os-setup スキルで定義されている全フェーズが完了している (`./scripts/os-setup-phase.sh status --config config/server8.yml` で確認)

**失敗判定**:
- 上記のいずれかが満たされない
- エージェントが途中で諦めて戻ってきた
- エージェントが無限ループ/長時間停止した状態で中断された

### Step 4: 失敗時のスキル改善ループ (最大 10 反復)

Step 3 で失敗判定となった場合、以下を実行:

1. **失敗原因の分析**: テストエージェントの最終レポート、作業ログ、`state/os-setup/server8/` の状態を読み、どのフェーズで/何が原因で詰まったかを特定
2. **スキルへの改善反映**: 原因に応じて以下のいずれかを修正:
   - `.claude/skills/os-setup/SKILL.md` — 手順の不足、注意書きの不足、フェーズ定義の曖昧さ
   - `.claude/skills/idrac7/SKILL.md` — 復旧手順の不明瞭な箇所、キー操作の詳細化、スクリーンショット判定基準
   - `scripts/` — スクリプトに起因する問題があればコード修正も検討
3. **再現状態に戻す**: 8号機が既に「VirtualMedia ブート不能」状態でない場合は、再現エージェント (Step 1) を再起動して故障を再現する。VirtualMedia 不能のままであれば再現はスキップ
4. **テストエージェント再起動**: Step 2 と同じ条件 (ヒントなし、通常の OS セットアップ指示のみ) で新しいエージェントを起動
5. **反復**: Step 3 に戻る

**反復上限**: 合計 10 反復まで (Step 2 の初回 + 9 回のリトライ)。10 反復で成功しなかった場合はループを終了してユーザに報告する。

**反復間の記録**: 各反復ごとに以下を `tmp/<sid>/iter-N-summary.md` に記録:
- 反復番号
- テストエージェントの結果 (成功/失敗、失敗時は原因)
- 反復 N で修正したスキル/スクリプトと diff の要約
- 次の反復での仮説

### Step 5: 最終報告 + レポート作成

ループ終了後 (成功または 10 反復上限到達) に、結果の成否に関わらず `report/` へレポートを作成する。

- ファイル名: `report/YYYY-MM-DD_HHMMSS_server8_vmedia_recovery_test.md` (JST タイムスタンプ)
- フォーマットは [REPORT.md](../../projects/pvese/REPORT.md) のルールに従う
- 記載内容:
  - 前提・目的 (本テストの動機、第 1/第 2 エージェント構成の意図)
  - 初期状態 (Step 1 の故障再現結果)
  - 各反復の要約表: 反復番号 / 失敗原因 / スキル修正内容 / 結果
  - 最終状態 (成功なら OS/PVE 動作確認結果、失敗なら残存症状と残存課題)
  - 得られた知見: どのスキル文書が不足していたか、復旧手順のどの部分が曖昧だったか
  - スキル最終差分の要約
  - 関連レポートへのリンク (2026-04-10_125116_server8_virtualmedia_recovery.md 等)

ユーザへの最終報告は、レポート作成後にレポートへのリンクを添えて行う。

## 実行時の注意事項

- 両エージェントとも `model: sonnet` を指定
- 再現エージェントは `run_in_background: false` (foreground) で起動し、完了を待ってからテストエージェントを起動する
- どちらのエージェントのプロンプトも自己完結型にする (会話履歴は見えない)
- 再現エージェントには CLAUDE.md ルール (pve-lock, oplog, ssh -F ssh/config, tmp/<sid>/) を守るよう明記
- テストエージェントには特別なヒントは渡さず、通常の os-setup 指示のみ
- セッション ID: `5b576cc5` (現セッション、tmp 参照用 — ただし各子エージェントは自身のセッション ID を持つ)

## 参照ファイル

| ファイル | 役割 |
|---------|------|
| `report/2026-04-10_125116_server8_virtualmedia_recovery.md` | 根本原因と Phase A-D の詳細手順 |
| `.claude/skills/idrac7/SKILL.md` (L229-321) | 「VirtualMedia ブート復旧手順」の正式文書 |
| `.claude/skills/os-setup/SKILL.md` (L188-191) | 「絶対禁止」警告と復旧手順へのリンク |
| `config/server8.yml` | 8号機の設定 (BMC IP, 静的 IP, ISO 等) |
| `scripts/idrac-virtualmedia.sh` | VirtualMedia マウント/アンマウント/boot 制御 |
| `scripts/idrac-kvm-interact.py` | VNC 経由キー送信 + スクリーンショット |

## Verification (計画実行後)

- 再現エージェント完了時: `ssh -F ssh/config idrac8 racadm get BIOS.BiosBootSettings.UefiBootSeq` の出力に `Optical.iDRACVirtual.1-1` が含まれない
- テストエージェント完了時 (成功ケース):
  - `ssh -F ssh/config pve8 uname -a` が成功
  - `ssh -F ssh/config pve8 pveversion` が成功
  - `racadm get BIOS.BiosBootSettings.UefiBootSeq` に `Optical.iDRACVirtual.1-1` が復帰している
  - `./scripts/os-setup-phase.sh status --config config/server8.yml` で全フェーズ完了
- テストエージェント失敗時: Step 4 の改善ループへ遷移
- 10 反復で成功しなかった場合: ループ終了、ユーザに状況と残存課題を報告

---
name: run-with-dual-verify-in-pane
description: "別の tmux ペインで動いている Claude Code インスタンスを、このセッションから tmux send-keys / capture-pane で駆動するオーケストレーション。プランモード投入 → プラン再点検 (1 回目の検証) → ユーザ承認ゲート → auto mode 実装 → レポート未記載追記 → レポート矛盾再チェック (2 回目の検証) の定型フロー。長時間タスクをもう 1 体の claude に「ダブルチェック付きで」実行させ、要所だけ自分が監督したいときに使う。"
argument-hint: "[target-pane 例: pvese:0.1]  [main-prompt]"
---

# run-with-dual-verify-in-pane スキル

このセッション (オーケストレータ) から、**隣の tmux ペインで動く別の Claude Code** を
`tmux send-keys` / `capture-pane` で操作し、プランニング → 実装 → レポート整備まで一気通貫で
駆動する。対象 claude が長時間タスク (例: TX1320 のフルセットアップ) を実行する間、自分は
状態を監視し、承認・質問・矛盾チェックなどの要所だけに介入する。

> 確立: 2026-06-19。TX1320 PVE ブリッジ構成 + RAID 初期化からのフルセットアップやり直しを、
> 右ペインの claude にプランモードで計画させ、2 段階の自己点検と人間承認ゲートを挟んで
> auto mode 実装させ、完了後にレポートの未記載追記 + 矛盾再チェックまで実行した手順を一般化。

## 大原則 (これだけは外さない)

1. **入力は必ず 2 段階**: ① `tmux send-keys -t <pane> -l "本文"` でテキストだけ送る →
   ② `capture-pane` で入力欄に正しく入っているか目視 → ③ `tmux send-keys -t <pane> Enter` で確定。
   テキストと Enter を 1 回の send-keys に混ぜない (途中改行で誤送信する)。
2. **送る前に必ず状態確認、送った後も必ず確認**。盲打ちしない。対象ペインは人間が別途
   操作している可能性もあるので、毎回 `capture-pane` で「今アイドルか」「入力欄に残骸はないか」を見る。
3. **対象 claude のターン中に文字を送らない**。生成中 (`esc to interrupt` 表示) に送ると
   割り込み or キュー入りで壊れる。必ずアイドル復帰を待ってから送る。
4. **判断が要る分岐 (プラン承認の可否など) は勝手に進めず人間に確認**。本スキルの既定フローでも
   「2 回目の承認」は必ず人間ゲート。

## 0. 対象ペインの特定

```sh
tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} #{pane_active} #{pane_current_command} #{pane_width}x#{pane_height} left=#{pane_left}"
```
- `pane_current_command` が `claude` のペインが対象。`left=` で左右、`pane_active` で今フォーカスが
  どこか分かる。自分 (オーケストレータ) と対象を取り違えないこと。
- 以降 `<pane>` は `session:window.pane` 形式 (例: `pvese:0.1`)。

## 1. ペイン状態の読み方 (capture-pane)

読み取りは **Bash 禁止事項に触れない** `tmux capture-pane -t <pane> -p -S -<N>` を使う
(末尾 N 行。フッターを見るなら `-S -6` で十分、ダイアログ全文なら `-S -30` 等)。

フッター / 末尾行のマーカーで状態を判定する:

| 表示 | 意味 | 介入可否 |
|------|------|---------|
| `esc to interrupt` | 対象が**生成中** (思考 or ツール実行) | 送信不可・待て |
| `· N shell ·` / `↓ to manage` / `N shell still running` | 対象が**自前のバックグラウンドシェル待ち**でターンを yield | 送信不可・待て (シェル完了で自動再開) |
| 上記いずれも無し + `❯ ` の空入力欄 + `(shift+tab to cycle)` | **真にアイドル** (入力待ち) | 送信可 |
| `Would you like to proceed?` + 番号付き選択肢 | **プラン承認ダイアログ** | 選択操作 |
| `1. Yes ... 2. ... 3. Type something` 等 | **質問 (AskUserQuestion)** | 選択操作 |
| `1. Yes 2. Yes, and don't ask again 3. No` 等 | **権限プロンプト** (auto mode 外) | 選択 or 人間確認 |

> ⚠️ **`(shift+tab to cycle)` は生成中でも表示される** (`... (shift+tab to cycle) · esc to interrupt`)。
> アイドル判定に単独で使わない。**`esc to interrupt` と `shell` 系が両方とも無いこと**が真のアイドル条件。

> ⚠️ **ゴーストサジェスト**: 空の入力欄に薄字で過去の入力候補 (`❯ ::1 も許可に追加して` 等) が
> 出ることがある。これは未送信テキストではなく**サジェスト**。1 文字打つと消える。`send-keys -l`
> でテキストを送れば上書きされるので無視してよい。迷ったら 1 文字打って確認。

## 2. テキスト送信の作法

```sh
# ① テキストだけ送る (日本語 OK。-l = literal でキーシーケンス解釈を抑止)
tmux send-keys -t <pane> -l "送りたいプロンプト本文"
# ② 入力欄を確認
tmux capture-pane -t <pane> -p -S -4
# ③ 問題なければ Enter で確定
tmux send-keys -t <pane> Enter
# ④ 送信できたか (生成が始まったか) を確認
tmux capture-pane -t <pane> -p -S -4
```
- **複数行プロンプトは 1 行に畳む** (改行をスペースに)。生の改行を送ると途中で確定する。
  どうしても改行を保ちたいなら本文は 1 回で送らず工夫が要るが、基本は 1 行化で十分。
- 制御キーは `send-keys`: `Enter` / `Escape` / `BTab` (= Shift+Tab) / `Down` / `Up` / `Tab`。

## 3. モード切替 (Shift+Tab = `BTab`)

`BTab` を 1 回送るごとにモードが循環する。送るたびに `capture-pane -S -3` でフッターを確認:

```
auto mode on  --BTab-->  (通常 / ? for shortcuts)  --BTab-->  accept edits on  --BTab-->  plan mode on  --BTab--> (auto mode on に戻る)
```
- 目標モードのフッター文字列 (`⏸ plan mode on` 等) が出るまで 1 回ずつ送って確認する。
  循環順は版で変わりうるので**回数を決め打ちせず、毎回確認**。

## 4. ダイアログ操作 (承認 / 質問 / 権限)

- 選択肢は `❯` が現在位置。`Down` / `Up` で移動し `Enter` で確定。番号直打ちより
  **`Down` で目的の行に `❯` を移動 → `capture-pane` で確認 → `Enter`** が確実。
- **プラン承認ダイアログ** (`Would you like to proceed?`):
  - `1. Yes, and use auto mode` … 承認して auto 実行
  - `2. Yes, manually approve edits` … 承認するが編集ごと確認
  - `4. Tell Claude what to change` … **承認せずフィードバックを返す** (これを選ぶと自由入力欄が開く)
  - → プランを「承認せず再点検させたい」ときは **4 を選んでフィードバック本文を送る**。
- **質問ダイアログ**で自由記述したいときは **`Type something.` を選択** → 質問ダイアログが閉じ
  通常の入力欄に戻るので、そこに回答を `send-keys -l` で入力 → Enter。
  (選択直後の capture では `User declined to answer questions` と出るが、これは「定型選択肢を選ばず
  自由入力に切り替えた」の意で正常。)

## 5. アイドル / 完了待ち (バックグラウンド監視)

対象がアイドル復帰 or ダイアログ停止するまで待つ監視スクリプトを **`tmp/<sid>/` に書いて**
`run_in_background: true` で回す (`.claude/` 配下は Bash 実行がブロックされるため skill 内には
置かず、下記を都度 tmp に展開する)。完了すると harness が自動で呼び戻す。

```sh
# tmp/<sid>/pane-wait.sh — 対象ペインが「真にアイドル」になるまで待つ
#   usage: sh tmp/<sid>/pane-wait.sh <pane> [streak] [poll_secs] [max_secs]
#   busy = 生成中(esc to interrupt) OR 自前のバックグラウンドシェル稼働中(N shell / to manage)
#!/bin/sh
set -u
PANE="${1:?usage: pane-wait.sh <pane> [streak] [poll] [max]}"
STREAK_TARGET="${2:-3}"   # 連続アイドル確認回数 (誤検知防止)
POLL="${3:-15}"           # ポーリング間隔秒
MAX="${4:-7200}"          # 上限秒 (長時間タスクは大きめに)
elapsed=0; streak=0
while [ "$elapsed" -lt "$MAX" ]; do
  snap=$(tmux capture-pane -t "$PANE" -p -S -6)
  busy=0
  printf '%s' "$snap" | grep -q "esc to interrupt" && busy=1
  printf '%s' "$snap" | grep -q "to manage" && busy=1
  printf '%s' "$snap" | grep -Eq "[0-9]+ shell" && busy=1
  if [ "$busy" -eq 1 ]; then streak=0; else streak=$((streak+1)); fi
  if [ "$streak" -ge "$STREAK_TARGET" ]; then echo "IDLE_OR_DIALOG"; exit 0; fi
  sleep "$POLL"; elapsed=$((elapsed+POLL))
done
echo "TIMEOUT"; exit 0
```

- 監視が `IDLE_OR_DIALOG` で返ったら **必ず `capture-pane -S -30` で中身を見る**。
  「タスク完了 (空入力欄)」「承認/質問ダイアログ」「権限プロンプト」のどれかを判別してから次手を打つ。
- ダイアログ専用に待ちたい場合は `grep` 条件を `keep planning` / `Would you like to proceed` /
  `Type something` 等に変えた別スクリプトにする。
- ❗ **誤完了に注意**: 対象が `sol-monitor` 等のバックグラウンドシェルを起動してターンを yield
  すると一瞬アイドルに見える。`N shell` / `to manage` を busy 扱いにしているのはこのため。
  それでも疑わしいときは中身を読んで「完了サマリが出ているか」を確認する。

## 6. 既定オーケストレーションフロー (今回実施した手順)

「もう 1 体の claude にプランニングから実装・レポート整備まで任せ、要所を監督する」標準レシピ。

1. **(任意) 既存セッションを終了して作り直す**: 対象が生成中なら `Escape` で中断 → アイドル確認 →
   `send-keys -l "/exit"` → `capture-pane` で候補に `Exit the CLI` を確認 → `Enter`。シェルに戻ったら
   `send-keys -l "claude"` → `Enter` で再起動。起動完了 (バナー + 入力欄) を確認。
2. **プランモードへ**: `BTab` を 1 回ずつ送り、`⏸ plan mode on` を確認 (§3)。
3. **メインプロンプト送信** (§2)。送信後 `Considering…` 等で生成が始まったことを確認。
4. **質問が出たら** (§4): 定型選択肢で足りなければ `Type something` → 通常入力欄で回答 → Enter。
   **回答内容が要件を変えるなら勝手に決めず人間に確認**。
5. **1 回目の承認ダイアログ → 自己点検させる**: `4. Tell Claude what to change` を選び、
   「再度、計画に矛盾がないか確認してください」を送る (承認せずプランを磨かせる)。
6. **2 回目の承認ダイアログ → 人間ゲート**: プラン全文を `Read` で読み (パスはフッターの
   `Planning: ~/.claude/plans/....md`) **要約して人間に承認を求める**。承認が出たら
   `1. Yes, and use auto mode` を確定。修正指示なら 4 でフィードバック。
7. **実装を待つ** (§5, `MAX` を十分大きく)。長時間タスクは複数回 yield するので `N shell` を
   busy 扱いした監視で「真の完了」だけ拾う。途中で**質問/権限プロンプトで停止したら人間に取り次ぐ**。
8. **完了後: レポート未記載の追記**: アイドル確認 → 「発見された事実でレポートに未記載の事項が
   ないか確認してください。追記する価値があるものは追記してください (価値判断は対象 claude に委ねる)」
   を送る → 完了待ち。
9. **最後: レポート矛盾の再チェック**: 「再度、レポートに矛盾がないか確認してください」を送る →
   完了待ち → 結果 (修正点) を人間に報告。

## 7. 進捗の見える化

各ステップ後に「何を送り、対象が今どの状態か」を人間に短く報告する。長時間待機に入る前に
「完了 or 停止で通知する」と伝えておく。停止 (質問/権限) を検知したら**その画面の内容を引用**して
人間の判断を仰ぐ。

## 落とし穴・既知の注意

- **送信のテキスト+Enter 混在**で誤送信 → 必ず分離 (§2)。
- **`(shift+tab to cycle)` をアイドル指標に使う**誤り → `esc to interrupt` と `shell` 系の不在で判定 (§1)。
- **バックグラウンドシェル yield を完了と誤判定** → `N shell` / `to manage` を busy 扱い (§5)。
- **ゴーストサジェストを未送信テキストと誤認** → 1 文字で消える/上書きされる (§1)。
- **`.claude/` 配下のスクリプトを `sh` で直接実行**するとセンシティブパスでブロック →
  監視スクリプトは `tmp/<sid>/` に Write して実行 (§5)。
- **モード循環の回数決め打ち** → 版差で順序が変わる。毎回フッター確認 (§3)。
- **対象ペインを人間も触っている前提**で、送信前後に必ず状態を読む。取り違え防止に §0 で
  `pane_active` / `left=` を確認。

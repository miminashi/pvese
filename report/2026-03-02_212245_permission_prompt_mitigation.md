# パーミッション承認プロンプト対策レポート

- **実施日時**: 2026年3月2日 21:22

## 前提・目的

Claude Code の Bash パーミッションは2層構造になっている:

1. **Layer 1**: `permissions.allow` のプレフィックスマッチ
2. **Layer 2**: 組み込み LLM クラシファイア（allow リストにマッチしても、コマンド全体を走査してインジェクション疑いパターンをブロック）

過去のセッションで報告された16件のブロックを分析し、4カテゴリに分類した:

| カテゴリ | 件数 | 原因 | 例 |
|---------|------|------|-----|
| A: 複合コマンド (`; \| &&`) | 5 | Layer 2 がチェイン検出 | `ls X; echo Y`, `zcat X \| grep Y` |
| B: SSH 引数内の引用符+ダッシュ | 2 | Layer 2 "quoted characters in flag names" | `ssh host 'cmd show-ports'` |
| C: `$()` コマンド置換 | 3 | Layer 2 が常にブロック | `docker run -v "$(pwd)"/...` |
| D: LLM 誤検出 (`2>&1`, sensitive path) | 6 | Layer 2 が不要な `2>&1` やパスを疑う | `ls -la ~/.ssh/`, `cat /proc/net/udp 2>&1` |

**根本原因**: Bash ツールは stdout/stderr を両方自動キャプチャするため `2>&1` や `2>/dev/null` は不要。にもかかわらず CLAUDE.md がこれらを「許可される」と記載していたため多用され、Layer 2 ブロックを誘発していた。

- 目的: CLAUDE.md のルールを修正し、Layer 2 ブロックを回避するガイダンスを追加する
- 前提条件: `.claude/settings.local.json` に問題のあるエントリが3件存在

## 環境情報

- Claude Code パーミッションシステム (Layer 1 + Layer 2)
- 対象ファイル: `CLAUDE.md`, `.claude/settings.local.json`, `settings.local.example.json`

## 実施内容

### 1. CLAUDE.md — リダイレクトルール修正 (旧 line 60)

旧:
> 許可されるのは `2>/dev/null` と `2>&1` のみ。stderr をファイルに保存したい場合は、Bash ツールの出力を直接利用すること

新:
> Bash ツールは stdout と stderr を両方キャプチャするため、`2>/dev/null` や `2>&1` は原則不要。これらを付けると Layer 2 LLM クラシファイアにブロックされることがある。`ssh` 引数内の `2>&1` は確実にブロックされる。どうしても stderr を抑制する必要がある場合のみ `2>/dev/null` をローカルコマンド単体で使ってよい

### 2. CLAUDE.md — 複合コマンドルール強化 (旧 line 57)

パイプ (`|`) も Layer 2 にブロックされることを追記。調査コマンドであっても `| head` を付けず、個別の Bash 呼び出しに分割するよう記載。

### 3. CLAUDE.md — ツールのインストール更新 (旧 line 65)

`sudo apt install -y <pkg>` で直接インストール可能であること（`Bash(sudo apt:*)` は許可リスト済み）に更新。

### 4. CLAUDE.md — 「自動承認されないコマンド」更新 (旧 line 131-141)

以下4項目を追加:
- `2>&1` 付きコマンド
- パイプ `|`・セミコロン `;` の複合コマンド
- `$()` コマンド置換
- `.ssh/`, `/proc/` 等のセンシティブパスへのアクセス

`sudo` の例外を `(iptables 以外)` → `(iptables, apt 以外)` に更新。

### 5. CLAUDE.md — 組み込みセキュリティチェック拡充 (旧 line 143-168)

テーブルに3行追加:

| 検出パターン | 理由メッセージ | 典型例 |
|-------------|--------------|--------|
| コマンド末尾の `2>&1`, `2>/dev/null` | LLM classifier detection | `ls /path 2>&1` |
| パイプ `\|` やセミコロン `;` による複合コマンド | LLM classifier detection | `which X; dpkg -l X` |
| `.ssh/`, `/proc/`, `/sys/` 等のセンシティブパス | sensitive path detection | `ls -la ~/.ssh/` |

NG/OK 例を大幅追加（4カテゴリ: `2>&1`、パイプ/セミコロン、`$()`、SSH引数内ダッシュ付き引用符）。

### 6. settings.local.json — 問題エントリ修正

| 操作 | エントリ | 理由 |
|------|---------|------|
| 削除 | `Bash(gh api ... 2>&1 \| python3 ...)` | 複合コマンド+リダイレクト |
| 置換 | `Bash(which gh && gh auth status 2>&1)` → `Bash(gh auth:*)` | 複合コマンド+リダイレクト |
| 置換 | `Bash(/home/ubuntu/.../playwright install:*)` → `Bash(.venv/bin/playwright install:*)` | 絶対パス違反 |

### 7. settings.local.example.json — ライブファイルと同期

`.claude/settings.local.json` の内容で上書き。`diff` で差分なしを確認。

## 検証結果

1. `diff .claude/settings.local.json settings.local.example.json` → 差分なし
2. CLAUDE.md で `許可される.*2>&1` を grep → マッチなし（旧記載が除去されたことを確認）
3. settings.local.json で `2>&1` を grep → マッチなし（問題エントリが除去されたことを確認）
4. 報告された16件の全4カテゴリに対応する NG/OK パターンが CLAUDE.md に記載済み

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `CLAUDE.md` | 5箇所の編集（リダイレクト、パイプ、apt、自動承認リスト、セキュリティチェック） |
| `.claude/settings.local.json` | 3エントリの削除/置換 |
| `settings.local.example.json` | ライブファイルから同期 |

# ISSUE.md — 課題管理ルール

## 概要

pvese プロジェクトの課題追跡・状態管理を行うためのルール。
複数の Claude Code セッションが並行して作業する際の調整基盤として機能する。

### ISSUE と REPORT の関係

| 種別 | 目的 | 保存先 |
|------|------|--------|
| **ISSUE** | 作業の追跡・状態管理 | `issues/issues.yml` |
| **REPORT** | 実験結果・手順の記録 | `report/*.md` |

- 1つの ISSUE に対して 0〜複数の REPORT が紐づく
- ISSUE を `done` にする際、関連する REPORT のパスを `report` フィールドに記録する
- REPORT の作成ルールは [REPORT.md](REPORT.md) を参照

## 状態遷移

```
plan ──start──> active ──verify──> verify ──done──> done
                 │  ^                │                │
              block│ │start       reopen           reopen
                 v  │                v                v
               blocked             active           active
```

| 状態 | 意味 |
|------|------|
| **plan** | 要件整理・設計段階。初期状態。 |
| **active** | スクリプト開発・環境構築・実験実行中 |
| **verify** | 結果確認・レポート作成中 |
| **blocked** | pve-lock 待ち・ハードウェア待ち・依存 issue 待ち |
| **done** | 完了 |

### 許可される遷移

| コマンド | 遷移元 | 遷移先 |
|---------|--------|--------|
| `start` | plan, blocked | active |
| `block` | active | blocked |
| `verify` | active | verify |
| `done` | verify | done |
| `reopen` | done, verify | active |

## 課題フィールド

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `id` | integer | Yes | 自動採番される一意な ID |
| `title` | string | Yes | 課題のタイトル |
| `status` | string | Yes | 状態 (plan/active/verify/blocked/done) |
| `owner` | string | No | 担当セッション名 |
| `created` | string | Yes | 作成日時 (ISO 8601) |
| `updated` | string | Yes | 最終更新日時 (ISO 8601) |
| `blocked_by` | string | No | ブロック理由 |
| `report` | string | No | 関連レポートのパス |
| `labels` | list | No | ラベルのリスト |
| `description` | string | No | 課題の詳細説明 |

## ラベル一覧

| ラベル | 用途 |
|--------|------|
| `ceph` | Ceph ストレージ関連 |
| `gluster` | GlusterFS 関連 |
| `ipmi` | IPMI/BMC 操作関連 |
| `infra` | インフラ・環境構築 |
| `bench` | ベンチマーク・性能測定 |
| `script` | スクリプト開発・改善 |
| `doc` | ドキュメント作成・更新 |

## CLI 操作

```bash
issue.sh list [--status STATUS] [--label LABEL]  # 一覧（デフォルトは done 以外）
issue.sh show <id>                                # 詳細表示
issue.sh add <title> [--label LABEL]...           # 新規作成 (status=plan)
issue.sh edit <id> [--title T] [--desc D] ...     # 編集
issue.sh start <id> [--owner OWNER]               # plan/blocked → active
issue.sh block <id> [REASON]                      # active → blocked
issue.sh verify <id>                              # active → verify
issue.sh done <id> [--report PATH]                # verify → done
issue.sh reopen <id>                              # done/verify → active
```

## Claude Code セッション運用フロー

1. **セッション開始時**: `issue.sh list` で未完了課題を確認
2. **作業開始**: `issue.sh start <id> --owner <session名>` で課題を取得
3. **pve-lock 待ち発生時**: `issue.sh block <id> "pve-lock 待ち"` でブロック状態にし、別の課題に着手
4. **pve-lock 解除後**: `issue.sh start <id>` で再開
5. **作業完了**: `issue.sh verify <id>` → レポート作成 → `issue.sh done <id> --report <path>`

## pve-lock.sh との連携

- `pve-lock.sh run` でロック取得できなかった場合:
  1. 現在の issue を `block` 状態に変更（理由: "pve-lock 待ち"）
  2. `issue.sh list --status plan` で別の作業可能な課題を探す
  3. `pve-lock.sh wait` をバックグラウンドで実行しつつ、別課題を進める
- ロック取得後、元の issue を `start` で再開する

# TX1320 BIOS RAID スキル: サブエージェント画像分析の標準化 + ツール昇格

## Context

`irmc-bios-raid` スキルでは、TX1320 M3 (iRMC S4 FW 9.69F) の AVAGO MegaRAID HII を
Playwright KVM 経由で per-key 操作する。各キー送信後に screenshot を撮り「選択タブ /
カーソル行 / 右ヘルプ / 反転背景 / 黒画有無」を判読してから次キーを決める運用だが、
現状スキルは **主エージェントがインラインで画像を Read する前提**で書かれている
(SKILL.md:434)。2026-06-01 (503d9361) の削除→再作成3サイクル検証で、各 shot を
general-purpose サブエージェントに委任して構造化報告させる方式が「確実 + context 消費を
抑える」と判明し、SKILL.md:455 に **Tips として1行だけ**記載された
(report `2026-06-01_204658_..._3cycle_validation.md` の知見8)。

本タスクは (1) このサブエージェント画像分析を**スキルの標準手順に昇格**し、(2) 同検証で
使われた使い捨てツール群 (`tmp/503d9361/`) を `scripts/` に**正式昇格**する。検証で実際に
機能したのは「永続 KVM セッションサーバ + FW 9.69F cookie ログイン + ナビ/検出エンジン +
復旧フロー」で、これらは既存 `scripts/` に等価物がなく、3サイクル完遂を可能にした中核。
完了後、削除→再作成を2サイクル実機再現して昇格物の動作とサブエージェントフローを検証する。

## ツール依存関係 (調査結果)

```
kvm_server.py ─import→ kvmlib.py ─import→ tmp/iter/_util.py (963行, ナビ/検出エンジン)
                          │
                          └ BMC/USR/PSW ハードコード, sys.path で tmp/iter 参照
```

- `_util.py` (36KB/963行): `open_viewer`以外の全ヘルパー (shot/press/detect_cursor_row/
  detect_active_cursor_row/nav_cursor_to_y/clear_configuration 等 + CURSOR_Y_* 定数)。
  昇格に必須。現在 `tmp/iter/` にあり 503d9361 とは別ディレクトリ。
  **依存検証済**: stdlib (`json/os/re/sys/time`) + `PIL.Image` のみ、`sys.path` は自己参照
  (`os.path.dirname(__file__)`)、ハードコード tmp 出力パスなし (shot 等はパス引数受取) →
  単純コピーで安全。PIL 12.1.1 / playwright とも `.venv` に存在確認済。
  （※実装中に追加発見: `_util.py` はロード時に同階層 `fingerprints.json` を読むため同梱必須）
- `pw.sh`/`snap.sh`: 既存 `bmc-power.sh`/`irmc-oem-screenshot.sh` の薄いラッパー → **昇格不要**
  (レポート判断と一致)。復旧スクリプトからは env-export 直書きで代替。
- `cycle_runner.py`: caret 盲信欠陥 (caret_y=393 を盲信し Enter → NIC 画面誤入) → **昇格対象外**
  (レポート明記)。

## 方針

### Part A: ツール昇格 (scripts/)

新規 Python パッケージディレクトリ `scripts/irmc-kvm/` を作成し、import 連鎖を同一ディレクトリ内で
完結させる (sys.path を `__file__` 基準に修正)。BMC 認証情報は `irmc-kvm-interact.py` と同じ
`--bmc-ip/--bmc-user/--bmc-pass` 引数方式でパラメータ化 (ハードコード除去)。

| 昇格先 (新規) | 元 | 主な変更 |
|---|---|---|
| `scripts/irmc-kvm/_util.py` | `tmp/iter/_util.py` | コピー (ナビ/検出エンジン)。改変最小 |
| `scripts/irmc-kvm/kvmlib.py` | `tmp/503d9361/kvmlib.py` | `sys.path.insert` を `os.path.dirname(__file__)` 基準に / BMC/USR/PSW を引数default化 |
| `scripts/irmc-kvm/server.py` | `tmp/503d9361/kvm_server.py` | argparse 化 (--bmc-ip/user/pass/--srv-dir/--idle-timeout 7200)、gain_control に creds スレッド、sys.path を __file__ 基準 |
| `scripts/irmc-bmc-reset-retry.sh` | `tmp/503d9361/bmc-reset-retry.sh` | creds 引数化、Manager.Reset を "Blocked" でリトライ |
| `scripts/irmc-kvm-recover.sh` | `wait-bmc-boot.sh`+`wait-post-snap.sh`+`killall.sh` 統合 | config 駆動の復旧フロー1スクリプト |

### Part B: SKILL.md 標準手順化

1. 新サブセクション「標準手順: スクリーンショット分析はサブエージェントに委任する」追加 (報告6項目+プロンプト雛形)。
2. 旧 Tips (知見7) を昇格済に書換。
3. ツール参照パス tmp/503d9361 → scripts/ 更新、「昇格済みツールと使い方」節追加。

### Part C: 実機テスト (削除→再作成 2サイクル)

recover → server 起動 → AVAGO ナビ → 削除→再作成 ×2、各段 OEM 真VGA 裏取り、全 shot サブエージェント判読。

### Part D: コミット (テスト成功後)

`scripts/irmc-kvm/` + 2 shell + SKILL.md を1コミット (issue #73)。push しない。

## 検証 (Verification)

- 静的: py_compile / sh -n / server.py --help / import 連鎖ロード。
- 機能: 2サイクル全段 OEM 裏取り成功 (最終 VD0 RAID0 3.272TB Optimal)。

## 注意・リスク

- KVM 操作は長時間。idle timeout / master 喪失時は recover で立て直す。
- RAID10 の HII 自動作成は依然 dead-end。テストはフォーム既定 RAID0。
- `tmp/503d9361/` `tmp/iter/` は昇格後も温存 (コピー元)。

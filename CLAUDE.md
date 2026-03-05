# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 必読ドキュメント

- [REPORT.md](REPORT.md) — レポート作成ルール
- [ISSUE.md](ISSUE.md) — 課題管理ルール

## プロジェクト概要

pvese (Proxmox VE Storage Evaluation) — Supermicro IPMI と Proxmox VE を操作して、分散ストレージ (Ceph, GlusterFS 等) の比較評価を行うプロジェクト。

## 技術スタック

- **言語**: POSIX sh (メイン), Rust (CLIツール)
- **IPMI操作**: ipmitool による Supermicro サーバの電源管理・センサー監視
- **PVE操作**: Proxmox REST API (curl) と CLI (pvesh, qm, pct, pveceph 等) を併用
- **評価対象ストレージ**: Ceph, GlusterFS 等の複数比較

## 環境構成

- Claude Code はローカルマシンから実行し、SSH 経由で PVE ノードを操作する
- IPMI は各サーバの BMC にネットワーク経由でアクセス
- PVE API アクセスにはトークン認証 (`PVEAPIToken=USER@REALM!TOKENID=SECRET`) を使用

## サーバ一覧

| サーバ | BMC IP | 静的 IP | ホスト名 | 設定ファイル |
|--------|--------|---------|----------|-------------|
| 4号機 | `10.10.10.24` | `10.10.10.204` | ayase-web-service-4 | `config/server4.yml` |
| 5号機 | `10.10.10.25` | `10.10.10.205` | ayase-web-service-5 | `config/server5.yml` |
| 6号機 | `10.10.10.26` | `10.10.10.206` | ayase-web-service-6 | `config/server6.yml` |
| 7号機 | `10.10.10.120` (iDRAC) | `10.10.10.207` | ayase-web-service-7 | `config/server7.yml` |

4-6号機共通: ユーザ名 `claude` / パスワード `Claude123` / マザーボード Supermicro X11DPU
7号機: DELL PowerEdge R320 / iDRAC SSH 鍵認証 (`~/.ssh/idrac_rsa`) / Web/IPMI は `claude` / `Claude123` / IPMI LAN 有効化済み / FW 2.65.65.65

接続コマンド例:
```sh
BMC_IP=$(./bin/yq '.bmc_ip' config/server4.yml)
ipmitool -I lanplus -H "$BMC_IP" -U claude -P Claude123 chassis status
```

## ルール

- **全操作をログに記録する**: 状態変更操作は `./oplog.sh` で記録すること（ラボ環境のためユーザ確認は不要）。ログは `log/oplog.log` に蓄積される
- **スクリプトは必ず `./` 付き相対パスで実行する**: 絶対パス (`/home/ubuntu/projects/pvese/scripts/xxx.sh`) や `./` なしのパス (`scripts/xxx.sh`) は許可リストにマッチしないため自動承認されない。必ず `./scripts/xxx.sh`, `./issue.sh`, `./oplog.sh` のように `./` を付けること
- **一時ファイルは `tmp/<session-id>/` に書く。`/tmp/` は使用禁止**: `/tmp/` はプロジェクト外パスのため承認プロンプトが出る。cookie ファイル、一時スクリプト、ログ等すべて `tmp/<session-id>/` に書くこと
- IPMI パスワードや API トークンはスクリプトにハードコードしてよい（ラボ環境）
- `.env` ファイルを使う場合は `.gitignore` に含め、コミットしない
- PVE API 呼び出し時は自己署名証明書に対応するため `curl -k` または `--cacert` を使用する
- スクリプトは `#!/bin/sh` で始め、`set -eu` を冒頭に付ける。bash 固有機能 (`[[ ]]`, 配列, `pipefail` 等) は使用禁止。sh で実現困難な処理は Rust CLIツール (`tools/` ディレクトリ) として実装する
- 関数名・変数名はスネークケース (`snake_case`)
- 設定値 (IPアドレス, ノード名等) はスクリプト先頭またはコンフィグファイルで定義する
- **Bashコマンドに `#` コメント行を含めない**: コメント付きコマンドはパーミッション自動承認が効かないため、コメントは Bash ツールの description パラメータに記載すること
- **マルチラインコマンドを避ける**: 改行区切りの複数コマンドはパーミッション自動承認が効かない。`&&` や `;` で1行にまとめるか、複数の Bash 呼び出しに分割すること。ただし `&&`/`;` チェインもビルトイン安全コマンド以外の異種コマンドの組み合わせでは自動承認されないため、複数 Bash 呼び出しへの分割が最も確実。**パイプ (`|`) も同様にブロックされる**。`zcat X | grep Y | head` や `ls X | tail -1 | xargs ...` は Layer 2 が複合コマンドとして検出しブロックする。調査コマンドであっても `; echo` や `| head` を付けず、個別の Bash 呼び出しに分割すること。パイプが必要な場合はスクリプトファイルに書いて `sh tmp/<session-id>/script.sh` で実行する
- **セッション用 tmp ディレクトリ**: セッション開始時に `mkdir -p tmp/<session-id>` でセッション固有の一時ディレクトリを作成する。`<session-id>` は Claude Code のセッション UUID の先頭8文字を使う（例: セッションの transcript パスが `.../<uuid>.jsonl` なら、その UUID の先頭8文字）。一時ファイル（スクリプト、コミットメッセージ等）はすべてここに書く。`/tmp/` への Write はプロジェクト外のため承認プロンプトが出る
- **複雑なスクリプトはファイルに書いてから実行する**: 環境変数の設定、ヒアドキュメント、複数行ロジックを含むコマンドや、書き捨ての Python スクリプトは Bash ツールにインラインで渡さず、Write ツールで `tmp/<session-id>/` にファイルとして保存してから `python3 tmp/<session-id>/script.py` や `sh tmp/<session-id>/script.sh` で実行すること。インラインの複雑なコマンドはパーミッション許可リストにマッチしない
- **シェルリダイレクトを使わない**: 出力リダイレクト (`>`, `2>`) だけでなく、**入力リダイレクト (`<`) もパーミッション自動承認が効かない**。`ssh ... "sh -s" < file` のようなコマンドも承認プロンプトが出る。Bash ツールは stdout と stderr を両方キャプチャするため、`2>/dev/null` や `2>&1` は原則不要。これらを付けると Layer 2 LLM クラシファイアにブロックされることがある。`ssh` 引数内の `2>&1` は確実にブロックされる。どうしても stderr を抑制する必要がある場合のみ `2>/dev/null` をローカルコマンド単体で使ってよい
- **ファイル内容の読み取りに Bash を使わない**: `cat`, `head`, `tail`, `for file in ... cat` 等でファイルを読むのは禁止。Read ツールや Glob ツールを使うこと。複数ファイルをまとめて読みたい場合は Glob で一覧を取得してから Read で各ファイルを読む
- **パーミッション設定の優先順位**: プロジェクト `settings.local.json` に `permissions.allow` がある場合、グローバル `settings.local.json` の `permissions.allow` は置換される（マージされない）。プロジェクト設定には必要なグローバルパターンも含めること
- **ツールのパスに `~` を使わない**: Read, Glob, Grep 等のツールは `~` をシェル展開しない。`~/projects/...` ではなく `/home/ubuntu/projects/...` のように絶対パスを使うこと
- **レポート作成**: plan mode を使用してまとまった作業を行った場合は、完了時にレポートを作成すること。フォーマットは [REPORT.md](REPORT.md) に従う。レポートは常に `/home/ubuntu/projects/pvese/report/` に作成する
- **ツールのインストール**: コマンドラインツールは sudo を使わずにプロジェクトローカル (`bin/`) にインストールしてよい（ユーザ確認不要）。スクリプトからの呼び出しは `${SCRIPT_DIR}/bin/yq` のようにフルパスで行う。apt パッケージは `sudo apt install -y <pkg>` で直接インストールできる（`Bash(sudo apt:*)` は許可リストに含まれている）。ただし `2>&1` は付けないこと
- **課題管理**: 作業は `issue.sh` で課題として追跡する。セッション開始時に `issue.sh list` で未完了課題を確認し、作業中の課題は `issue.sh start <id> --owner <session名>` で取得する。状態遷移ルールは [ISSUE.md](ISSUE.md) を参照
- **BMC ファクトリーリセット禁止**: `ipmitool raw 0x3c 0x40` 等の BMC リセットコマンドは実行禁止。BMC 全ユーザ・ネットワーク設定が消失する。リセットが必要な場合はコマンドをユーザに提示し手動実行を依頼すること
- **`git push` は自動許可しない**: パーミッション許可リストに `git push` は含めない。push が必要な場合はユーザに確認を求めること
- **通しテストはユーザの明確な指示で実行する**: `scripts/` 配下のセットアップスクリプトを修正した場合でも、通しテスト（`os-setup` スキル）は自動的に実行しない。ユーザが明確に通しテストを指示した場合のみ実行すること
- **SSH は静的 IP (`10.10.10.0/8`) を使う**: `192.168.39.0/24` (DHCP) 側の IP に SSH しないこと。DHCP アドレスは OS 再インストールで変動するため、SSH・scp・PVE API 等のリモート接続はすべて設定ファイルの `static_ip` を使用する

## パーミッション許可リストとコマンド実行

`.claude/settings.local.json` の `permissions.allow` にはプレフィックスマッチングで自動承認されるコマンドパターンが定義されている。コマンドが自動承認されるためには、以下の規則に従うこと。

### マッチングルール

- `Bash(X:*)` はコマンド文字列が `X` で**始まる**場合にマッチする
- 例: `Bash(git status:*)` は `git status`, `git status --short`, `git status -sb` すべてにマッチ
- 例: `Bash(./scripts/:*)` は `./scripts/bmc-power.sh status`, `./scripts/generate-preseed.sh` 等すべてにマッチ

### スクリプトのパス規則

プロジェクトスクリプトは常に `./` 付きの相対パスで実行すること:

| スクリプト | 実行例 |
|-----------|--------|
| ルートスクリプト | `./issue.sh list`, `./oplog.sh curl ...`, `./pve-lock.sh run ...` |
| scripts/ 配下 | `./scripts/bmc-power.sh status`, `./scripts/generate-preseed.sh` |
| bin/ 配下 | `./bin/yq .bmc_ip config.yml` |

`scripts/xxx.sh`（`./` なし）や絶対パスは許可リストにないため自動承認されない。

> **注意**: 絶対パスは最もよくある間違い。特に引数に渡すファイルパスも `tmp/<session-id>/` を使うこと。

```sh
# NG: 絶対パスでスクリプトを実行（自動承認されない）
/home/ubuntu/projects/pvese/scripts/bmc-virtualmedia.sh status 10.10.10.25 /tmp/bmc-cookie 'token'

# NG: ./ なしで実行（自動承認されない）
scripts/bmc-virtualmedia.sh status 10.10.10.25 /tmp/bmc-cookie 'token'

# OK: ./ 付き相対パス + tmp/<session-id>/ を使用
./scripts/bmc-virtualmedia.sh status 10.10.10.25 tmp/a1b2c3d4/bmc-cookie 'token'
```

### 複雑なコマンドはファイルに書いて実行する

環境変数の設定、パイプライン、`&&` チェイン、ヒアドキュメント等を含む複雑なコマンドは許可リストにマッチしないことが多い。Write ツールで `tmp/<session-id>/` にファイルとして保存し、`sh tmp/<session-id>/script.sh` や `python3 tmp/<session-id>/script.py` で実行すること（`Bash(sh:*)` と `Bash(python3:*)` は許可リストに含まれている）。

```sh
# NG: インラインの複雑なコマンド（自動承認されない）
CSRF="xxx" && ./scripts/bmc-virtualmedia.sh mount ...

# OK: ファイルに書いてから実行
Write tmp/<session-id>/mount.sh → sh tmp/<session-id>/mount.sh

# NG: stdin リダイレクトで SSH にスクリプトを流し込む（自動承認されない）
ssh root@10.10.10.204 "sh -s" < tmp/<session-id>/script.sh

# OK: リダイレクトごとラッパースクリプトに書く
# tmp/<session-id>/run-remote.sh の内容:
#   ssh root@10.10.10.204 "sh -s" < tmp/<session-id>/script.sh
sh tmp/<session-id>/run-remote.sh

# OK: scp + ssh に分解する（リダイレクト不要）
scp tmp/<session-id>/script.sh root@10.10.10.204:/tmp/script.sh
ssh root@10.10.10.204 "sh /tmp/script.sh"
```

### 自動承認されないコマンド（手動承認が必要）

- `git push` (全サブコマンド)
- `./` なしのスクリプトパス (`scripts/xxx.sh`, `bin/xxx`)
- 絶対パスのスクリプト (`/home/ubuntu/projects/pvese/scripts/xxx.sh`)
- `&&` や `;` で繋いだ異種コマンドチェイン（安全コマンド以外の組み合わせでは自動承認されない場合がある）
- `sudo` (iptables, apt 以外)
- `git -C <path>` (`git -C /path status` → `Bash(git -C` で始まり `Bash(git status:*)` にマッチしない。`cd /path && git status` をファイルに書いて `sh tmp/<session-id>/script.sh` で実行するか、プロジェクトルートから直接実行すること)
- `git commit -m "$(cat <<'EOF'...)"` (HEREDOC はマルチラインコマンドになり自動承認されない。代わりに Write ツールで `tmp/<session-id>/commit-msg.txt` にメッセージを書き、`git commit -F tmp/<session-id>/commit-msg.txt` で実行すること)
- `<` 入力リダイレクト (`ssh ... "sh -s" < file` — `<` はシェル演算子のため自動承認不可。ラッパースクリプトに書くか `scp` + `ssh` に分解する)
- `2>&1` 付きコマンド (Bash ツールでは不要なため常に省略すること)
- パイプ `|`・セミコロン `;` の複合コマンド (個別 Bash 呼び出しに分割)
- `$()` コマンド置換 (スクリプトファイル経由で実行)
- `.ssh/`, `/proc/` 等のセンシティブパスへのアクセス (Read ツール使用を推奨)
- Write ツールでの `/tmp/` への書き込み (プロジェクト外パスは承認が必要。代わりに `tmp/<session-id>/` を使うこと)

### 組み込みセキュリティチェック（allow リストとは別）

`permissions.allow` にマッチしても、コマンド引数に以下のパターンが含まれると Claude Code の組み込みチェックにより承認プロンプトが出る:

| 検出パターン | 理由メッセージ | 典型例 |
|-------------|--------------|--------|
| 引用符の直後にダッシュ (`"- - -"`, `-- '-i4'`) | "empty quotes before dash" | SCSI rescan, CLI の `--` separator |
| 引数内の `&`, `;`, `\|` | "shell metacharacters in arguments" | SSH 引数内の `2>&1` |
| 引数内の `$(...)` | "$() command substitution" | SSH 引数内のコマンド置換 |
| コマンド末尾の `2>&1`, `2>/dev/null` | LLM classifier detection | `ls /path 2>&1`, `.venv/bin/python script.py 2>&1` |
| パイプ `\|` やセミコロン `;` による複合コマンド | LLM classifier detection | `which X; dpkg -l X`, `zcat X \| grep Y` |
| `.ssh/`, `/proc/`, `/sys/` 等のセンシティブパス | sensitive path detection | `ls -la /home/ubuntu/.ssh/`, `cat /proc/net/udp` |

**対策**: SSH 経由のリモートコマンドでこれらのパターンが必要な場合は、リモート側で実行するスクリプトを `scp` で転送してから `ssh` で実行する:

```sh
# NG: 引数内の特殊パターンでブロックされる
ssh root@10.10.10.204 'echo "- - -" > /sys/class/scsi_host/host9/scan'
ssh root@10.10.10.204 "linstor ... -- '-i4 -I64'"
ssh root@10.10.10.204 "dd ... 2>&1"
ssh root@10.10.10.204 "for d in sda sdb; do echo $(cat /sys/block/$d/...); done"

# OK: scp + ssh に分解する
# 1. Write ツールで tmp/<session-id>/remote-cmd.sh にスクリプトを書く
# 2. scp でリモートに転送
scp tmp/<session-id>/remote-cmd.sh root@10.10.10.204:/tmp/remote-cmd.sh
# 3. ssh で実行
ssh root@10.10.10.204 "sh /tmp/remote-cmd.sh"

# NG: 不要な 2>&1 でブロック
.venv/bin/playwright --version 2>&1
sudo apt install -y tftpd-hpa 2>&1
cat /proc/net/udp 2>&1

# OK: 2>&1 を外す（Bash ツールが stderr を自動キャプチャ）
.venv/bin/playwright --version
sudo apt install -y tftpd-hpa
cat /proc/net/udp

# NG: パイプ/セミコロンの複合コマンド
ls docs/; echo "---"; ls scripts/*.sh | head -20
which in.tftpd 2>&1; dpkg -l tftpd-hpa 2>&1 | tail -3
zcat /tmp/catalog.xml.gz | grep -i "keyword" | head -20

# OK: 別々の Bash 呼び出しに分割
# (1回目) ls docs/
# (2回目) ls scripts/*.sh
# (3回目) which in.tftpd
# (4回目) dpkg -l tftpd-hpa
# パイプが必要 → sh tmp/<session-id>/search.sh

# NG: $() コマンド置換
docker run -v "$(pwd)"/tmp/file:/mount:ro image

# OK: スクリプトファイルに書く
# tmp/<session-id>/docker-run.sh:
#   docker run -v "$(pwd)"/tmp/file:/mount:ro image
sh tmp/<session-id>/docker-run.sh

# NG: SSH 引数内のダッシュ付き引用符
ssh root@10.10.10.204 'python3 /tmp/script.py show-ports'

# OK: 引用符を外す (単純なコマンドの場合)
ssh root@10.10.10.204 python3 /tmp/script.py show-ports
# OK: scp + ssh パターン (複雑なコマンドの場合)
scp tmp/<session-id>/cmd.sh root@10.10.10.204:/tmp/cmd.sh
ssh root@10.10.10.204 sh /tmp/cmd.sh
```

### settings.local.json の管理

`.claude/settings.local.json` はグローバル gitignore で除外されているため git に含まれない。許可リストを更新した場合は、コピーをコミットして変更を追跡すること:

1. `.claude/settings.local.json` を更新
2. `settings.local.example.json` (プロジェクトルート) にコピー
3. example ファイルをコミット

## 操作ログ

状態変更操作は `./oplog.sh` で記録する:

```sh
./oplog.sh <command...>    # コマンド実行 + ログ記録
```

記録フォーマット: `タイムスタンプ | rc=終了コード | 実行秒数 | コマンド`

ログファイル: `log/oplog.log`

`pve-lock.sh` と組み合わせる場合:
```sh
./pve-lock.sh run ./oplog.sh pvesh create /nodes/pve1/qemu ...
```

## Rust CLIツール

sh で実現困難な処理は `tools/` ディレクトリに Rust CLI ツールとして実装する:

```
tools/
  Cargo.toml          # workspace root
  <crate-name>/       # 個別ツール (必要に応じて追加)
```

ビルド: `cd tools && cargo build --release`

新規ツール追加手順:
1. `cargo new --name <name> tools/<name>`
2. `tools/Cargo.toml` の `members` に追加
3. `cargo build --release` で確認

## PVE/IPMI ロック

PVE クラスタやサーバの状態に影響する操作は排他制御を通して実行すること:

```bash
pve-lock.sh status                           # ロック状態確認
pve-lock.sh run <command...>                 # 即座に実行 (ロック中ならエラー)
pve-lock.sh wait [--timeout N] <command...>  # ロック待ち→実行
```

> **重要**: PVE クラスタ操作やIPMI操作のうち状態変更を伴うものは**直接実行しないこと**。
> 必ず `pve-lock.sh run` または `pve-lock.sh wait` で包んで実行する。
> 直接実行すると他セッションの操作と競合し、クラスタ状態が不整合になる可能性がある。

### ロック必須の操作

| カテゴリ | 実行方法 | 理由 |
|---------|---------|------|
| **VM/CT 作成・削除・移行** | `pve-lock.sh run pvesh ...` | クラスタリソース競合 |
| **ストレージ作成・破棄** | `pve-lock.sh run pveceph ...` / `pve-lock.sh run pvesh ...` | ストレージ構成変更 |
| **ノード電源操作** | `pve-lock.sh run ipmitool ... power on/off/reset` | クラスタメンバーシップに影響 |
| **Ceph OSD 追加・削除** | `pve-lock.sh run ceph osd ...` | データ再配置が発生 |
| **ネットワーク設定変更** | `pve-lock.sh run pvesh set /nodes/.../network/...` | クラスタ通信に影響 |

### ロック不要の操作

| 操作 | 理由 |
|------|------|
| `pvesh get ...` (読み取りクエリ全般) | 状態変更なし |
| `ipmitool ... sensor list`, `ipmitool ... sdr` | センサー読み取りのみ |
| `ceph status`, `ceph osd tree`, `ceph df` | 読み取り専用 |
| `qm status`, `pct status` | VM/CT 状態確認のみ |

- ロック中なら現在の issue を `issue.sh block <id> "pve-lock 待ち"` でブロックし、別の課題（`issue.sh list --status plan`）に着手すること
- バックグラウンド実行パターン: `Bash(run_in_background=true)` + `pve-lock.sh wait` でロック待ちの間に別作業を進められる
- ロック取得後、元の issue を `issue.sh start <id>` で再開する

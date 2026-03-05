---
name: idrac7-fw-update
description: "iDRAC7 ファームウェアアップデート。段階的アップグレードパスに従い TFTP 経由で適用する。"
argument-hint: "<target: 1.66|2.20|2.65|all>"
---

# iDRAC7 FW Update スキル

iDRAC7 ファームウェアを段階的アップグレードパスに従い TFTP 経由で適用する。

## 概要

| 項目 | 値 |
|------|-----|
| 対象 | 7号機 (DELL PowerEdge R320) iDRAC7 |
| 方式 | TFTP 経由 (`racadm fwupdate -g -u -a <IP>`) |
| 前提スキル | [idrac7](../idrac7/SKILL.md), [dell-fw-download](../dell-fw-download/SKILL.md), [tftp-server](../tftp-server/SKILL.md) |

## アップグレードパス

iDRAC7 は直接最新版にジャンプできない。以下の段階的パスに従う:

| ステップ | From | To | Driver ID | 所要時間 (概算) |
|---------|------|-----|-----------|---------------|
| 1 | 1.57.57 | 1.66.65 | 992WY | ~5 分 |
| 2 | 1.66.65 | 2.20.20.20 | 4P5PF | ~7 分 |
| 3 | 2.20.20.20 | 2.65.65.65 | Y9YPN | ~8 分 |

`target` 引数で到達バージョンを指定:
- `1.66`: ステップ 1 のみ
- `2.20`: ステップ 1-2
- `2.65`: ステップ 1-3 (最新)
- `all`: 現在のバージョンから最新まで全ステップ

## フェーズ

各ステップは以下の 6 フェーズで構成される:

### Phase 1: FW ダウンロード

dell-fw-download スキルを使用:

```sh
.venv/bin/python tmp/<session-id>/dell-download.py <DRIVER-ID> tmp/<session-id>
```

### Phase 2: BIN 展開

```sh
python3 tmp/<session-id>/extract-bin.py tmp/<session-id>/<BIN-file> tmp/<session-id>/fw-extracted
chmod 644 tmp/<session-id>/fw-extracted/payload/firmimg.d7
```

### Phase 3: TFTP サーバ起動

tftp-server スキルを使用。起動コマンドはスクリプトファイルに書いて実行:

`tmp/<session-id>/start-tftp.sh`:
```sh
docker stop tftp-server 2>/dev/null || true
docker run --rm -d --name tftp-server \
    -p 69:69/udp \
    -v "$(pwd)/tmp/<session-id>/fw-extracted/payload/firmimg.d7:/tftpboot/firmimg.d7:ro" \
    jumanjiman/tftp-hpa
```

```sh
sh tmp/<session-id>/start-tftp.sh
```

### Phase 4: FW 適用

```sh
./oplog.sh ssh idrac7 racadm fwupdate -g -u -a <TFTP-SERVER-IP>
```

- `<TFTP-SERVER-IP>`: ローカルマシンの IP (iDRAC から到達可能なアドレス。例: `10.1.6.1`)
- `-d` オプションは省略 (TFTP ルート直下の `firmimg.d7` を自動取得)

適用中の出力:
```
Firmware update completed successfully.
```

### Phase 5: 接続回復確認

FW 適用後、iDRAC が自動リブートする。SSH 再接続まで 60-120 秒:

1. SSH ホスト鍵削除: `ssh-keygen -R 10.10.10.120`
2. SSH 接続確認 (30 秒間隔でリトライ):
   ```sh
   ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no idrac7 racadm getsysinfo
   ```
3. FW バージョン確認: 期待バージョンと一致することを確認

### Phase 6: クリーンアップ

```sh
docker stop tftp-server
```

次のステップがある場合は Phase 1 に戻る。最終ステップの場合は展開ファイルも削除:
```sh
rm -rf tmp/<session-id>/fw-extracted
```

## 既知の失敗パターン

### F1: TFTP "Remote host is not reachable"

iDRAC から TFTP サーバに到達できない。確認事項:
1. iDRAC からローカルマシンへの ping: `ssh idrac7 racadm ping <TFTP-IP>`
2. ファイルパーミッション: `chmod 644 firmimg.d7` (tftp-server スキル参照)
3. Docker コンテナが起動しているか: `docker ps`
4. UDP 69 がリッスンされているか

### F2: FW アップデートジョブのスタック

`racadm fwupdate -s` で "Preparing for firmware update" のまま停滞。
`racadm racreset` も拒否される場合:

1. IPMI LAN を有効化:
   ```sh
   ssh idrac7 racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1
   ```
2. ipmitool でコールドリセット:
   ```sh
   ipmitool -I lanplus -H 10.10.10.120 -U claude -P Claude123 mc reset cold
   ```
3. 120 秒待機後に SSH 再接続

### F3: `-d firmimg.d7` エラー

`-d` はディレクトリパス指定オプション。ファイル名として解釈されない。**`-d` オプションは常に省略**する。

### F4: Dell BIN ダウンロード 403

curl では Akamai CDN がボット検知で 403 を返す。Playwright 経由でダウンロードすること (dell-fw-download スキル参照)。

### F5: SSH ホスト鍵不一致

FW アップデート後に iDRAC の SSH ホスト鍵が変わる。アップデート前に毎回:
```sh
ssh-keygen -R 10.10.10.120
```

## 最終検証

全ステップ完了後:

```sh
ssh idrac7 racadm getsysinfo
ssh idrac7 racadm getconfig -g cfgIpmiLan
ssh idrac7 racadm jobqueue view
```

確認項目:
- Firmware Version = 期待バージョン
- cfgIpmiLanEnable = 1
- ジョブキューが空

## 参照

- [idrac7 スキル](../idrac7/SKILL.md) — SSH/racadm 基本操作
- [dell-fw-download スキル](../dell-fw-download/SKILL.md) — FW ダウンロード + BIN 展開
- [tftp-server スキル](../tftp-server/SKILL.md) — TFTP サーバ起動
- [playwright スキル](../playwright/SKILL.md) — Playwright セットアップ
- [iDRAC7 FW アップグレードレポート](../../../report/2026-03-02_143000_idrac7_firmware_upgrade.md)

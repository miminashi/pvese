---
name: tftp-server
description: "Docker TFTP サーバ。jumanjiman/tftp-hpa コンテナで一時的な TFTP サービスを提供する。"
argument-hint: "<subcommand: start|stop|test|status> <file>"
---

# TFTP Server スキル

Docker コンテナで一時的な TFTP サーバを起動する。

## 概要

| 項目 | 値 |
|------|-----|
| コンテナイメージ | `jumanjiman/tftp-hpa` |
| プロトコル | UDP 69 |
| TFTP ルート | コンテナ内 `/tftpboot/` |
| 用途 | iDRAC FW アップデート (firmimg.d7 配信) |

## 起動コマンド

```sh
docker run --rm -d --name tftp-server \
    -p 69:69/udp \
    -v /path/to/firmimg.d7:/tftpboot/firmimg.d7:ro \
    jumanjiman/tftp-hpa
```

- `--rm`: 停止時にコンテナ自動削除
- `-d`: バックグラウンド実行
- `-p 69:69/udp`: ホストの UDP 69 をコンテナに転送
- `-v ...:/tftpboot/...:ro`: ファイルをコンテナ内の TFTP ルートにマウント

## ファイルパーミッション要件

**TFTP で配信するファイルは 644 (全ユーザ読み取り可) が必須**。

```sh
chmod 644 /path/to/firmimg.d7
```

tftpd-hpa は `File must have global read permissions` エラーを返し、600 (owner のみ) のファイルは配信できない。

## 動作確認

### Python UDP テスト

TFTP RRQ パケットを送信し、DATA 応答を確認する:

```python
import socket
import struct

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(5)

filename = b"firmimg.d7"
mode = b"octet"
rrq = struct.pack("!H", 1) + filename + b"\x00" + mode + b"\x00"

sock.sendto(rrq, ("127.0.0.1", 69))
data, addr = sock.recvfrom(1024)

opcode = struct.unpack("!H", data[:2])[0]
if opcode == 3:
    print("OK: TFTP DATA received")
elif opcode == 5:
    errmsg = data[4:].decode(errors="replace").rstrip("\x00")
    print(f"ERROR: {errmsg}")
sock.close()
```

- opcode 3 = DATA (成功)
- opcode 5 = ERROR

テストスクリプトは `tmp/<session-id>/tftp-test.py` に書いて `python3 tmp/<session-id>/tftp-test.py` で実行する。

### docker logs 確認

```sh
docker logs tftp-server
```

## ファイル差し替え

FW ファイルを差し替える場合はコンテナを再起動する:

```sh
docker stop tftp-server
docker run --rm -d --name tftp-server \
    -p 69:69/udp \
    -v /path/to/new-firmimg.d7:/tftpboot/firmimg.d7:ro \
    jumanjiman/tftp-hpa
```

## 停止

```sh
docker stop tftp-server
```

`--rm` フラグにより停止時にコンテナが自動削除される。

## 注意事項

- **UDP ポート 69**: 他のプロセスが使用中でないことを確認。`sudo ss -ulnp sport = :69` でチェック
- **ファイアウォール**: iptables/nftables で UDP 69 が許可されていること。ラボ環境ではデフォルトで開放済み
- **iDRAC からの接続**: iDRAC → ローカルマシンの IP (10.1.6.1 等) に TFTP で接続する。iDRAC から ping 確認してから使用すること

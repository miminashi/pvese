# tx1320 PVE: Web UI + API アクセスを 192.168.33.0/24 に制限

## Context (背景・目的)

現在セットアップ済みの training-tx1320 (Fujitsu PRIMERGY TX1320 M3) の PVE で、
PVE 管理画面 (Web UI) および REST API へのアクセスを **192.168.33.0/24 ネットワークからのみ**
許可し、それ以外 (特に claude が現在使っている 10.254.254.0/24 dark-net) からは遮断したい。
**SSH (ポート 22) はそのまま開けておく** (管理・復旧経路として残す)。

### 前提となる事実 (調査結果)

- PVE の **Web UI と REST API は同一の `pveproxy` (TCP 8006)** で提供される。
  → 8006 を絞れば Web UI と API の両方が同時に制限される。
- `pveproxy` は現在 `0.0.0.0:8006` で全インターフェース listen。
- tx1320 の NIC 構成:
  - **eno1 = 192.168.33.x** (サイト LAN、OpenWrt NAT 背後。claude からは不達)
  - **eno2 = 10.254.254.x** (dark-net、claude が SSH/Web で到達している経路。MAC `4c:52:62:14:de:f0`)
- SSH (22) は pveproxy とは別系統なので、pveproxy 制限の影響を受けない。
- リポジトリには既存のファイアウォール / pveproxy アクセス制限の仕組みは無い。

### ユーザ確定事項

- 対象: Web UI + API (= pveproxy 8006)。SSH は開けたまま。
- 適用範囲: **現ホストのみ** (リポジトリのセットアップスクリプトには組み込まない)。
- 許可元: **127.0.0.1 (loopback) + 192.168.33.0/24**。それ以外は全拒否。

## アプローチ

PVE firewall や iptables ではなく、**`/etc/default/pveproxy` の `ALLOW_FROM` / `DENY_FROM` / `POLICY`**
を使う (PVE 公式のアクセス制限機構)。pveproxy にのみ作用するため SSH を巻き込まず、
万一の設定ミスでも SSH で即復旧できる最も低リスクな方法。

設定内容 (PVE 公式の「特定ネットワークのみ許可」パターン):

```
ALLOW_FROM="127.0.0.1,192.168.33.0/24"
DENY_FROM="all"
POLICY="allow"
```

セマンティクス: `POLICY="allow"` の下では `DENY_FROM` (=all) で全拒否しつつ
`ALLOW_FROM` に一致するものを許可 (ALLOW が DENY に優先)。
結果 → 127.0.0.1 と 192.168.33.0/24 のみ許可、それ以外は 403 Forbidden。

> 注: 内部通信は `pvedaemon` (localhost:85) 経由で、pveproxy 8006 を介さないため、
> この制限で PVE 本体機能は壊れない。loopback 許可によりホスト自身からの 8006 アクセスも温存。

## 実装手順 (現ホストへの適用のみ)

すべて SSH 経由でリモートホスト上に適用する。コードはリポジトリにコミットしない。

1. **現在の eno2 IP を特定** (DHCP で変動するため MAC で再発見)
   - ローカルで 10.254.254.0/24 を ping-sweep し `ip neigh | grep 4c:52:62:14:de:f0` で IP 取得
   - `ssh -F ssh/config root@<ip> true` で到達確認
2. **現状確認** (適用前のベースライン記録)
   - `ssh root@<ip> cat /etc/default/pveproxy` (既存内容バックアップ目的)
   - `ssh root@<ip> ip -4 addr show eno1` で eno1 の 192.168.33.x 実アドレス確認 (positive test 用)
   - claude 側から `curl -sk -o /dev/null -w '%{http_code}' https://<ip>:8006` → 現状 200 を確認
3. **設定適用** (`tmp/<session-id>/` にリモート実行スクリプトを作成 → scp → ssh 実行)
   - `/etc/default/pveproxy` を `/etc/default/pveproxy.bak.<日付>` にバックアップ
   - 上記 3 行 (`ALLOW_FROM` / `DENY_FROM` / `POLICY`) を書き込む
     (既存の同名キーがあれば置換、無ければ追記。冪等になるよう設計)
   - `systemctl restart pveproxy`
   - `systemctl is-active pveproxy` で稼働確認
   - すべて `./oplog.sh` 経由で実行しログ記録

### 変更対象ファイル (リモートホスト上)

- `/etc/default/pveproxy` (tx1320 上。リポジトリ内ファイルは変更しない)

リポジトリ内のスクリプト/設定の変更は **無し** (ユーザ指定: 現ホストのみ)。

## 検証 (Verification)

適用後、以下を確認する:

1. **遮断確認 (negative test)** — claude 側 (10.254.254.x) から:
   - `curl -sk -o /dev/null -w '%{http_code}' https://<eno2-ip>:8006/` → **拒否応答 (403 等の 200 以外)** を期待 (Web UI 遮断)
   - `curl -sk -o /dev/null -w '%{http_code}' https://<eno2-ip>:8006/api2/json/version` → **拒否応答 (200 以外)** を期待 (API 遮断)
   - 適用前の 200 → 適用後の拒否、という変化が遮断成立の本質的な証拠。
2. **許可確認 (positive test)** — ホスト上で SSH 経由実行:
   - `curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8006/` → **200** を期待 (loopback 許可)
   - eno1 に 192.168.33.x が付与されている場合のみ:
     `curl -sk -o /dev/null -w '%{http_code}' https://192.168.33.x:8006/` (eno1 の IP に接続 → source=192.168.33.x) → **200** を期待。
     付与されていなければこの test はスキップし、loopback 200 + negative test の遮断成立をもって判定する。
3. **SSH 疎通維持確認** — claude 側から `ssh -F ssh/config root@<eno2-ip> true` が成功 (SSH は遮断されていない)
4. **pveproxy 稼働確認** — `systemctl is-active pveproxy` = active

### 復旧手順 (もし問題が起きたら)

SSH は生きているので、`/etc/default/pveproxy.bak.<日付>` を書き戻して
`systemctl restart pveproxy` で即座に元に戻せる。

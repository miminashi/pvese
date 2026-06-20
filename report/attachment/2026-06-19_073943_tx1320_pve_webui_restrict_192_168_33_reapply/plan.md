# tx1320 PVE Web UI + API アクセスを 192.168.33.0/24 + loopback に制限 (再適用)

## Context

2026-06-14 のレポート ([report/2026-06-14_022710_tx1320_pve_webui_restrict_192_168_33.md](../../projects/pvese/report/2026-06-14_022710_tx1320_pve_webui_restrict_192_168_33.md))
で実施したのと同じ pveproxy アクセス制限を、現在の training-tx1320 ホストに**再度**適用する。

なぜ再適用が必要か: ホストは 2026-06-19 にブリッジ構成 (vmbr0=eno1 LAN / vmbr1=eno2 dark-net 固定
10.1.4.16) で **RAID 初期化からフルセットアップし直された** ([report/2026-06-19_...bridge...md](../../projects/pvese/report/2026-06-19_045707_tx1320_pve_bridge_vmbr0_lan_vmbr1_darknet.md))。
再インストールで `/etc/default/pveproxy` はリセットされ、現在は未存在 = アクセス制限なしの状態。

要件 (ユーザ確定):
- PVE Web UI + REST API (= pveproxy TCP 8006) を **127.0.0.1 (loopback) + 192.168.33.0/24** のみ許可
- それ以外 (dark-net 10.0.0.0/8 / 10.1.4.16 含む) は遮断
- SSH (22) は維持 (pveproxy と別系統なので影響なし = 復旧経路)
- 機構は `/etc/default/pveproxy` の ALLOW_FROM/DENY_FROM/POLICY (PVE 公式機構、firewall/iptables は使わない)
- 適用範囲は**現ホストのみ**。リポジトリのスクリプト/設定は変更しない。冪等に。

## 現状確認結果 (read-only、本セッションで実機取得済 — 推測なし)

| 項目 | 値 |
|------|-----|
| 到達経路 | `ssh -F ssh/config training-tx1320` (= root@10.1.4.16) ※ping 84ms OK |
| vmbr0 | `192.168.33.11/24` (LAN, DHCP, OpenWrt NAT 背後 — claude からは不達) |
| vmbr1 | `10.1.4.16/8` (dark-net, static — **claude が到達している経路**) |
| `/etc/default/pveproxy` | **未存在** (制限なし。新規作成する) |
| pveproxy listen | `*:8006` dual-stack (IPv4+IPv6) |
| pveproxy | active / PVE 9.2.3 |
| **pve-firewall** | **disabled** (= 8006 を絞る別機構は存在しない) |
| iptables 8006 | ルールなし |
| ベースライン (claude→web / api) | **200 / 401** (= 現状未制限・到達可) |
| ベースライン (ホスト自己 lo / vmbr0 / vmbr1) | **200 / 200 / 200** (= 全ソース未制限) |

→ (1) の検証: `/etc/default/pveproxy` 不在・pve-firewall disabled・iptables ルールなし・listen `*:8006` を
すべて ssh で確認済。**現状は確実に「未制限」**で、8006 を絞る他機構は存在しない。

前回 (10.254.254.16) との唯一の差分: claude 到達 IP が固定 **10.1.4.16** になった点。
許可元 (192.168.33.0/24 + 127.0.0.1) は同一なので適用内容は前回と完全に同じ。

### (2) ブリッジ構成下で 192.168.33.0/24 制限が意図どおり効く根拠 (実機裏取り)
- pveproxy はユーザ空間プロキシで `*:8006` を bind し、**TCP peer (source) IP を素で参照**する。
  PVE ホスト上で incoming に NAT は介在しない (ブリッジは L2) ため source IP は保存される。
- claude → 10.1.4.16 の source IP は claude ホスト (`10.1.x`) で **192.168.33.0/24 外** → 適用後は遮断。
- ホスト自身が `192.168.33.11` を curl すると source=`192.168.33.11` (許可レンジ内) で現状 200 を確認
  → 適用後も 200 を維持できる。site LAN クライアント (192.168.33.x) も同様に許可される。
- ⚠️ **帰結 (要件どおり)**: 適用後は **claude 自身も web UI / REST API を失い、SSH (22) のみ残る**。
  これは仕様 (許可元を 192.168.33.0/24 + loopback に限定) の意図的な結果。復旧は SSH 経由で可能。

## 実施手順 (現ホストのみ、冪等)

1. **適用前ベースライン取得**: claude 経路から現状の応答を記録
   ```sh
   curl -sk -o /dev/null -w '%{http_code}\n' https://10.1.4.16:8006/                 # 期待 200 (制限前)
   curl -sk -o /dev/null -w '%{http_code}\n' https://10.1.4.16:8006/api2/json/version # 期待 401 (到達=認証要求)
   ```

2. **`/etc/default/pveproxy` を冪等に設定** (現ホスト上)。目標は以下 3 行が**各キー 1 つだけ**存在する状態:
   ```
   ALLOW_FROM="127.0.0.1,192.168.33.0/24"
   DENY_FROM="all"
   POLICY="allow"
   ```
   - `POLICY="allow"` 下で `DENY_FROM="all"` が全拒否、`ALLOW_FROM` 一致のみ許可 (ALLOW が DENY に優先)。
   - **(3) 冪等性の精密化** — 単純な追記だと再実行でキーが重複する。以下の手順で 3 キー全てに漏れなく効かせる:
     1. 既存ファイル (無ければ空) から **3 キーを一括除去**: `grep` でアンカー正規表現
        `^[[:space:]]*(ALLOW_FROM|DENY_FROM|POLICY)=` に**マッチしない**行だけを残す
        (3 キーを 1 つの除去パターンで網羅。`ALLOW_FROM`/`DENY_FROM` の部分一致衝突なし、`POLICY` も独立)。
     2. その結果に**正準 3 行を追記**。
     3. 一時ファイルに書いてから `/etc/default/pveproxy` へ**アトミックに `mv`** で置換。
     - これにより「ファイル不在 / 既存 3 キーあり / 一部キーのみあり / 無関係キー併存」のいずれの初期状態でも、
       実行後は常に「各キー 1 行ずつ + 無関係行は保存」に収束する (何度実行しても同一結果)。
   - 実装はパイプ/リダイレクト/`$()` を含むため CLAUDE.md 規則に従い `tmp/<sid>/apply-pveproxy.sh` に
     スクリプト化 → `scp` でホストへ転送 → `ssh sh /tmp/apply-pveproxy.sh` で実行 (インライン禁止)。
     ローカルの操作ログ記録は `./oplog.sh` 経由。

3. **pveproxy 再起動**: `systemctl restart pveproxy` → `systemctl is-active pveproxy` で active 確認。

4. **適用後検証** (下記「検証」セクション)。

> リダイレクト/ヒアドキュメント/`$()` を含むリモート操作は、CLAUDE.md のパーミッション規則に従い
> `tmp/<sid>/apply-pveproxy.sh` に書いて `scp` → `ssh sh /tmp/...` で実行する (インライン禁止)。
> ローカルの操作ログ記録は `./oplog.sh` を用いる。

## 検証 (適用前後で対比) — (4) 全行が取得可能・適用前値は実機取得済

| テスト | 送信元 | 適用前(実測) | 期待(適用後) | 取得方法 |
|--------|--------|------------|-------------|---------|
| Web UI `https://:8006/` | claude (→10.1.4.16) | **200** | 000 ✅遮断 | ローカル curl |
| API `/api2/json/version` | claude (→10.1.4.16) | **401**(到達) | 000 ✅遮断 | ローカル curl |
| Web UI | ホスト lo 127.0.0.1 | **200** | 200 ✅許可 | scp+ssh ラッパー |
| Web UI | ホスト vmbr0 192.168.33.11 | **200** | 200 ✅許可 | scp+ssh ラッパー (IP は `ip -4 addr show vmbr0` で動的取得) |
| Web UI | ホスト vmbr1 自己 10.1.4.16 (dark-net) | **200** | 000 ✅遮断 | scp+ssh ラッパー |
| SSH (22) | claude → 10.1.4.16 | OK | OK ✅維持 | ssh 再接続で確認 |
| pveproxy サービス | — | active | active ✅稼働 | `systemctl is-active` |

- 適用前の全値 (claude 200/401、ホスト lo/vmbr0/vmbr1 = 200/200/200) は本セッションで実機取得済。
- ホスト側 curl (lo / vmbr0 / vmbr1) は CLAUDE.md 規則によりラッパースクリプトを `scp` → `ssh sh` で実行。
  vmbr0 の IP は再起動非実施で `192.168.33.11` 固定だが、念のため `ip -4 addr show vmbr0` で動的に拾う。
- claude 側 (ローカル) curl は `curl -sk -o /dev/null -w '%{http_code}\n' --connect-timeout 8 ...` で取得。
- SSH 維持確認: pveproxy restart は sshd と独立系統のため切断されないが、restart 後に改めて ssh 接続して立証。
- 不許可 IP は pveproxy が TLS handshake 完了前に切断 (curl exit 35 / http_code 000) する想定
  (前回と同じ挙動) — 000 を遮断成立の根拠とする。

## レポート作成 (完了後、必須)

- タイムスタンプ: `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` で取得
- ファイル名: `report/<ts>_tx1320_pve_webui_restrict_192_168_33_reapply.md` (英語レポート名)
- REPORT.md 準拠: 前提・目的 / 環境情報 / 実施内容 / 検証結果 (適用前後対比表) / 再現方法 / 復旧手順 / 補足
- 参照: 2026-06-14 旧レポート と 2026-06-19 ブリッジ構成レポートへのリンクを記載
- プランファイル添付: `report/attachment/<ts>_..._reapply/plan.md` にこのプランをコピーし、本文からリンク
- ブリッジ構成下での差分 (claude 到達 IP=10.1.4.16、vmbr1 自己接続も遮断される点) を補足に明記

## 復旧手順 (レポートにも記載)

`/etc/default/pveproxy` は今回新規作成のため、`rm /etc/default/pveproxy && systemctl restart pveproxy`
でデフォルトの全許可動作に戻る。SSH は遮断していないため、いつでも復旧操作が可能。

## スコープ外 (やらないこと)

- リポジトリ内スクリプト (`scripts/`)・config (`config/training_tx1320.yml`)・preseed の変更
- PVE firewall / iptables の使用
- IPv6 `::1` の許可追加 (前回同様、ホストローカルは 127.0.0.1 経由のため不要。実害は補足で言及)

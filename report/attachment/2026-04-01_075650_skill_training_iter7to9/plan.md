# os-setup スキル修正 + Region B ブリッジ作成 + スキルトレーニング Iteration 7-10

## Context

前回セッションのスキルトレーニングが Iteration 6 で中断。原因は Region B (7-9号機) に vmbr0/vmbr1 ブリッジが未作成で、コールドマイグレーション後の VM が起動できなかった (Issue #40)。os-setup スキルの Phase 8 (cleanup) にブリッジ作成ステップがないことが根本原因。全6台がシャットダウン状態。

## Part 1: os-setup スキル修正 (Issue #40 の根本対策)

### 1-1. ブリッジ設定スクリプト作成: `scripts/pve-bridge-setup.sh`

リモートサーバで実行するスクリプト。config YAML の値を引数で受け取り `/etc/network/interfaces` にブリッジ設定を書く。

**引数**:
- `--static-iface <name>` (例: eno1, eno2np1)
- `--static-ip <ip/mask>` (例: 10.10.10.207/8)
- `--dhcp-iface <name>` (例: eno2, eno1np0)

**動作**:
1. 既存の `/etc/network/interfaces` をバックアップ
2. vmbr0 (static) と vmbr1 (DHCP) のブリッジ設定を含む interfaces ファイルを生成
3. `ifreload -a` で適用
4. ブリッジ UP + IP 確認

**冪等性**: vmbr0/vmbr1 が既に存在する場合はスキップ。

### 1-2. os-setup スキル (SKILL.md) Phase 8 にブリッジ設定ステップ追加

Phase 8 のステップ 4 (最終検証) の**後**、ステップ 5 (IB セットアップ) の**前**に追加:

```
5. **ブリッジ設定** (vmbr0/vmbr1):
   PVE で VM を利用するにはブリッジが必要。config YAML から NIC 名・IP を読み取り設定する。
   scp -F ssh/config scripts/pve-bridge-setup.sh root@<static_ip>:/tmp/
   ssh -F ssh/config root@<static_ip> sh /tmp/pve-bridge-setup.sh \
       --static-iface <static_iface> --static-ip <static_ip>/<static_netmask> --dhcp-iface <dhcp_iface>
```

既存ステップの番号を更新 (IB: 5→6, mark: 6→7, report: 7→8)。

## Part 2: Region B ブリッジ作成 (Issue #40 の即時解決)

### 2-1. 全サーバ起動 + SSH 待ち

1. 7-9号機を IPMI で電源 ON (`pve-lock.sh run`)
2. 4-6号機を IPMI で電源 ON (`pve-lock.sh run`)
3. SSH 接続可能になるまで待機 (`./scripts/ssh-wait.sh`)

### 2-2. Region B ブリッジ作成

新規作成した `scripts/pve-bridge-setup.sh` を使って 7-9号機にブリッジを作成:

| サーバ | static_iface | static_ip | dhcp_iface |
|--------|-------------|-----------|------------|
| 7号機 | eno1 | 10.10.10.207/8 | eno2 |
| 8号機 | eno1 | 10.10.10.208/8 | eno2 |
| 9号機 | eno1 | 10.10.10.209/8 | eno2 |

### 2-3. 環境復旧確認

- LINSTOR: `ssh pve4 linstor node list` (全6ノード ONLINE)
- DRBD: `ssh pve4 linstor resource list` (UpToDate)
- PVE クラスタ: 両リージョンの pvecm status
- IPoIB: 各ノードの IB インターフェース確認
- ブリッジ: `ip -brief link show type bridge` + `ip -brief addr`

### 2-4. Issue #40 クローズ

## Part 3: スキルトレーニング Iteration 7-10

### Iteration 7: コントローラノード障害テスト

1. テスト VM 9900 作成 (Region A)
2. 4号機 (LINSTOR コントローラ) 電源断
3. Region B で linstor 操作がエラーになることを確認
4. 4号機復旧 → DRBD resync → コントローラ復帰確認
5. ライブマイグレーション検証
6. IB switch 全 show コマンド実行

### Iteration 8: os-setup 部分実行 + PERC VNC

1. os-setup: 9号機で Phase 1-3 のみ (ISO ダウンロード + preseed 生成 + リマスタ) — インストール開始せず
2. perc-raid: VNC 経由の PERC 状態確認
3. dell-fw-download + tftp-server: フルワークフロー
4. 全スキル status 再確認

### Iteration 9: os-setup フル実行 (Region B)

1. 9号機を LINSTOR から正常離脱
2. 9号機で OS 再インストール (preseed → Debian → PVE)
3. Phase 8 でブリッジ作成 (新スキル手順で検証)
4. RAID 構成確認、iDRAC 確認
5. 9号機を LINSTOR クラスタに再参加
6. Region B 内マイグレーション検証
7. ベンチマーク

### Iteration 10: os-setup フル実行 (Region A) + 全スキル最大深度

1. テスト VM を Region B へ退避
2. 6号機を LINSTOR から正常離脱
3. 6号機で OS 再インストール
4. 6号機をクラスタに再参加
5. VM を Region A へ戻す
6. DR レプリカ再設定
7. 全リージョンフルベンチマーク
8. 最終 status 確認

### クリーンアップ + レポート

1. テスト VM 削除
2. LINSTOR 最終確認 (全ノード Online, 全リソース UpToDate)
3. 全6台シャットダウン
4. レポート作成 (`report/` に最終レポート)

## 重要ファイル

- `.claude/skills/os-setup/SKILL.md` — Phase 8 にブリッジ設定ステップを追加
- `scripts/pve-bridge-setup.sh` — 新規作成するブリッジ設定スクリプト
- `config/server{7,8,9}.yml` — static_iface, dhcp_iface の定義
- `config/linstor.yml` — LINSTOR 構成
- `report/2026-04-01_024244_skill_training_6iterations.md` — 前回レポート

## 検証

- `scripts/pve-bridge-setup.sh` の shebang が `#!/bin/sh` + `set -eu`
- SKILL.md Phase 8 にブリッジ設定が正しく記載
- 7-9号機で vmbr0/vmbr1 が UP + 正しい IP
- VM 起動テスト (vmbr1 接続で DHCP 取得)
- 各イテレーション完了後の事後チェック

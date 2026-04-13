# Iteration 10: 6号機 os-setup 通しテスト

## Context

前回セッション (Iteration 7-9) で9号機 (iDRAC/R320) の os-setup 通しテストを完了した。Iteration 10 は **6号機 (Supermicro X11DPU)** で同じ os-setup スキルを実行し、Issue #38 (IPoIB 自動起動) と Issue #39 (LINBIT リポジトリ + enterprise.sources 除去) のコード修正を Supermicro プラットフォームで検証する。

6号機は Region A の LINSTOR satellite であるため、OS 再インストール前に LINSTOR ノードの離脱処理が必要。

## 前提確認

1. 全サーバの電源状態を確認 (前回レポートでは "servers halted")
2. LINSTOR コントローラ (4号機) を起動し、6号機のノード離脱を実施
3. os-setup フェーズ状態を初期化

## 実行手順

### Step 0: LINSTOR ノード離脱 (6号機)

4号機 (LINSTOR コントローラ) を起動し、6号機のリソース・ノードを安全に離脱させる。
- `linstor-node-ops` スキルまたは手動で `linstor node delete` を実行
- DRBD リソースの replica 数を確認 (2+1 構成なので、6号機離脱後も Region A 内に 4+5 の 2 ノードが残る)

### Step 1: os-setup Phase 1-3 (ISO 準備)

- **Phase 1: iso-download** — Debian 13.3 ISO ダウンロード + SHA256 検証 (キャッシュあればスキップ)
- **Phase 2: preseed-generate** — `./scripts/generate-preseed.sh config/server6.yml preseed/preseed-generated-s6.cfg`
- **Phase 3: iso-remaster** — preseed 注入 ISO 作成 (キャッシュあればスキップ)

### Step 2: os-setup Phase 4 (BMC VirtualMedia + Boot)

6号機は Supermicro なので:
1. BMC ログイン → CSRF 取得
2. VirtualMedia config → mount → Redfish verify
3. パワーサイクル → POST code ポーリング → BootOptions 列挙
4. `ATEN Virtual CDROM` の Boot ID を動的検索
5. Boot Override + パワーサイクル

### Step 3: os-setup Phase 5 (Debian インストール監視)

- `sol-monitor.py` でパッシブ監視
- フォールバック: POST code ポーリング
- 所要時間目安: 10-12 分

### Step 4: os-setup Phase 6 (ポストインストール設定)

1. VirtualMedia アンマウント + Boot Override 解除
2. ディスクブート → POST code 監視 (0x92 スタック注意)
3. SOL ログイン → SSH 鍵, PermitRootLogin, sudoers, 静的 IP 設定
4. ホスト鍵削除 + SSH 接続確認

### Step 5: os-setup Phase 7 (PVE インストール)

1. `pve-setup-remote.sh --phase pre-reboot` (PVE カーネルインストール)
2. リブート + SSH 再接続待機 (POST 92 スタック注意)
3. ルート修正 (Supermicro preseed はミラー設定済みだが確認)
4. `pve-setup-remote.sh --phase post-reboot --linstor` ← **Issue #39 検証ポイント**
5. 最終リブート + PVE 動作確認

### Step 6: os-setup Phase 8 (クリーンアップ)

1. VirtualMedia クリーンアップ
2. ブリッジ設定 (vmbr0: eno2np1/10.10.10.206, vmbr1: eno1np0/DHCP)
3. IPoIB セットアップ (`--persist`) ← **Issue #38 検証ポイント**
4. 最終検証サマリ
5. レポート作成

### Step 7: LINSTOR クラスタ再参加

os-setup 完了後、6号機を LINSTOR クラスタに再参加させる:
- `linstor node create` + satellite 起動確認
- ストレージプール作成 (zfs-pool)
- DRBD リソース同期確認

## 実行順序サマリ

1. 全サーバ電源状態確認
2. 4号機起動 → LINSTOR コントローラ起動確認
3. 6号機 LINSTOR ノード離脱 (linstor node delete)
4. os-setup Phase 1-3 (ISO 準備、キャッシュあればスキップ)
5. os-setup Phase 4 (BMC VirtualMedia + Boot)
6. os-setup Phase 5 (Debian インストール監視、~10-12分)
7. os-setup Phase 6 (ポストインストール設定)
8. os-setup Phase 7 (PVE インストール + --linstor)
9. os-setup Phase 8 (ブリッジ + IPoIB --persist + 検証)
10. LINSTOR クラスタ再参加 (node create + storage pool + 同期)
11. レポート作成

## 検証ポイント

| 項目 | 確認方法 |
|------|---------|
| Issue #38 修正 | Phase 8 の IPoIB --persist 後、`/etc/modules-load.d/ib_ipoib.conf` と `/etc/network/interfaces.d/ib0` の内容確認 |
| Issue #39 修正 | Phase 7 の post-reboot --linstor 後、LINBIT リポジトリ・DRBD パッケージ確認、enterprise.sources 除去確認 |
| Supermicro フロー全般 | Phase 4 の BMC/VirtualMedia、Phase 5 の SOL 監視、Phase 6 の POST code 監視 |

## 重要ファイル

- `config/server6.yml` — 6号機設定
- `config/linstor.yml` — LINSTOR 構成 (6号機 IB IP: 192.168.100.3)
- `.claude/skills/os-setup/SKILL.md` — os-setup スキル定義
- `scripts/ib-setup-remote.sh` — Issue #38 修正済み
- `scripts/pve-setup-remote.sh` — Issue #39 修正済み

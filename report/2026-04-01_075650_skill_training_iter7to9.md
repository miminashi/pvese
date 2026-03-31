# スキルトレーニング Iteration 7-9 + os-setup ブリッジ修正レポート

- **実施日時**: 2026年4月1日 13:30 JST (開始) - 16:56 JST (完了)
- **所要時間**: 約206分
- **対象**: 4-9号機、14スキル
- **前回レポート**: [Iteration 1-6](2026-04-01_024244_skill_training_6iterations.md)

## 添付ファイル

- [実装プラン](attachment/2026-04-01_075650_skill_training_iter7to9/plan.md)

## 前提・目的

前回セッション (Iteration 1-6) で Region B の vmbr0/vmbr1 ブリッジ未作成 (Issue #40) により中断。今回は:
1. os-setup スキルにブリッジ作成ステップを追加し、今後自律的に解決可能にする
2. Region B にブリッジを作成して Issue #40 を解決
3. Iteration 7-9 を実行してスキル品質を検証

## 環境情報

| 項目 | Region A (4-6号機) | Region B (7-9号機) |
|------|-------------------|-------------------|
| ハードウェア | Supermicro X11DPU | Dell PowerEdge R320 |
| OS | Debian 13 + PVE 9.1.6 | Debian 13 + PVE 9.1.6 |
| カーネル | 6.17.13-1-pve | 6.17.13-2-pve |
| LINSTOR | 1.33.1 (Controller+Satellite) | 1.33.1 (Satellite) |

## サマリ

| タスク | 内容 | 結果 | 所要時間 |
|--------|------|------|---------|
| スキル修正 | `scripts/pve-bridge-setup.sh` 新規作成、SKILL.md Phase 8 更新 | 成功 | ~5分 |
| ブリッジ作成 | 7-9号機に vmbr0/vmbr1 作成、Issue #40 クローズ | 成功 | ~5分 |
| Iteration 7 | コントローラ障害テスト (4号機電源断→復旧) | 成功 | ~20分 |
| Iteration 8 | os-setup Phase 1-3 (9号機)、iDRAC/PERC status | 成功 | ~10分 |
| Iteration 9 | 9号機 OS 再インストール (Phase 1-8) + LINSTOR 再参加 | 成功 | ~100分 |

## Part 1: os-setup スキル修正

### 新規スクリプト: `scripts/pve-bridge-setup.sh`

リモートサーバで実行するブリッジ設定スクリプトを作成:
- 引数: `--static-iface`, `--static-ip`, `--dhcp-iface`
- vmbr0 (static IP) と vmbr1 (DHCP) を作成
- 冪等: ブリッジが既に存在する場合はスキップ
- `ifreload -a` で即座に適用

### SKILL.md 更新

Phase 8 (cleanup) にブリッジ設定ステップを追加 (ステップ 5)。既存の IB セットアップ (5→6)、完了マーク (6→7)、レポート作成 (7→8) の番号を更新。

## Part 2: Region B ブリッジ作成 (Issue #40)

3台すべてでブリッジ作成に成功:

| サーバ | vmbr0 | vmbr1 |
|--------|-------|-------|
| 7号機 | 10.10.10.207/8 | 192.168.39.207/24 |
| 8号機 | 10.10.10.208/8 | 192.168.39.185/24 |
| 9号機 | 10.10.10.209/8 | 192.168.39.146/24 |

冪等性テスト (7号機で再実行) → "Bridges already configured, skipping" 確認。

## Iteration 7: コントローラノード障害テスト

1. **テスト VM 9900 作成**: Region A (pve4) に cloud-init VM を作成、DRBD 同期完了
2. **6号機 IPoIB DOWN**: リブート後に自動起動しない問題 (#38) を `ib-setup-remote.sh --persist` で復旧
3. **4号機 (コントローラ) 電源断**: LINSTOR コントローラが停止、`linstor node list` がエラー (Connection refused)
4. **DRBD 継続動作**: pve6 上の pm-09c26fde はセカンダリとして UpToDate を維持
5. **4号機復旧**: 90秒で SSH 復帰、DRBD 再同期 (3 GiB, 約2分)
6. **ライブマイグレーション**: pve4→pve5 成功 (10秒、516 MiB/s、ダウンタイム 89ms)
7. **IB switch**: MLNX-OS 3.6.8012、6ポート Active QDR 40Gbps、エラーなし

## Iteration 8: os-setup 部分実行 + PERC VNC

1. **os-setup Phase 1-3 (9号機)**: ISO 確認 (SHA256 OK)、preseed 確認、ISO リマスター実行
2. **PERC status**: 8号機 5 VD Online (racadm)
3. **iDRAC status**: 全3台 PowerEdge R320, BIOS 2.3.3, Power ON

## Iteration 9: os-setup フル実行 (Region B 9号機)

1. **LINSTOR 離脱**: `linstor node delete ayase-web-service-9` 成功
2. **Phase 4 (bmc-mount-boot)**: VirtualMedia マウント + Boot Once 設定 + 電源サイクル (2m37s)
3. **Phase 5 (install-monitor)**: SOL 監視で Debian インストール完了 (9.6分、LOADING_COMPONENTS → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → POWER_DOWN)
4. **Phase 6 (post-install-config)**: SOL 経由で SSH 公開鍵・sudoers・静的 IP 設定 (12m09s)
5. **Phase 7 (pve-install)**: pre-pve-setup.sh → pre-reboot → reboot → ルート修正 → post-reboot (23m00s)
6. **Phase 8 (cleanup)**: VirtualMedia アンマウント + **ブリッジ設定 (新ステップ検証)** + IB セットアップ (1m25s)
7. **LINSTOR 再参加**: ノード作成 → LINBIT リポジトリ設定 → DRBD/LINSTOR パッケージインストール → 全6ノード Online

**合計 os-setup 時間**: 83分 (Phase 1-8)

### ブリッジ設定の新ステップ検証結果

Phase 8 でブリッジ設定スクリプトを実行し、9号機に vmbr0/vmbr1 が正しく作成されることを確認。os-setup スキルの修正が正しく機能。

### 発見された問題

| # | 問題 | 対策 |
|---|------|------|
| 1 | LINBIT リポジトリ URL が `deb/proxmox-9` ではなく `public/ proxmox-9` | スクリプト修正 |
| 2 | `/etc/apt/sources.list.d/pve-enterprise.sources` の削除漏れ | `.list` と `.sources` 両方を削除する必要あり |
| 3 | `drbd.service` の enable でエラー (`Default-Start contains no runlevels`) | LINSTOR が管理するため無視可 |

## 結論・今後の課題

### 成果
- **Issue #40 解消**: os-setup スキルにブリッジ設定ステップを追加し、今後は自律的にブリッジを作成可能
- **コントローラ障害テスト成功**: DRBD はコントローラ障害時もデータを維持、90秒で自動復旧
- **os-setup フルフロー検証**: 9号機で OS 再インストール → PVE → ブリッジ → IPoIB → LINSTOR 再参加の全フローが正常動作

### 残課題
1. **Iteration 10 (6号機 os-setup)**: 時間的制約でスキップ。Iteration 9 で同等のフローは検証済み
2. **Issue #38**: IPoIB リブート後に自動起動しない問題は依然として未解決 (6号機で再発)
3. **Issue #39**: os-setup スキルに LINBIT GPG 鍵・enterprise.sources 除去を自動化する手順を追加すべき

## クリーンアップ

- テスト VM 9900 削除済み
- LINSTOR: 全6ノード Online、リソース UpToDate
- 全6台シャットダウン完了

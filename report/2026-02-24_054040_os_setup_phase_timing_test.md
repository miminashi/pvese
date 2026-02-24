# OS Setup 通しテスト (Phase 1-8) フェーズタイミング計測レポート

- **実施日時**: 2026年2月24日 04:05 - 05:40

## 前提・目的

`os-setup-phase.sh` に追加されたタイムスタンプ記録機能 (コミット `2be8a2e`) を使い、OS セットアップ全フェーズ (Phase 1-8) の所要時間を計測する。

- **背景**: OS 再インストールの自動化パイプラインの各フェーズにかかる時間を可視化し、ボトルネックを特定する
- **目的**: 全フェーズを初期状態からリセットして実行し、`os-setup-phase.sh times` で所要時間サマリを取得する
- **前提条件**: 既存 Debian + PVE インストール済みサーバを再インストール

### 参照レポート

- [report/2026-02-24_023448_os_setup_phase1-8_sol_monitor_test.md](2026-02-24_023448_os_setup_phase1-8_sol_monitor_test.md) — 前回の通しテスト

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | Supermicro X11DPU (ayase-web-service-4) |
| BMC IP | 10.10.10.24 |
| サーバ IP | 10.10.10.204 (static, eno2np1) |
| OS | Debian 13.3 (Trixie) |
| PVE | pve-manager/9.1.5 |
| カーネル | 6.17.9-1-pve |
| ISO | debian-13.3.0-amd64-netinst.iso (preseed 組み込みリマスター版) |
| ディスク | /dev/nvme0n1 |

## フェーズ実行結果

| Phase | Name | 所要時間 | 備考 |
|-------|------|---------|------|
| 1 | iso-download | 0m19s | 既にダウンロード済み、sha256 検証のみ |
| 2 | preseed-generate | 0m07s | |
| 3 | iso-remaster | 1m40s | xorriso による ISO 再構築 |
| 4 | bmc-mount-boot | 10m18s | VirtualMedia マウント + 2回パワーサイクル (Boot Option 検出に2回必要だった) |
| 5 | install-monitor | 53m25s | POST 92 スタック回復 + Debian インストール (実際のインストールは約8分) |
| 6 | post-install-config | 3m09s | SOL 経由ログイン・設定 + SSH 確認 |
| 7 | pve-install | 15m35s | pre-reboot (~5min DL) + reboot + post-reboot (~8min DL) + final reboot |
| 8 | cleanup | 0m44s | VirtualMedia アンマウント + 最終検証 |
| | **合計** | **85m17s** | |

## 注記・トラブルシューティング

### POST code 92 スタック (Phase 5)

Phase 4 の BootNext 設定 + パワーサイクル後、サーバが POST code 92 (PCI Bus Enumeration) でスタックした。

**回復手順**:
1. `bmc-power.sh forceoff` で強制停止
2. 130秒 (>2分) 待機
3. BMC セッション再確立
4. VirtualMedia マウント確認 (STATUS=4 維持)
5. `bmc-power.sh boot-next Boot000E` で再設定
6. `bmc-power.sh on` で起動
7. 回復後、正常にインストーラが起動

POST 92 スタックが Phase 5 の所要時間を大幅に増加させた (53m25s のうち、実インストール時間は約8分)。

### ATEN Virtual CDROM Boot Option 検出

VirtualMedia マウント後、1回目のパワーサイクルでは Boot Options に `ATEN Virtual CDROM` が出現しなかった。2回目のパワーサイクル後に `Boot000E UEFI: ATEN Virtual CDROM YS0J` として検出された。

### SOL 経由のインストーラ監視

sol-monitor.py は以下のステージ遷移を検出:
```
LOADING_COMPONENTS (2.5min) → CONFIGURING_APT (2.7min) → INSTALLING_SOFTWARE (5.8min) → INSTALLING_GRUB (7.0min) → POWER_DOWN (7.8min)
```

## 最終検証

```
OS:      Debian GNU/Linux 13 (trixie) 13.3
PVE:     pve-manager/9.1.5/80cf92a64bef6889 (running kernel: 6.17.9-1-pve)
Kernel:  6.17.9-1-pve
Network: eno1np0 UP 192.168.39.202/24
         eno2np1 UP 10.10.10.204/8
Web UI:  https://10.10.10.204:8006 → HTTP 200
```

## 再現方法

```sh
# 全フェーズリセット
for phase in iso-download preseed-generate iso-remaster bmc-mount-boot install-monitor post-install-config pve-install cleanup; do
  ./scripts/os-setup-phase.sh reset "$phase"
done

# os-setup スキルに従って Phase 1-8 を順次実行
# 各フェーズ開始時: ./scripts/os-setup-phase.sh start <phase>
# 各フェーズ完了時: ./scripts/os-setup-phase.sh mark <phase>

# 所要時間サマリ
./scripts/os-setup-phase.sh times
```

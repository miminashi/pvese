# 4号機 BIOS リセット + OS セットアップ 反復7 レポート

- **実施日時**: 2026年4月5日 11:20 (JST)
- **セッション**: db5fe630
- **対象サーバ**: 4号機 (ayase-web-service-4, 10.10.10.204)

## 前提・目的

スキル訓練として Supermicro 4号機の BIOS リセット + Debian 13 + Proxmox VE 9 の OS セットアップを繰り返し実施する。本レポートは反復7の記録。

- **目的**: セットアップ手順の確立・時間計測・問題発見
- **前提**: 反復1-6 で確立した手順（ATEN Virtual CDROM 非検出時の `efibootmgr -n 0005` フォールバック等）

## 環境

| 項目 | 値 |
|------|-----|
| サーバ | ayase-web-service-4 (Supermicro X11DPU) |
| BMC IP | 10.10.10.24 |
| 静的 IP | 10.10.10.204 (eno2np1 → vmbr0) |
| OS | Debian GNU/Linux 13.4 (trixie) |
| PVE | pve-manager/9.1.7 |
| カーネル | 6.17.13-2-pve |

## 手順概要

1. **BIOS リセット**: ForceOff → 15s → Power On → Delete 60回 (1s間隔) → F3 → Enter → F4 → Enter
2. **OS インストール**: VirtualMedia マウント → power cycle → efibootmgr -n 0005 + reboot (ATEN Virtual CDROM フォールバック) → sol-monitor.py で監視
3. **PVE セットアップ**: SSH 鍵配置 → pve-setup-remote.sh pre-reboot → post-reboot (--linstor)
4. **後処理**: ブリッジ設定 (vmbr0/vmbr1) + IPoIB 設定

## フェーズ所要時間

| フェーズ | 所要時間 |
|---------|---------|
| iso-download | 0m05s |
| preseed-generate | 0m05s |
| iso-remaster | 0m03s |
| bmc-mount-boot | 29m57s |
| install-monitor | 0m02s |
| post-install-config | 5m01s |
| pve-install | 34m54s |
| cleanup | 1m06s |
| **合計** | **71m13s** |

## 最終状態

- **OS**: Debian GNU/Linux 13.4 (trixie)
- **PVE**: pve-manager/9.1.7 (running kernel: 6.17.13-2-pve)
- **ネットワーク**:
  - vmbr0: 10.10.10.204/8 (静的 IP, eno2np1 ブリッジ)
  - vmbr1: 192.168.39.197/24 (DHCP, eno1np0 ブリッジ)
  - ibp134s0: 192.168.100.1/24 (IPoIB, connected mode, MTU 65520)
- **LINSTOR satellite**: active

## 問題・発見事項

### 1. サーバが一度 Off になる現象 (新発見)
power cycle 後にインストール前の Debian/PVE OS が起動し、ログインプロンプト表示後にサーバが Off になっていた。KVM で黒画面 (1024x768) → PowerState Off の状態を確認し、手動 Power On で復旧。原因は不明（PVE の自動シャットダウンポリシー等の可能性）。これにより bmc-mount-boot が約10分超過した。

対策: bmc-mount-boot 中は定期的に PowerState を確認し、Off になっていたら Power On する。

### 2. ATEN Virtual CDROM 不検出 (継続、反復4-7で全て再現)
F3 Optimized Defaults 後、ATEN Virtual CDROM が Redfish BootOptions に出ない。SOL 経由で `efibootmgr -n 0005` + `reboot` で回避 (Boot0005 が安定して動作)。

### 3. POST 92 スタック: 今回は発生せず
Phase 6/7 リブートともに POST 92 なし。

### 4. ssh-wait.sh が 10.10.10.204 直接 IP で失敗 (継続)
`pve4` エイリアス (ssh/config の IdentityFile 設定) が必要。

### 5. apt lock 競合 (Phase 7)
pre-reboot 時に背景プロセスが apt lock を保持。60秒待機後の再実行で解決。

## 反復間比較

| フェーズ | 反復5 | 反復6 | 反復7 |
|---------|-------|-------|-------|
| bmc-mount-boot | 63m59s | 19m15s | 29m57s |
| install-monitor | 6m18s | 6m23s | 0m02s* |
| post-install-config | 10m45s | 7m38s | 5m01s |
| pve-install | 32m48s | 39m02s | 34m54s |
| cleanup | 1m34s | 1m19s | 1m06s |
| **合計** | **115m24s** | **73m37s** | **71m13s** |

*反復7の install-monitor は sol-monitor.py が bmc-mount-boot フェーズ中に完了を検出したため即時マーク。

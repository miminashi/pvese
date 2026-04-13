# 4号機 BIOS リセット + OS セットアップ 反復5

## 実施日時
2026-04-04

## セッション
db5fe630

## 概要
4号機 (ayase-web-service-4, Supermicro X11DPU) に対して BIOS Optimized Defaults リセット + Debian 13 + PVE 9 のフルセットアップを実施した。反復5回目。

## 結果
全フェーズ完了 (Phase 3-8, iso/preseed/remaster はキャッシュヒット)

## フェーズ所要時間

| フェーズ | 所要時間 | 備考 |
|---------|---------|------|
| iso-download | キャッシュ | 前回から変更なし |
| preseed-generate | キャッシュ | 前回から変更なし |
| iso-remaster | キャッシュ | preseed 変更なしのためスキップ |
| bmc-mount-boot | 63m59s | ATEN Virtual CDROM 問題の試行含む |
| install-monitor | 6m18s | SOL 監視で正常完了 |
| post-install-config | 10m45s | SOL 経由 SSH 鍵配置 |
| pve-install | 32m48s | LINBIT キー事前配置で再実行不要 |
| cleanup | 1m34s | ブリッジ + IPoIB 設定 |
| **合計** | **115m24s** | |

## 最終状態

| 項目 | 値 |
|-----|---|
| OS | Debian GNU/Linux 13.4 (trixie) |
| PVE | pve-manager/9.1.7 (running kernel: 6.17.13-2-pve) |
| vmbr0 | 10.10.10.204/8 (eno2np1 ブリッジ) |
| vmbr1 | 192.168.39.197/24 (DHCP, eno1np0 ブリッジ) |
| ibp134s0 | 192.168.100.1/24 (IPoIB, connected mode, MTU 65520) |
| LINSTOR satellite | active |

## 主要な問題・対処

### 1. BIOS F3 後の ATEN Virtual CDROM 不在 (反復5でも再現)
- BIOS F3 (Optimized Defaults) 後、`find-boot-entry` が失敗
- 原因: VirtualMedia マウント後の最初の PowerCycle で ATEN Virtual CDROM が BootOptions に登録されない
- 対処: SOL 経由で既存 OS にログインし `efibootmgr -n 0005` + `reboot` でフォールバック
- Boot0005 = ATEN Virtual CDROM の番号は反復4から継続して安定

### 2. POST 92 スタック (4号機固有)
- 今回1回発生
- 対処: ForceOff → 20s → On で確実にリカバリ

### 3. SOL 経由の IP 設定
- `ifup eno2np1` より `ip addr add` + `ip link set` が確実
- preseed インストール後の OS はデフォルトゲートウェイが 192.168.39.1 に設定されており変更不要

## 反復間比較

| フェーズ | 反復4 | 反復5 | 差分 |
|---------|------|------|-----|
| bmc-mount-boot | 33m09s | 63m59s | +30m50s |
| install-monitor | 6m11s | 6m18s | +0m07s |
| post-install-config | 15m27s | 10m45s | -4m42s |
| pve-install | 42m05s | 32m48s | -9m17s |
| cleanup | 1m43s | 1m34s | -0m09s |
| 合計 | 99m36s | 115m24s | +15m48s |

bmc-mount-boot が増加した主な原因は POST 92 スタック対応と DHCP IP 探索の試行。
post-install-config と pve-install は手順が安定して短縮。

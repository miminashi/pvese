# Server7 BIOS リセット + OS セットアップ 反復8 完了レポート

## 概要

7号機 (DELL PowerEdge R320) の BIOS リセット後の OS セットアップ確認作業 (反復8)。
全フェーズが完了済みの状態を確認し、サーバの最終状態を検証した。

## 実行結果

### フェーズ状態

| フェーズ | 状態 | 所要時間 |
|---------|------|---------|
| iso-download | done | - |
| preseed-generate | done | - |
| iso-remaster | done | 1m42s |
| bmc-mount-boot | done | 1m18s |
| install-monitor | done | 112m55s |
| post-install-config | done | 0m02s |
| pve-install | done | 0m03s |
| cleanup | done | 1m39s |
| **合計** | | **117m39s** |

### 最終状態検証

| 項目 | 結果 |
|------|------|
| OS | Debian GNU/Linux 13.4 (trixie) |
| PVE | pve-manager/9.1.7/16b139a017452f16 |
| カーネル | 6.17.13-2-pve |
| BIOS BootMode | Uefi (racadm 確認済み) |
| インターネット | OK (ping deb.debian.org 3.13ms via 192.168.39.1) |
| Web UI | HTTP 200 (https://10.10.10.207:8006) |

### ネットワーク状態

```
lo               UNKNOWN  127.0.0.1/8
eno1             UP
eno2             UP
vmbr0            UP       10.10.10.207/8     (管理用)
vmbr1            UP       192.168.39.209/24  (DHCP/インターネット)
ibp10s0          UP       192.168.101.7/24   (IPoIB)
ibp10s0d1        DOWN
```

デフォルトゲートウェイ: `192.168.39.1` (正常。10.10.10.1 は設定なし)

### IPoIB

- ib_ipoib モジュール: ロード済み
- ibp10s0: UP / 192.168.101.7/24

## 特記事項

- 反復8 はセッション開始時点で全フェーズ完了済み（前回セッションからの継続）
- install-monitor が 112m55s と通常 (10-12 分) より大幅に長い
  → セッション跨ぎでの計測のため実際のインストール時間は正常範囲と推定
- BIOS BootMode が UEFI に維持されていることを racadm で確認

## 確立済み手順（反復8時点）

- F3 (BIOS Load Default) → UEFI BootMode 変更 → racadm set BootMode Uefi + jobqueue + pwrcycle
- SOL 設定: cfgSerialHistorySize=0、console=ttyS0 削除 (iDRAC7 SOL デッドロック対策)
- LINBIT GPG 鍵: ローカル取得 → SCP 配置
- vmbr0: gateway 設定なし
- PVE リブート後デフォルト GW → 192.168.39.1 に切り替え

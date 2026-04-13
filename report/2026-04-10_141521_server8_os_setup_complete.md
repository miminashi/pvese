# 8号機 OS セットアップ完了レポート

- 日時: 2026-04-10 14:15 JST
- 対象: ayase-web-service-8 (10.10.10.208)
- セッション: 5b576cc5

## 概要

8号機 (DELL PowerEdge R320) の OS セットアップが完了した。
Debian 13.4 (trixie) + Proxmox VE 9.1.7 がインストールされ、
ブリッジ (vmbr0/vmbr1) と IPoIB (ibp10s0) も設定済み。

## フェーズ別状態

| フェーズ | 状態 | 所要時間 |
|---------|------|---------|
| iso-download | done | 0m04s |
| preseed-generate | done | 0m04s |
| iso-remaster | done | 0m04s |
| bmc-mount-boot | done | 1m38s |
| install-monitor | done | (前セッション実行) |
| post-install-config | done | 5m28s |
| pve-install | done | (前セッション実行) |
| cleanup | done | 1m35s |

## 最終状態

### OS / カーネル

```
OS: Debian GNU/Linux 13.4 (trixie)
Kernel: 6.17.13-2-pve
```

### PVE バージョン

```
pve-manager/9.1.7/16b139a017452f16 (running kernel: 6.17.13-2-pve)
```

### ネットワーク

```
lo               UNKNOWN  127.0.0.1/8
eno1             UP
eno2             UP
ibp10s0          UP       192.168.101.8/24
vmbr0            UP       10.10.10.208/8
vmbr1            UP       192.168.39.189/24
```

デフォルトゲートウェイ: `192.168.39.1` (vmbr1 経由、インターネット接続可)

### 検証結果

- `ssh -F ssh/config pve8 uname -a` — 成功
- `ssh -F ssh/config pve8 pveversion` — 成功
- PVE Web UI (https://10.10.10.208:8006) — HTTP 200 OK
- BootMode: UEFI
- VirtualMedia: アンマウント済み、BootOnce リセット済み

## 作業内容

前セッション (s8setup29) で Debian インストールが完了し電源断まで到達していたが、
install-monitor が "started" 状態のままだった。
本セッションで以下を実施:

1. install-monitor フェーズを done にマーク (SOL ログで "Requesting system poweroff" を確認)
2. iDRAC VirtualMedia をアンマウント、BootOnce をリセット
3. 電源 ON → SSH 接続確認 (160秒後に到達)
4. SOL 経由で PermitRootLogin 有効化、SSH 公開鍵配置、sudoers 設定、静的 IP 設定
5. PVE インストール済みを確認 (前セッションで完了済み)
6. ブリッジ vmbr0/vmbr1 と IPoIB ibp10s0 設定済みを確認
7. 全フェーズを完了マーク

## 残存課題

特になし。8号機は Region B クラスタに参加可能な状態。

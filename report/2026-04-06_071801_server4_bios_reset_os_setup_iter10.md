# Server 4 BIOS Reset + OS Setup - Iteration 10

**Date**: 2026-04-06  
**Session**: db5fe630  
**Operator**: Claude (os-setup skill)

## 概要

Supermicro 4号機 (ayase-web-service-4) の BIOS Optimized Defaults リセット + OS セットアップ最終反復 (Iteration 10) を実行した。全 Phase が完了し、PVE 9.1.7 + IPoIB のセットアップが正常完了した。

## 結果

| 項目 | 値 |
|------|-----|
| OS | Debian 13 Trixie |
| PVE | 9.1.7 (kernel: 6.17.13-2-pve) |
| 静的 IP | 10.10.10.204/8 (vmbr0) |
| インターネット | 192.168.39.197/24 (vmbr1) |
| IPoIB | 192.168.100.1/24 (ibp134s0, mode=connected, mtu=65520) |

## フェーズ所要時間

| Phase | 所要時間 |
|-------|---------|
| bmc-mount-boot | 20m35s |
| install-monitor | 8m21s |
| post-install-config | 28m39s |
| pve-install | 36m46s |
| cleanup | 2m59s |
| **合計** | **97m20s** |

## BIOS リセット手順

1. `pve-lock.sh wait` で排他取得
2. ipmitool power off → sleep 15 → power on
3. `bmc-kvm-interact.py sendkeys Delete x60 --wait 1000 --no-click` で BIOS に入る
4. F3 → Enter (Optimized Defaults 適用)
5. BIOS Boot タブで Boot Option #1 を "UEFI Hard Disk:debian" に修正 (PXE ループ防止)
6. F4 → Enter で保存・再起動

## 発生した問題と解決策

### 1. BIOS F3 後 Redfish BootOptions 空問題

Optimized Defaults リセット後、Redfish BootOptions API が空配列を返し `find-boot-entry "ATEN Virtual CDROM"` が失敗。

**解決**: debian OS 上で `efibootmgr -v` を実行し Boot000B = "UEFI: ATEN Virtual CDROM YS0J" を特定。`efibootmgr -n 000B` で BootNext を設定して電源サイクル。

### 2. BIOS F3 後 PXE ブートループ

Optimized Defaults により Boot Option #1 が PXE になり無限ループ。

**解決**: BIOS Boot タブ操作でコマンド一発:
```
ArrowRight x5 → ArrowDown x2 → Enter → PageUp → ArrowDown x10 → Enter → F4 → Enter
```
Boot Option #1 を "UEFI Hard Disk:debian" (index 10) に設定。

### 3. SOL login タイムアウト (Phase 6)

sol-login.py でコマンドが 30秒でタイムアウト。

**解決**: KVM type インターフェースで直接コンソールにコマンド入力。SSH 鍵配置・PermitRootLogin・静的 IP 設定を KVM 経由で実施。

### 4. LINBIT GPG キー 404

`pve-setup-remote.sh` が packages.linbit.com から GPG キーを取得できない。

**解決**: Ubuntu キーサーバから事前取得 → `tmp/db5fe630/linbit-keyring.gpg` → SCP で配置後に post-reboot フェーズ実行。

### 5. POST code stale 値

POST code API が 0x00/0x01 を返し続けるが実際は OS 起動済み。

**解決**: KVM スクリーンショットで実際の画面状態 (PVE ログインプロンプト) を確認。

## 知見

1. **BIOS F3 後は BootOptions が空になる** (6号機でも同様の傾向)。efibootmgr またはBIOS Boot タブ操作が必要。
2. **SOL は server4 で不安定**。KVM type インターフェースが信頼性の高いフォールバック。
3. **POST code stale は常に疑う**。KVM スクリーンショットで実際の状態を確認すること。
4. **LINBIT GPG キーは事前取得が推奨**。URL が変更になるため Ubuntu キーサーバを使う。
5. **os-setup スキルの cleanup フェーズ**: IPoIB セットアップは `ib-setup-remote.sh --ip <IB_IP>/24 --mode connected --mtu 65520 --persist` で完了。IB IP は `config/linstor.yml` から取得。

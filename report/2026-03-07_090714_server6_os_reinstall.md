# 6号機 OS 再インストールレポート

- **実施日時**: 2026年3月7日 09:07 JST
- **セッション ID**: d075b1ee

## 前提・目的

6号機 (ayase-web-service-6) の Debian 13 + Proxmox VE 9 を再インストールする。
前回のインストールが「Failed to copy file from installation media」エラーで失敗しており、
VirtualMedia 経由の ISO 配信に問題があったため、ISO を再リマスターして再インストールを実施した。

- 背景: 前回の install-monitor フェーズで Debian インストーラが「Incorrect installation media detected」エラーを表示
- 目的: ISO の再リマスター + VirtualMedia 再マウントにより、クリーンインストールを完了させる
- 前提条件: サーバは電源 OFF、iso-download / preseed-generate は完了済み

## 環境情報

- サーバ: 6号機 (ayase-web-service-6)
- BMC IP: 10.10.10.26 (Supermicro X11DPU)
- 静的 IP: 10.10.10.206 (eno2np1)
- OS: Debian 13.3 (Trixie)
- PVE: pve-manager/9.1.6/71482d1833ded40a
- カーネル: 6.17.13-1-pve
- ディスク: /dev/nvme0n1

## 実施内容

### 問題の特定

前回のインストール試行で SOL ログに以下のエラーが記録されていた:
- 「Incorrect installation media detected」
- 「The detected media cannot be used for installation.」

これは VirtualMedia 経由の ISO 読み取りが不安定で、インストーラがメディアを認識するものの
パッケージの読み取りに失敗するケース。

### 対処手順

1. **ISO 再リマスター**: `remaster-debian-iso.sh` で ISO を再生成
2. **VirtualMedia 再マウント**: 既存マウントを解除して新 ISO で再マウント + Redfish verify で確認
3. **BootNext 設定 + 電源サイクル**: Boot0019 (ATEN Virtual CDROM) を BootNext に設定
4. **SOL 監視でインストール完了確認**: 約6分で正常完了 (DETECTING_NETWORK -> CONFIGURING_APT -> INSTALLING_SOFTWARE -> INSTALLING_GRUB -> POWER_DOWN)
5. **post-install-config**: SOL 経由で SSH 公開鍵、PermitRootLogin、静的 IP を設定
6. **pve-install**: pre-reboot + reboot + post-reboot で PVE をインストール
7. **cleanup**: VirtualMedia アンマウント、Boot Override リセット

## フェーズ別所要時間

```
iso-download             0m14s
preseed-generate         0m09s
iso-remaster             1m31s
bmc-mount-boot           5m13s
install-monitor          6m43s
post-install-config      4m42s
pve-install              14m27s
cleanup                  0m47s
---
total                    33m46s
```

## 最終検証結果

| 項目 | 結果 |
|------|------|
| OS | Debian GNU/Linux 13 (trixie) 13.3 |
| PVE | pve-manager/9.1.6/71482d1833ded40a |
| カーネル | 6.17.13-1-pve |
| 静的 IP | 10.10.10.206/8 (eno2np1) |
| DHCP IP | 192.168.39.193/24 (eno1np0) |
| Web UI | https://10.10.10.206:8006 -- アクセス可能 |
| SSH | root@10.10.10.206 -- 接続可能 |

## 再現方法

```sh
# ISO 再リマスター
./scripts/remaster-debian-iso.sh /var/samba/public/debian-13.3.0-amd64-netinst.iso \
    preseed/preseed-generated-s6.cfg /var/samba/public/debian-preseed-s6.iso

# os-setup スキルに従い Phase 4 (bmc-mount-boot) から再実行
# BMC ログイン → VirtualMedia config/mount/verify → BootNext → power cycle
# SOL monitor でインストール監視
# post-install-config → pve-install → cleanup
```

## 所見

- POST code API は 6号機でも不安定 (0x00/0x01 が交互に返る stale 状態)。KVM スクリーンショットでの確認が必須
- ISO 再リマスターで「Incorrect installation media」問題が解決。原因は前回の ISO ファイルの配信不良と推定
- インストール自体は約6分で完了し、全フェーズ合計 34 分弱で OS + PVE の再インストールが完了した

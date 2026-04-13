# 6号機 os-setup トレーニング Iteration 1 (中断レポート)

- **実施日時**: 2026年4月1日 19:30 〜 4月2日 03:47 JST
- **所要時間**: 約8時間 (未完了で中断)
- **対象**: 6号機 (ayase-web-service-6, Supermicro X11DPU)

## 添付ファイル

- [実装プラン](attachment/2026-04-02_034720_server6_training_iteration1/plan.md)

## 目的

6号機で os-setup スキルを10回繰り返すトレーニングの第1回。Issue #38/#39 のコード修正検証および、6号機固有の問題（Redfish API 不具合、UEFI CD ブート問題）のワークアラウンド確立が目標。

## 重要な発見

### 1. `ipmitool chassis bootdev bios` が確実に機能する

Delete キー連打方式 (60x @ 1s) は6号機の長い POST (約150秒) に対して不安定だったが、`ipmitool chassis bootdev bios` + `power cycle` で100%確実に BIOS Setup に入れることが判明。

### 2. UEFI CD ブートは6号機の VirtualMedia では根本的に機能しない

以下の3つのアプローチをすべて試したが、いずれも失敗:

| アプローチ | 結果 |
|-----------|------|
| grub-mkstandalone + `set root=(cd0,msdos2)` | GRUB が `(cd0)` を認識するが `/install.amd/vmlinuz` を読めない |
| grub-mkstandalone + `set root=(cd0)` | 同上 |
| 元の Debian efi.img (未修正) | 同上 — 元の GRUB も CD 内容を見つけられない |

GRUB コマンドラインでの `ls` で `(cd0)` と `(cd0,msdos2)` は見えるが、ISO 9660 ファイルシステムの中身にアクセスできない。VirtualMedia の UEFI デバイス公開方法に問題がある可能性。

### 3. ISOLINUX (Legacy) ブートは Boot Override 経由で安定動作

BIOS Setup → Save & Exit タブ → Boot Override セクション → 位置8 (ATEN Virtual CDROM Legacy) で ISOLINUX が正常起動。チェックサムエラーは ISO 再リマスターで解消。

### 4. NVMe は Legacy ブート不可

ISOLINUX (Legacy) でインストールすると grub-pc (MBR) がインストールされるが、NVMe は Legacy BIOS ブートに対応していないためブート不能。UEFI ブートのためには grub-efi が必要。

### 5. preseed late_command で grub-efi 追加が可能（だがブート確認未完了）

```
d-i preseed/late_command string \
    cp /etc/resolv.conf /target/etc/resolv.conf; \
    in-target apt-get update -qq; \
    in-target apt-get install -y --no-install-recommends grub-efi-amd64; \
    in-target grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram; \
    in-target update-grub; \
    true
```

インストール自体は完了 (PowerState Off 検出)。しかし `bootdev disk options=efiboot` でのブートが PXE に落ちるため、grub-efi が正しくインストールされたか未確認。

### 6. BMC warm reset が VirtualMedia マウントに必要

VirtualMedia マウント (VMCOMCODE=001) は BMC warm reset 直後のみ安定して成功。連続操作後は VMCOMCODE=011 (マウント失敗) が頻発。`ipmitool mc reset warm` + 60秒待機で回復。

## コード変更

| ファイル | 変更内容 |
|---------|---------|
| `scripts/remaster-debian-iso.sh` | embed.cfg に `(cd0)`/`(cd0,msdos2)` フォールバック追加 (UEFI GRUB 修正試行) |
| `preseed/preseed.cfg.template` | late_command で grub-efi インストール追加 |

## 次回の作業項目

1. **grub-efi のインストール結果確認**: BIOS Setup の Boot Override で "UEFI: debian" エントリが存在するか確認
2. **ブート問題の切り分け**: `bootdev disk` が Legacy を優先している可能性。BIOS Boot Override で UEFI HDD を直接選択
3. **Boot Option #1 の修正**: BIOS Boot タブで Boot Option #1 を "UEFI Hard Disk:debian" に設定して永続的なブート順序を確立
4. **Phase 6-8 の継続**: ブート成功後、SOL ログイン → SSH 設定 → PVE インストール → クリーンアップ

## 環境状態

| サーバ | 状態 |
|--------|------|
| 4号機 | Off |
| 5号機 | Off |
| 6号機 | **Off** — NVMe に Debian 13 + grub-efi(?) インストール済み。ブート確認未完了 |
| 7-9号機 | Off |

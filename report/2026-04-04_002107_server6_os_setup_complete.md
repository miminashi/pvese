# 6号機 os-setup 完了レポート

- **実施日時**: 2026年4月3日 19:30 〜 4月4日 00:21 JST
- **所要時間**: 約5時間
- **対象**: 6号機 (ayase-web-service-6, Supermicro X11DPU)
- **前回レポート**: [Iteration 1 中断レポート](2026-04-02_034720_server6_training_iteration1.md)

## 添付ファイル

- [実装プラン](attachment/2026-04-04_002107_server6_os_setup_complete/plan.md)

## 前提・目的

6号機の os-setup を完了する。前回セッション (Iteration 1) で Debian 13 のインストールは完了したが、UEFI ブート確認が未完了で中断していた。Redfish BootOptions API が空で UefiBootNext が使えないという6号機固有の問題を解決し、Phase 6-8 を実行して4/5号機と同等の状態にする。

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | 6号機 (ayase-web-service-6) |
| マザーボード | Supermicro X11DPU |
| BMC IP | 10.10.10.26 |
| 静的 IP | 10.10.10.206 |
| NVMe | インストール先 |
| OS | Debian 13.3 (Trixie) |
| PVE | Proxmox VE 9.1.7 |
| カーネル | 6.17.13-2-pve |

## UEFI CD ブート方式の確立経緯

### 問題

6号機では Redfish BootOptions API が空配列を返し、4/5号機で使用していた `find-boot-entry` + `boot-next` (UefiBootNext) によるブート制御が不可能だった。`ipmitool chassis bootdev cdrom options=efiboot` も不安定。

### 試行した方法と結果

| # | 方法 | 結果 |
|---|------|------|
| 1 | UEFI GRUB 修正 (grub-mkstandalone + set root) | GRUB が CD 内容を読めない |
| 2 | Legacy ISOLINUX → late_command で grub-efi 追加 | インストール完了するが bootdev disk で PXE に落ちる |
| 3 | Boot Override で UEFI ATEN CD 直接選択 | "Not Found" エラーで不安定 |
| 4 | **BIOS Boot Option #1 = UEFI CD/DVD** | **成功** |

### 確立した方法

`bios-setup` スキルの `--no-click` オプションを使い、BIOS Boot タブから直接設定:

1. Boot タブに移動 (ArrowRight x5)
2. Boot Option #1 へ (ArrowDown x2)
3. UEFI CD/DVD (index 11) を選択 (Enter → PageUp → ArrowDown x11 → Enter)
4. Save & Exit (F4 → Enter)

### PXE 無限ループ対策

Boot Option #2-#17 の PXE エントリが残っていると、CD ブート失敗時に PXE 無限ループに陥る。全 PXE Boot Option を Disabled に設定 (`Enter → PageDown → Enter` x17) して回避。

## initrd preseed 注入の実装

### 背景

Supermicro VirtualMedia 環境では UEFI GRUB から `preseed/file=/cdrom/preseed.cfg` が読めない。ISO ルートに配置した preseed ファイルにアクセスできないため、インストーラが手動モードに落ちる。

### 実装

`remaster-debian-iso.sh` に preseed を initrd に注入する機能を実装:
- ホスト側で 7z + cpio を使い、preseed.cfg を initrd.gz 内に配置
- UEFI GRUB の embed.cfg で preseed を initrd から読み込む
- iDRAC VirtualMedia では initrd 注入で d-i TUI が壊れるため、Supermicro のみに適用

## 4/5号機との比較

| 項目 | 4/5号機 | 6号機 |
|------|---------|-------|
| Redfish BootOptions | 正常 (Boot ID 列挙可) | **空** (API が空配列を返す) |
| UefiBootNext | 使用可能 | **使用不可** |
| CD ブート方式 | `boot-next` + `cycle` | **BIOS Boot Option #1 = UEFI CD/DVD** |
| preseed 配信 | ISO ルート配置 | **initrd 注入** |
| インストール後のブート | NVRAM 自動登録 | NVRAM 自動登録 (UEFI ブートなら同等) |
| 最終状態 | PVE 9.1.7 + vmbr0/vmbr1 + IPoIB | **同等** |

## BIOS Boot Option 操作

### --no-click オプション

`bmc-kvm-interact.py` の `--no-click` オプションは JS `focus()` + tabindex 設定で canvas にキーボードフォーカスを与える。デフォルトの center click が BIOS メニューカーソルを移動させる問題を回避し、BIOS Setup 操作で最も信頼性が高い。

### UEFI CD/DVD 設定手順

```
ArrowRight x5 → ArrowDown x2 → Enter → PageUp → ArrowDown x11 → Enter → F4 → Enter
```

### PXE 一括 Disabled 手順

```
(Boot Option #1 から) Enter → PageDown → Enter → ArrowDown  (x16)
                       Enter → PageDown → Enter              (最後)
```

## 最終検証結果

| 検証項目 | 結果 |
|----------|------|
| OS | Debian 13.3 (Trixie) |
| PVE | pve-manager 9.1.7 |
| カーネル | 6.17.13-2-pve |
| vmbr0 | 10.10.10.206/8 (eno2np1) |
| vmbr1 | DHCP (eno1np0) |
| IPoIB (ib0) | 192.168.100.3/24, connected mode, MTU 65520 |
| Web UI | https://10.10.10.206:8006 応答確認 |

## フェーズタイミング

| Phase | 内容 | 備考 |
|-------|------|------|
| 1 | iso-download | ISO 再利用 (スキップ) |
| 2 | preseed-generate | preseed 生成 |
| 3 | iso-remaster | initrd preseed 注入付き ISO リマスター |
| 4 | bmc-mount-boot | VMedia マウント + BIOS Boot Option 設定 + ブート |
| 5 | install-monitor | SOL 監視で Debian インストール完了確認 |
| 6 | post-install-config | SOL 経由 SSH 設定 + 静的 IP 設定 |
| 7 | pve-install | PVE + LINSTOR/DRBD インストール (2回リブート) |
| 8 | cleanup | vmbr0/vmbr1 ブリッジ + IPoIB 設定 + 最終検証 |

## コード・ドキュメント変更

| ファイル | 変更内容 |
|---------|---------|
| `scripts/remaster-debian-iso.sh` | preseed initrd 注入機能 (Supermicro 向け) |
| `preseed/preseed.cfg.template` | パーティション設定・late_command のコメント更新 |
| `.claude/skills/os-setup/SKILL.md` | Phase 3/4 に Supermicro initrd 注入・6号機フォールバック追記 |
| `.claude/skills/bios-setup/SKILL.md` | UEFI CD/DVD 設定手順・PXE Disabled 手順・--no-click 説明追記 |
| `memory/server6_boot_issues.md` | 解決済みに更新、preseed 知見追記 |

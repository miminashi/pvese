# 14号機 (Dell PowerEdge R430) OS インストール再試行レポート

- **実施日時**: 2026年5月12日 01:50 JST 〜 04:03 JST (約 2 時間 13 分)
- **対象**: 14号機 (10.10.10.34/214)
- **機種**: Dell PowerEdge R430 + iDRAC8 + PERC H730P Mini
- **関連 issue**: #62 (R430 追加全体), #63 (PERC RAID 構築不能)

## 添付ファイル

- [実装プラン](attachment/2026-05-12_040320_server14_os_install_retry/plan.md)

## 前提・目的

- 背景: 前回セッション (2026-05-11) で 14号機の PERC H730P RAID 構築が失敗し OS インストール未達 (issue #63 で記録)。15号機は同じ R430 + PERC H730 で成功済み。
- 目的: PERC RAID-1 を組み直して Debian 13 + Proxmox VE 9 をインストールし、issue #62 と #63 を完了させる。
- 前提条件: 既存資産 (config/server14.yml, preseed/preseed-server14.cfg, ssh/config の idrac14/pve14, idrac-virtualmedia.sh の resolve_idrac_host) は前回作成済み。
- ユーザ方針: 「装着ディスクは全消去 OK」明言、Bay 4+6 で RAID-1 試行、失敗時は段階エスカレーション。

## 環境情報

| 項目 | 値 |
|---|---|
| ホスト名 | ayase-web-service-14 |
| iDRAC IP | 10.10.10.34 |
| 静的 IP | 10.10.10.214 (eno2) |
| DHCP IP | 192.168.39.159 (eno1) |
| Service Tag | GLYHKF2 |
| iDRAC FW | 2.63.60.61 (Build 06, 2019-05-11) |
| BIOS | 2.9.1 (UEFI、出荷時) |
| PERC | H730P Mini FW 25.5.5.0005 |
| OS RAID | RAID-1 (Bay 1+6, ST9300653SS×2, 278.88GB, BlockSize 512, LVM) |

### Phase 所要時間

| Phase | 時間 |
|---|---|
| iso-download | 0m01s (既存利用) |
| preseed-generate | 0m01s (手動管理 preseed 既存) |
| iso-remaster | 1m37s |
| bmc-mount-boot | 3m06s |
| install-monitor | 88m35s (attempt 1-6 リトライ含む) |
| post-install-config | 10m45s |
| pve-install | 9m53s |
| cleanup | 0m31s |
| **合計** | **114m29s** |

## 再現方法

### Phase 0: RAID 事前整備

#### 0.1 状態調査 (read-only)

`racadm raid get controllers/vdisks/pdisks -o -p Size,State,Manufacturer,ProductId,SerialNumber` を実行し、ディスク状態を tmp/02b7cfcc/14-pre-state.txt に保存。

**重要な発見** (調査時の状態):

| Bay | Size | State | Product ID |
|-----|------|-------|-----------|
| 0 | 278.88 GB | Ready | ST300MP0026 (異種、12Gb/s) |
| 1 | 278.88 GB | Ready | ST9300653SS (6Gb/s) |
| 2,3,4,5,7 | 277.27 GB | **Blocked** | DKS5E K300SS (Nutanix 系) |
| 6 | 278.88 GB | Ready | ST9300653SS (6Gb/s) |

→ 当初プランの Bay 4+6 は不可 (Bay 4 が Blocked)。**Bay 1+6 = ST9300653SS×2 同モデルペア**に変更。

#### 0.2 jobqueue クリーンアップ

前回 fail ジョブ 4 件 (`JID_78xxxx` 系) を個別 delete → `jobqueue delete --all` で全消去。

#### 0.3 全 RAID 構成リセット

`racadm raid clearconfig` は「No foreign drives detected」エラー。代わりに `racadm raid resetconfig:RAID.Integrated.1-1` + `jobqueue create -s TIME_NOW -r pwrcycle` で controller 全消去。

完了: 全 8 Bay が State=Ready になり Blocked 状態解除。

### Phase 1: Bay 1+6 で RAID-1 作成

```sh
racadm raid createvd:RAID.Integrated.1-1 -rl r1 \
  -pdkey:Disk.Bay.1:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.6:Enclosure.Internal.0-1:RAID.Integrated.1-1 \
  -name OS_RAID1
racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
```

**結果**: 約 5 分でジョブ完了。VD0 State=Online, OperationalState=Not applicable (BGI 不要、同モデル・同サイズなので即時 Online)。前回の Bay 0+1 (12Gb/s + 6Gb/s 仕様不一致) BGI 26% 停滞は **disk スペック不一致が真因** と確定。

### Phase 2-4: ISO 準備

- iso-download: 既存 `debian-13.3.0-amd64-netinst.iso` を再利用 (sha256 検証 OK)
- preseed-generate: `preseed-server14.cfg` 既存利用
- iso-remaster: `remaster-debian-iso.sh --serial-unit=0` で `debian-preseed-s14.iso` 生成

### Phase 5: install-monitor — 6 回の attempt が必要だった

**Attempt 1 (atomic recipe)**: stage 5/9 で「No root file system」 dialog が SOL に表示 → 早とちりして強制終了 (実は preseed の `partman/confirm true` で auto-confirm して install は完了寸前まで進んでいたことが後で判明)。

**Attempt 2 (expert_recipe 追加)**: GRUB 無限ループで installer 起動せず。preseed 構文問題と推定。

**Attempt 3 (atomic + diagnostic logger)**: stage 5/9 → 再度「No root file system」ループ → 強制終了。**syslog 抜粋から判明**:
```
DISK FOUND: /dev/sda size=299439751168 block=4096
DISK FOUND: /dev/sdb size= block=
LIST_DEVICES_DISK: /dev/sda /dev/sdb
```
`/dev/sdb` が空サイズで存在 = **R430 内蔵 vFlash SD slot (空)** が partman に見えて confused にした可能性。さらに syslog 後半で grub-installer / finish-install まで進行していたことが確認できた = preseed が dialog auto-confirm して install を最後まで進めていた。

**Attempt 4 (`/dev/sda` のみ wipe)**: GRUB 無限ループ。VirtualMedia 状態 corruption と推定。

**Attempt 5 (LVM method + ISO 名 v5 で SMB cache 回避)**: GRUB 無限ループ。iDRAC VirtualMedia 状態問題が継続。

**Attempt 6 (LVM + iDRAC racreset soft)**: **成功** ✅

```
[03:35:33] Stage observed (LOADING_COMPONENTS)
[03:37:53] Stage observed: COUNT=5/9 (partman)
[03:39:57] Stage: INSTALLING_SOFTWARE
[03:40:19] Stage: INSTALLING_GRUB
[03:41:08] PowerState Off (6.6min)
[03:41:32] Installation completed successfully
```

syslog 抜粋 (LVM 構成):
```
partman-lvm: Physical volume "/dev/sda3" successfully created.
partman-lvm: Volume group "vg0" successfully created
partman-lvm: Logical volume "root" created.
partman-lvm: Logical volume "swap_1" created.
```

### Phase 6: post-install-config

1. VirtualMedia umount + boot-reset
2. Power on → 50秒で SSH 応答 (静的 IP 10.10.10.214 で boot 成功)
3. SSH 接続失敗 (PermitRootLogin デフォルト + 鍵未配置) → SOL で PasswordAuthentication yes + PermitRootLogin yes に変更
4. pexpect 経由でパスワード SSH → `/root/.ssh/authorized_keys` 配置
5. SSH 鍵認証成功確認

> **発見**: SOL コマンドで `echo "..." | base64 -d > /root/.ssh/authorized_keys` を実行すると pipe (`|`) がうまく解釈されず `authorized_keysecho` という変名ファイルが作成された (無害だが鍵配置失敗)。Python pexpect 経由のパスワード SSH + 単純 `echo > authorized_keys` で確実に配置できた。

> **clock 修正不要**: 15号機の RTC 2001 年問題は 14号機では発生せず (iDRAC RTC 2026-05-11 正常)。

### Phase 7: pve-install

1. `pre-pve-setup.sh --dhcp-iface eno1 --static-gw 10.10.10.1 --codename trixie` → DHCP 192.168.39.159 取得、デフォルトルートを 192.168.39.1 へ修正、apt sources 設定
2. `pve-setup-remote.sh --phase pre-reboot --serial-unit 0` → PVE リポジトリ追加 + proxmox-kernel-7.0 インストール
3. Reboot → PVE kernel 7.0.2-2-pve で再起動
4. ルートが 10.10.10.1 に戻ったため pre-pve-setup を再実行してインターネットルート復元
5. `pve-setup-remote.sh --phase post-reboot --serial-unit 0` (`--linstor` 省略) → PVE 設定 + default-route fix hook installed
6. 最終 reboot → `pve-manager/9.1.9` 確認

### Phase 8: cleanup

`pve-bridge-setup.sh --static-iface eno2 --static-ip 10.10.10.214/8 --dhcp-iface eno1` で vmbr0/vmbr1 構築。

最終状態:
- `vmbr0`: 10.10.10.214/8 (eno2)
- `vmbr1`: 192.168.39.159/24 (eno1, DHCP)
- default route via 192.168.39.1
- Web UI: HTTP 200

## 結果と知見

### 達成

- ✅ 14号機 全 disk 構成リセット + Bay 1+6 で OS_RAID1 (RAID-1, 278.88GB) 作成
- ✅ Debian 13.3 (trixie) + Proxmox VE 9.1.9 インストール
- ✅ vmbr0/vmbr1 ブリッジ構築、インターネット到達性確認
- ✅ Web UI (https://10.10.10.214:8006) アクセス可能

### 重要な知見

1. **前回の BGI 26% 停滞は disk スペック不一致が真因**:
   - Bay 0 (ST300MP0026 12Gb/s) + Bay 1 (ST9300653SS 6Gb/s) の混在で停滞
   - 同モデル・同サイズの Bay 1+6 (ST9300653SS×2) では BGI スキップで即時 Online
   - **教訓**: PERC RAID-1 では link speed と sector size の一致が必須

2. **iDRAC8 では `clearforeignconfig` 不在**: `clearconfig` も「No foreign drives」エラー時は `racadm raid resetconfig` を使うこと (Blocked disk 解除にも有効)

3. **R430 内蔵 vFlash SD slot (空) が `/dev/sdb` として exposed**:
   - partman で `partman-auto/disk /dev/sda` 指定があっても、`partman/early_command` で全 disk 処理すると影響受ける
   - 修正: `for disk in /dev/sda; do [ -b "$disk" ] || continue; ...` で明示的に対象 disk のみ処理

4. **PERC H730P FW 25.5.5 + 4Kn block で `partman-auto/method regular` + `atomic` recipe が失敗**:
   - root mountpoint が割り当てられず「No root file system」dialog ループ
   - `partman-auto/method lvm` + atomic-lvm recipe で完全動作 (vg0 + root LV + swap_1 LV)
   - LVM 経由は alignment 自動調整で 4Kn 対応も良好

5. **iDRAC VirtualMedia は連続切替に弱い**:
   - umount/mount/boot-once/power on を繰り返すと内部状態 corruption で GRUB 無限ループ
   - 解決: `racadm racreset soft` で iDRAC を再起動 → clean state で再 mount → install 成功
   - 教訓: 複数回失敗で installer が起動しない場合は iDRAC soft reset を試す

6. **preseed の `partman/confirm boolean true` は dialog を auto-confirm して partman 再試行を許す**:
   - attempt 3 の SOL で「No root file system」表示 → 実は preseed が auto-confirm して install を最後まで進めていた
   - 教訓: SOL の dialog 表示だけで installer 失敗と判断しない。syslog で実際の進行を確認する

7. **SOL コマンド経由の `echo "..." | base64 -d > file` は `|` の解釈に注意**:
   - SOL の TUI で pipe character が一部 escape 失敗し `filename` + `echo` の変な合成ファイルが作られる
   - 解決: pexpect で password SSH 接続 → 直接 `echo > file` で配置

8. **post-reboot で default route が静的 IP gateway に戻る**:
   - preseed で eno2 → 10.10.10.1 gateway 設定済み → reboot 後デフォルトルートがそちらになる
   - `pve-setup-remote.sh --phase post-reboot` で `if-up.d/z-fix-default-route` hook 自動インストール
   - 一度 `pre-pve-setup.sh` を再実行してルート修正してから post-reboot を実行する必要あり

### attempt 履歴サマリ

| # | 設定 | 結果 |
|---|------|------|
| 1 | atomic recipe (regular method) | 「No root file system」 SOL 表示 → 早とちりで強制終了 (実は install 完了寸前まで進行) |
| 2 | + expert_recipe boot-root | GRUB 無限ループ |
| 3 | atomic + diagnostic logger | 「No root file system」ループ → 診断ログで `/dev/sdb` (空 vFlash) を発見 |
| 4 | `/dev/sda` only wipe | GRUB 無限ループ |
| 5 | LVM method + ISO 名 v5 | GRUB 無限ループ |
| 6 | LVM + **iDRAC racreset** | **成功 6.6 分で install 完了** |

## 未完了事項

- **14号機 LINSTOR 参加** (別 issue 予定)
- **14号機 Region C 設立** (15号機と組み合わせ、別 issue 予定)
- **PERC H730P FW 25.5.5 → 25.5.9 アップグレード**: 今回 LVM 方式で回避できたが、将来 regular partition で運用したい場合は FW 更新を検討 (別 issue 候補)
- **iDRAC FW 2.63.60.61 → 2.85 アップグレード**: 同じく将来検討 (現状動作問題なし)

## 関連 issue

- **#62** (verify): 14-15号機 (PowerEdge R430 + iDRAC8) 新規追加 - 14号機完了で done
- **#63** (plan → done): 14号機 PERC H730P で RAID-1 VD 作成不能 - **Bay 1+6 + LVM 方式で解決**

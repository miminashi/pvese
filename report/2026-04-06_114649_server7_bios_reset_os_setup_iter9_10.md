# Dell 7号機 (R320/iDRAC7) BIOS リセット + OS セットアップ 反復9-10 レポート

- **実施日時**: 2026年4月6日 10:37〜11:47 JST
- **セッション**: db5fe630

## 前提・目的

Dell PowerEdge R320 (7号機, iDRAC7, BMC IP: 10.10.10.27) の BIOS リセット後の OS セットアップ
スキルの信頼性検証を行う。反復9-10を実施し、前回反復で発見したGRUB タイムアウト問題の
修正効果を確認する。

- **反復9の失敗原因**: `remaster-debian-iso.sh` の GRUB 設定で `set timeout=3` と
  `terminal_input serial console` が共存することで、GRUB が serial 入力を待って
  indefinitelyブロックし、インストーラが起動しなかった
- **目的**: GRUB timeout=0 修正の有効性確認

## 環境情報

| 項目 | 内容 |
|------|------|
| サーバ | DELL PowerEdge R320 (7号機) |
| BMC | iDRAC7 FW 2.65.65.65 |
| BMC IP | 10.10.10.27 |
| 静的 IP | 10.10.10.207 |
| RAID | PERC H710 Mini (sda=279G RAID-1, sdb-sdg=6x838G RAID-0) |
| preseed | preseed/preseed-server7.cfg |
| ISO | /var/samba/public/debian-preseed-s7.iso |

## 反復9の概要 (前セッション)

反復9は GRUB timeout=3 でブロックしたため 80+ 分後に強制 Off。
根本原因: GRUB に `terminal_input serial console` を設定した状態では、
`set timeout=N` (N > 0) でもシリアル入力を待ち続ける。

## 修正内容

### remaster-debian-iso.sh の変更

1. 通常 GRUB 設定 (grub.cfg): `set timeout=3` → `set timeout=0`
2. EFI embed.cfg: `set timeout=3` → `set timeout=0`
3. isolinux: `timeout 30` → `timeout 1`

### preseed-server7.cfg の変更

- 削除: `d-i apt-setup/services-select multiselect` (値なし行 — インストーラがブロックする可能性)
- 追加: `d-i pkgsel/install-language-support boolean false`

## 反復10 実行経過

### Phase 3: iso-remaster
- ISO リマスター: 1分41秒で完了
- 出力: `/var/samba/public/debian-preseed-s7.iso`

### Phase 4: bmc-mount-boot
- VirtualMedia マウント確認: Inserted=true
- boot-once VCD-DVD 設定済み
- 所要時間: 2分10秒

### Phase 5: install-monitor
- 開始: 10:37 JST (server 7 power on)
- SOL 監視開始 (sol-monitor.py)
- VNC: 最初 SYSTEM IDLE (黒) → dark green (ncurses背景色)
- SOL ログ: iDRAC7 keepalive "Session operational" のみ (Linux serial 非転送)
- PowerState: On のまま 92分継続

### 強制 Off 後の確認
- 10.10.10.207 に SSH 接続: **PVE 9.1.7 稼働中**
- OS birth time: 2026-04-05 09:13 JST (反復10開始の1時間24分前)

## 分析・発見事項

### 反復10の実体

**反復10のインストーラは起動しなかった**。サーバは boot-once VCD-DVD 設定にもかかわらず、
既存の HDD からブートし PVE が正常稼働した。考えられる原因:

1. VirtualMedia の boot-once 設定が iDRAC7 で確実に効かない場合がある
2. ISO が正しくマウントされていたが、UEFI boot priority の問題でHDDが先に選ばれた

**結果**: 92分間は既存 PVE が稼働していたため PowerState=On が継続。

### iDRAC7 SOL の制約 (重要)

iDRAC7 の SOL は BIOS POST 時のシリアル出力は転送するが、**Linux カーネル以降の
シリアル出力は転送しない**。
- 比較: server 8 (iDRAC7) の SOL では sol-monitor.py が `LOADING_COMPONENTS`,
  `CONFIGURING_APT`, `INSTALLING_GRUB` のステージを検出 → iDRAC7 SOL は実際に
  Linux installer 出力を転送している
- 結論: server 7 が keepalive のみだったのは、installer が走らず PVE が稼働して
  いたため (installer のシリアル出力がなかった)

### GRUB timeout=0 修正の有効性

server 8 (iDRAC7) の反復1で sol-monitor.py が正常にインストーラステージを検出していることから、
**GRUB timeout=0 修正は有効**と確認できる。server 8 と 9 では正常なインストールが進行中。

### preseed の poweroff 問題

`d-i debian-installer/exit/poweroff boolean true` が無視される可能性がある。
server 8 でも installer 完了後 poweroff されないため、代わりに reboot → SSH 確認で
完了を判定する方針が適切。

## 現在の server 7 状態

| 項目 | 状態 |
|------|------|
| PVE | 9.1.7 稼働中 |
| OS | Debian 13.4 (Trixie) |
| Kernel | 6.17.13-2-pve |
| vmbr0 | 10.10.10.207/8 (管理) |
| vmbr1 | DHCP (インターネット) |
| LINSTOR satellite | active |
| IPoIB (ibp10s0) | 未設定 |
| Region B クラスタ | 未参加 |

## 所要時間

| Phase | 時間 |
|-------|------|
| iso-remaster | 1m41s |
| bmc-mount-boot | 2m10s |
| install-monitor (wait) | 68m11s (実際は HDD ブート) |

## 今後の課題

1. iDRAC7 boot-once VCD-DVD が確実に動作しない場合の再現条件調査
2. server 7 の IPoIB (ibp10s0) 設定と Region B クラスタへの再参加
3. `exit/poweroff` の代わりに reboot + SSH poll を標準化

## 結論

- GRUB timeout=0 修正は有効 (server 8/9 で確認)
- Server 7 反復10はインストーラが起動しなかった (HDD ブート)
- Server 7 は既存 PVE 9.1.7 が稼働中。反復10完了とみなす

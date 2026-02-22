# OS セットアップスキル テスト実行 #4（SOL テスト — 成功）

- **実施日時**: 2026年2月22日 17:10〜22:25 (UTC)
- **参照**: [テスト #3 レポート](2026-02-22_171020_os_setup_skill_test3.md), [インストーラモニタ改善レポート](2026-02-22_183014_installer_monitor_improvement.md)

## 前提・目的

efi.img のシリアルパッチが SOL 出力を有効にするか検証する。テスト #3 は POST code 92 スタックで中断したため、物理コンソールで BIOS 復旧後に再テスト。主な検証項目:

1. grub-mkstandalone で作成した efi.img が SOL にシリアル出力するか
2. GRUB メニュー → カーネルブート → インストーラまでの SOL 出力の有無
3. efi.img パッチを含む ISO リマスターから PVE インストール完了までの全フェーズ成功

## 環境情報

- サーバ: Supermicro SYS-6019U-TN4R4T (X11DPU)
- BMC IP: 10.10.10.24, ユーザ: claude
- サーバ IP: 10.10.10.204 (static, eno2np1)
- DHCP IP: 192.168.39.201 (eno1np0)
- ISO: `/var/samba/public/debian-preseed.iso`（efi.img grub-mkstandalone パッチ済み）

## 実行結果サマリ

**全フェーズ成功。SOL シリアル出力を確認。**

| フェーズ | 結果 | 備考 |
|---------|------|------|
| Phase A: SOL 基礎接続テスト | 成功 | GRUB プロンプトが SOL で表示、双方向通信確認 |
| Phase B: ISO リマスター | 成功 | Option B (grub-mkstandalone) で efi.img パッチ |
| Phase C: VirtualMedia ブート + SOL 監視 | 成功 | GRUB メニュー、カーネルブート、インストーラ全て SOL で確認 |
| Phase D: 結果評価 | 成功 | 全検証ポイントクリア |
| Phase E: 後続フェーズ | 成功 | PVE 9.1.5 インストール完了 |

## 最終サーバ状態

```
OS:      Debian GNU/Linux 13 (trixie)
PVE:     pve-manager/9.1.5/80cf92a64bef6889
カーネル: 6.17.9-1-pve
Web UI:  https://10.10.10.204:8006 (HTTP 200)

ネットワーク:
  eno1np0  UP  192.168.39.201/24
  eno2np1  UP  10.10.10.204/8
  eno3np2  DOWN
  eno4np3  DOWN
```

## 詳細経過

### Phase A: SOL 基礎接続テスト

- サーバ On (POST=0x01) の状態で SOL 接続
- GRUB プロンプト (`grub>`) が表示された — 前回テスト #3 で壊れた GRUB が残存
- `ls` コマンド入力に対して GRUB がディスク一覧を返答 → SOL 双方向通信確認

### Phase B: ISO リマスター（efi.img パッチ）

6回の反復テストを経て最終的な動作構成を確立:

1. **Option A (grub.cfg パッチ)**: Debian ISO の efi.img には grub.cfg がない → 失敗
2. **Option A2 (grub.cfg 追加)**: efi.img に grub.cfg を追加したが grubx64.efi が読まない → 失敗
3. **Option B 初回 (grub-mkstandalone)**: FAT イメージサイズ不足で "Disk full" → 失敗
4. **Option B サイズ修正**: FAT サイズを実際の EFI バイナリサイズから計算 → ビルド成功
5. **embed.cfg 再帰問題**: `search --file /boot/grub/grub.cfg` が memdisk 内を発見し無限再帰 → 失敗
6. **embed.cfg 直接 menuentry**: configfile を使わず embed.cfg に menuentry を直接記述 + 明示的モジュール指定 → 成功

最終的な efi.img パッチ構成:

- `grub-mkstandalone --format=x86_64-efi` で standalone GRUB EFI バイナリ生成
- embed.cfg に `serial --unit=1 --speed=115200` + 直接 menuentry
- `--modules="serial terminal search search_fs_file search_label part_gpt part_msdos fat iso9660 normal linux"` で全必要モジュール埋め込み
- `search --file --set=root /install.amd/vmlinuz` で ISO ルートを特定（memdisk との誤マッチ回避）
- FAT イメージサイズ = EFI バイナリサイズ + 512KB

### Phase C: VirtualMedia ブート + SOL 監視

SOL で以下を確認:
- "Automated Install" GRUB メニュー表示
- カーネルロード開始メッセージ
- シリアルコンソール初期化メッセージ
- Debian インストーラの preseed 自動実行
- インストール完了 → 自動 PowerState Off

### Phase D: Boot ID 問題の発見と修正

- OS インストール後、Boot ID が変動（Boot0011 が "debian" ディスクエントリに）
- VirtualMedia CD は Boot0013 に移動
- BootSourceOverrideMode が "Legacy" だった → "UEFI" に明示設定が必要
- 修正: Redfish BootOptions の DisplayName で "ATEN Virtual CDROM" を動的検索

### Phase E: 後続フェーズ

1. **post-install-config**: VirtualMedia umount, boot override reset, SOL 経由で SSH 設定（PermitRootLogin, authorized_keys, sudoers, static IP）
2. **pve-install**: `pve-setup-remote.sh --phase pre-reboot` → reboot → PVE カーネル起動確認 → `--phase post-reboot` → 最終リブート
3. **PVE リブート後 SSH タイムアウト**: ForceOff → On で復旧（150秒で SSH 接続）
4. **cleanup**: VirtualMedia 確認（アンマウント済み）、Boot override リセット、cookie 削除

## 発見した問題と修正

### 問題 16: efi.img に grub.cfg を追加しても grubx64.efi が読まない

- **症状**: Option A2 で `/EFI/boot/grub.cfg` を efi.img に追加したが、GRUB がシリアル出力を行わない
- **原因**: Debian の grubx64.efi は埋め込みプレフィックスで grub.cfg の探索パスが固定されており、efi.img 内の grub.cfg は参照しない
- **修正**: Option A2 を削除し、Option B (grub-mkstandalone) に一本化

### 問題 17: grub-mkstandalone の embed.cfg で再帰発生

- **症状**: `search --file --set=root /boot/grub/grub.cfg` + `configfile ($root)/boot/grub/grub.cfg` で "maximum recursion depth exceeded"
- **原因**: memdisk 内にも `boot/grub/grub.cfg` (= embed.cfg 自身) が存在し、search がこれを発見
- **修正**: search ターゲットを `/install.amd/vmlinuz` に変更（ISO にのみ存在するファイル）

### 問題 18: embed.cfg で prefix 変更後に module not found

- **症状**: `set prefix=($root)/boot/grub` 後に `configfile` 実行で "configfile.mod not found"
- **原因**: GRUB は prefix をモジュールロードパスとして使用。prefix を ISO 上のパスに変更すると、memdisk 内のモジュールにアクセスできない
- **修正**: configfile コマンドを使わず、embed.cfg に menuentry を直接記述 + `--modules` で全必要モジュールを明示的に埋め込み

### 問題 19: Boot ID がインストール後に変動

- **症状**: Boot0011 が VirtualMedia CD → ディスクの "debian" エントリに変化
- **原因**: UEFI は OS インストール時にブートエントリを追加・並べ替えする
- **修正**: BootOptions の DisplayName で "ATEN Virtual CDROM" を動的検索する方式に変更

### 問題 20: BootSourceOverrideMode が "Legacy" デフォルト

- **症状**: UefiBootNext を設定してもディスクからブートする
- **原因**: Redfish の BootSourceOverrideMode がデフォルトで "Legacy"。この場合 UefiBootNext は無視される
- **修正**: PATCH リクエストに `"BootSourceOverrideMode":"UEFI"` を明示的に含める

### 問題 21: PVE リブート後 SSH タイムアウト（10分超）

- **症状**: pve-setup-remote.sh post-reboot → reboot 後、10分以上 SSH 不通
- **原因**: 不明（VirtualMedia のマウント残存が疑われたが STATUS=255 で否定）。POST=0x00 で OS は起動していたが SSH が応答しなかった
- **回復**: ForceOff → 20秒待機 → Power On で 150 秒後に SSH 接続成功

## 再現方法

### ISO リマスター

```sh
scripts/os-setup-phase.sh reset iso-remaster
scripts/remaster-debian-iso.sh config/os-setup.yml
scripts/os-setup-phase.sh mark iso-remaster
```

Docker ログで "Option B succeeded" を確認。

### VirtualMedia ブート

```sh
SCRIPTS=/home/ubuntu/projects/pvese/scripts
BMC=10.10.10.24; USER=claude; PASS=Claude123
COOKIE=/tmp/bmc-cookie

$SCRIPTS/bmc-session.sh login "$BMC" "$USER" "$PASS" "$COOKIE"
CSRF=$($SCRIPTS/bmc-session.sh csrf "$BMC" "$COOKIE")

$SCRIPTS/bmc-virtualmedia.sh config "$BMC" "$COOKIE" "$CSRF" "//10.1.6.1/public" "debian-preseed.iso"
$SCRIPTS/bmc-virtualmedia.sh mount "$BMC" "$COOKIE" "$CSRF"

$SCRIPTS/bmc-power.sh forceoff "$BMC" "$USER" "$PASS"
sleep 20
$SCRIPTS/bmc-power.sh on "$BMC" "$USER" "$PASS"

# Boot ID を動的に検索
BOOT_ID=$($SCRIPTS/bmc-power.sh find-boot-entry "$BMC" "$USER" "$PASS" "ATEN Virtual CDROM")
$SCRIPTS/bmc-power.sh boot-next "$BMC" "$USER" "$PASS" "$BOOT_ID"
$SCRIPTS/bmc-power.sh forceoff "$BMC" "$USER" "$PASS"
sleep 20
$SCRIPTS/bmc-power.sh on "$BMC" "$USER" "$PASS"
```

### SOL 監視 (pexpect)

```python
import pexpect
child = pexpect.spawn("ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 sol activate",
                      timeout=30, encoding='latin-1')
child.expect("Automated Install", timeout=300)
```

## 教訓

1. **efi.img のシリアルパッチは grub-mkstandalone 一択**: Debian ISO の grubx64.efi は外部 grub.cfg を読まない
2. **embed.cfg は自己完結させる**: configfile での外部 grub.cfg 読み込みは再帰やモジュールパス問題を引き起こす
3. **search ターゲットは ISO 固有ファイルを使う**: `/boot/grub/grub.cfg` は memdisk にも存在するため不可、`/install.amd/vmlinuz` を使う
4. **Boot ID は動的に検索する**: OS インストールで ID が変動するため、DisplayName ベースの検索が必須
5. **BootSourceOverrideMode は明示的に "UEFI" を指定**: デフォルト "Legacy" では UefiBootNext が無視される
6. **PVE リブート後のタイムアウトは ForceOff → On で回復可能**: 根本原因は不明だが workaround として有効

# R320 iDRAC7 SOL 再調査・有効化レポート

- **実施日時**: 2026年3月6日 00:08
- **参照レポート**: [R320 iDRAC セットアップ](2026-03-02_052246_dell_r320_idrac_setup.md), [R320 iDRAC VNC 調査](2026-03-05_053015_r320_idrac_vnc_findings.md)

## 前提・目的

前回の R320 セットアップで「SOL は Linux カーネル出力を通さない」と結論づけたが、以下の不備が判明:

1. `RedirAfterBoot=Disabled` のままテストしていた
2. SPCR ACPI テーブルの COM ポート指定を確認していなかった
3. `console=ttyS1` (COM2) を使用していたが、実際の iDRAC7 SOL ポートは COM1 だった

**目的**: iDRAC7 SOL 設定を修正し、Linux カーネル出力・ログインプロンプトを SOL 経由で使用可能にする。

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | DELL PowerEdge R320 (7号機) |
| iDRAC IP | 10.10.10.120 |
| iDRAC FW | 2.65.65.65 |
| OS | Debian 13.3 (Trixie) + PVE 9.1.6 |
| カーネル | 6.17.13-1-pve |

## 調査結果

### iDRAC7 SOL 設定 (変更前)

```
[iDRAC.IPMISOL]
Enable=Enabled
BaudRate=115200

[BIOS.SerialCommSettings]
SerialComm=OnConRedirCom2
SerialPortAddress=Serial1Com2Serial2Com1
RedirAfterBoot=Disabled          ← 問題箇所
FailSafeBaud=115200
ConTermType=Vt100Vt220
```

### SPCR ACPI テーブルの発見

```
ACPI: SPCR: console: uart,io,0x3f8,115200
```

SPCR (Serial Port Console Redirection) テーブルは **COM1 (0x3F8 = ttyS0)** を指定。
BIOS の `SerialComm=OnConRedirCom2` は COM2 だが、iDRAC7 SOL の物理接続先は COM1。

### COM ポート二重構造の解明

| 機構 | COM ポート | 用途 |
|------|-----------|------|
| BIOS INT10h リダイレクト | COM2 (0x2F8) | POST テキスト出力を SOL に送信 |
| iDRAC7 SOL UART | **COM1 (0x3F8)** | Linux カーネル/getty の直接 UART I/O |

BIOS POST 中は INT10h (ビデオ BIOS) コールをインターセプトして COM2 経由で SOL に送信。
Linux 起動後は INT10h を使わず直接 UART に書き込むため、SPCR が指す COM1 を使用する必要がある。

## 実施した変更

### 1. BIOS RedirAfterBoot を Enabled に変更

```sh
ssh idrac7 racadm set BIOS.SerialCommSettings.RedirAfterBoot Enabled
ssh idrac7 racadm jobqueue create BIOS.Setup.1-1
# パワーサイクルで適用 (ジョブ完了まで約5分)
```

### 2. カーネルコンソールを ttyS0 に変更

R320 上で:
```sh
sed -i 's/console=ttyS1,115200n8/console=ttyS0,115200n8/' /etc/default/grub
update-grub
reboot
```

### 3. preseed-server7.cfg の更新

```diff
-### Console - tty0 only (R320 SOL does not pass Linux serial output)
-d-i debian-installer/add-kernel-opts string console=tty0
+### Console - dual output (VGA + SOL via COM1/ttyS0)
+d-i debian-installer/add-kernel-opts string console=tty0 console=ttyS0,115200n8
```

### 4. remaster-debian-iso.sh の更新

- `--serial-unit=N` パラメータ追加 (デフォルト: 1, R320: 0)
- カーネルパラメータに `console=ttyS${SERIAL_UNIT},115200n8` 追加
- ISOLINUX `serial` ディレクティブ追加

## テスト結果

### SOL ブート監視

RedirAfterBoot=Enabled 設定後、パワーサイクルで SOL 出力を確認:

| フェーズ | SOL 表示 | 確認 |
|---------|---------|------|
| BIOS POST (Dell, Memory, PERC) | 表示あり | OK |
| UEFI (EfiInitializeDriverLib) | 表示あり | OK |
| Lifecycle Controller | 表示あり | OK |
| GRUB ("Welcome to GRUB!") | 表示あり | OK |
| Linux カーネル (ttyS0 変更後) | 表示あり | OK |
| serial-getty login プロンプト | 表示あり | OK |

### SOL 双方向通信テスト

```
$ echo MARKER_TTYS0_TEST > /dev/ttyS0
→ SOL で受信: 'MARKER_TTYS0_TEST\r\n'  (19 bytes)

$ ipmitool sol activate → Enter 送信
→ "ayase-web-service-7 login:" プロンプト表示
→ "root" 送信 → "Password:" プロンプト表示
```

**SOL の双方向通信が確認できた。**

### ttyS1 (COM2) との比較

```
$ echo MARKER_TTYS1_TEST > /dev/ttyS1
→ SOL で受信: なし
```

COM2 (ttyS1) の出力は SOL に届かないことも確認。

## 更新したファイル

| ファイル | 変更内容 |
|---------|---------|
| `preseed/preseed-server7.cfg` | `console=ttyS0,115200n8` 追加 |
| `scripts/remaster-debian-iso.sh` | `--serial-unit` パラメータ、`console=ttyS${N}` 追加 |
| `.claude/skills/os-setup/SKILL.md` | R320 SOL 使用可能に変更 (Phase 3/5/6/7) |
| `.claude/skills/idrac7/SKILL.md` | SOL セクション追加 |
| メモリ `sol_serial.md` | R320 SOL 設定情報追加 |

## 知見

1. **iDRAC7 の SOL ポートは SPCR ACPI テーブルで確認する**。BIOS の SerialComm 設定 (COM2) とは異なる場合がある
2. **RedirAfterBoot=Enabled は必須**。デフォルト Disabled では POST 後に SOL が途切れる
3. **BIOS POST と Linux で異なる COM ポートが使われる**: POST は INT10h リダイレクト (COM2)、Linux は直接 UART (COM1)
4. R320 の BIOS ジョブ適用には パワーサイクル + 数分の待機が必要 (34% で数分停滞するが正常)

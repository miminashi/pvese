---
name: bios-setup
description: "Supermicro X11DPU BIOS Setup 操作。KVM スクリーンショット + キーストロークで BIOS メニューを操作する。BIOS 設定変更、確認、保存を行う。4-6号機のみ対応。"
argument-hint: "<subcommand: enter|screenshot|navigate|set|verify|save-exit>"
---

# BIOS Setup スキル

Supermicro X11DPU (4-6号機) の AMI Aptio UEFI BIOS Setup をリモート操作する。
Redfish BIOS API は DCMS ライセンス不可のため、**KVM スクリーンショット + キーストローク** のインタラクティブ方式で操作する。

| サブコマンド | 用途 |
|-------------|------|
| `enter <server>` | サーバを再起動し、POST 中に Delete で BIOS Setup に入る |
| `screenshot <server>` | 現在の KVM 画面をスクリーンショット |
| `navigate <server> <path>` | 指定メニューパスへナビゲート (例: "Advanced > CPU Configuration") |
| `set <server> <setting> <value>` | BIOS 設定値を変更 |
| `verify <server> <setting>` | 現在の設定値を確認 |
| `save-exit <server>` | Save Changes and Exit |

## 前提条件

- 対象: 4号機 (10.10.10.24), 5号機 (10.10.10.25), 6号機 (10.10.10.26) のみ
- 7-9号機 (Dell iDRAC) は非対応
- Playwright + Chromium インストール済み (`.venv/bin/python`)

## ツール

- `scripts/bmc-kvm-interact.py` — KVM 操作 (screenshot, sendkeys, type)

```sh
# スクリーンショット撮影
.venv/bin/python scripts/bmc-kvm-interact.py \
    --bmc-ip BMC_IP --bmc-user claude --bmc-pass Claude123 \
    screenshot tmp/<sid>/bios-screen.png

# キー送信 (最終結果のみ撮影)
.venv/bin/python scripts/bmc-kvm-interact.py \
    --bmc-ip BMC_IP --bmc-user claude --bmc-pass Claude123 \
    sendkeys Delete Delete Delete --wait 500 --screenshot tmp/<sid>/result.png --post-wait 1000

# キー送信 (各キー後にスクリーンショット: PREFIX_001.png, _002.png, ...)
.venv/bin/python scripts/bmc-kvm-interact.py \
    --bmc-ip BMC_IP --bmc-user claude --bmc-pass Claude123 \
    sendkeys ArrowDown Enter Escape --wait 300 \
    --screenshot-each tmp/<sid>/nav --post-wait 500 --pre-screenshot

# テキスト入力
.venv/bin/python scripts/bmc-kvm-interact.py \
    --bmc-ip BMC_IP --bmc-user claude --bmc-pass Claude123 \
    type "some text" --screenshot tmp/<sid>/result.png
```

### sendkeys オプション

| オプション | 説明 |
|-----------|------|
| `--wait MS` | キー間の待機 (デフォルト: 100ms) |
| `--screenshot FILE` | 全キー送信後にスクリーンショット |
| `--post-wait MS` | スクリーンショット前の待機 (デフォルト: 500ms) |
| `--screenshot-each PREFIX` | 各キー後に `PREFIX_001.png`, `_002.png`, ... を保存 |
| `--pre-screenshot` | `--screenshot-each` 使用時、初期状態を `PREFIX_000.png` に保存 |

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
BMC_IP=$("$YQ" '.bmc_ip' "config/server4.yml")
BMC_USER=$("$YQ" '.bmc_user' "config/server4.yml")
BMC_PASS=$("$YQ" '.bmc_pass' "config/server4.yml")
```

## ワークフロー

すべての操作は **screenshot → 画面判読 → キー送信 → screenshot → 確認** のループで行う。
Claude が Read ツールでスクリーンショット PNG を読み取り、画面状態を判断してキーを送る。

### サブコマンド: enter

BIOS Setup に入る。**pve-lock 必須** (電源操作を伴う)。

POST は長時間かかる（ロゴ画面まで約40秒、PXE タイムアウト含め全体で約90秒）。
"Press DEL" は POST 後半のロゴ画面で受け付けられるため、電源投入後すぐに接続を開始し、
**60回の Delete を --wait 1000（1秒間隔）で送り続ける**ことで確実にキャッチする。

1. ForceOff → 15秒待機 → Power On
2. 3秒後に KVM 接続を開始（接続に ~8秒かかる）
3. 60回の Delete キーを1秒間隔で送信（約60秒間カバー）
4. `--screenshot-each` で各キー後のスクリーンショットを確認
5. canvas サイズが 720x400 → 800x600 に変わったら BIOS Setup に入った証拠

```sh
# Step 1: Power off + wait + on
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 power off
sleep 15
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 power on

# Step 2: スクリプトに書いて実行（sleep + 60回 Delete 送信）
# tmp/<sid>/enter_bios.sh:
#   sleep 3
#   .venv/bin/python scripts/bmc-kvm-interact.py \
#       --bmc-ip 10.10.10.24 --bmc-user claude --bmc-pass Claude123 --timeout 60 \
#       sendkeys Delete x60 \
#       --wait 1000 --screenshot-each tmp/<sid>/bios_entry --post-wait 300
sh tmp/<sid>/enter_bios.sh

# Step 3: 最後のスクリーンショットを確認
# Read ツールで tmp/<sid>/bios_entry_060.png を表示
# "Aptio Setup Utility" が見えれば成功
# POST 中のロゴ画面 (bios_entry_040 付近) で "Press <DEL>" が見える
```

**重要**: Delete キーは POST 後半の Supermicro ロゴ画面（電源投入後40-50秒）で受け付けられる。
PXE ブート中（FlexBoot/Intel Boot Agent）には受け付けられない。

**POST 92 スタック対策** (4号機のみ):
4号機は PVE カーネルリブート後に POST code 92 (PCI bus init) でスタックする傾向がある。
スタックした場合: ForceOff → 20秒待機 → Power On → Delete 連打を再試行。

### サブコマンド: screenshot

```sh
.venv/bin/python scripts/bmc-kvm-interact.py \
    --bmc-ip 10.10.10.24 --bmc-user claude --bmc-pass Claude123 \
    screenshot tmp/<sid>/bios-screen.png
```

### サブコマンド: navigate

BIOS メニュー内を指定パスまでナビゲートする。**すべてスクリーンショットを見ながらインタラクティブに操作する。**

#### タブ構造

| Index | タブ名 | 主な設定 |
|-------|--------|---------|
| 0 | Main | System Date/Time, BIOS Version, Memory Info |
| 1 | Advanced | CPU, Chipset, SATA, PCIe, Serial, ACPI, Boot Feature |
| 2 | Event Logs | SMBIOS Event Log |
| 3 | IPMI | BMC FW, System Event Log, BMC Network |
| 4 | Security | Administrator/User Password |
| 5 | Boot | Boot Mode, Boot Order, Legacy/UEFI |
| 6 | Save & Exit | Save/Discard/Defaults, Boot Override |

#### Advanced タブ サブメニュー一覧

- Boot Feature
- CPU Configuration
- Chipset Configuration
- Server ME Information
- PCH SATA Configuration
- PCH eSATA Configuration
- PCIe/PCI/PnP Configuration
- Super IO Configuration
- Serial Port Console Redirection
- ACPI Settings
- Trusted Computing
- HTTP BOOT Configuration
- Supermicro KMS Server Configuration
- TLS Authenticate Configuration
- iSCSI Configuration
- Driver Health

#### キー操作リファレンス (AMI Aptio UEFI BIOS)

| キー | 動作 |
|------|------|
| ArrowLeft / ArrowRight | タブ切替え (**注意事項あり**) |
| ArrowUp / ArrowDown | メニュー項目の選択 |
| Enter | サブメニューに入る / 設定値の変更ダイアログを開く |
| Escape | サブメニューから親メニューに戻る / トップレベルでは Exit ダイアログ表示 |
| +/- | 設定値の変更 (enum 型) |
| F1 | General Help |
| F2 | Previous Values |
| F3 | Optimized Defaults |
| F4 | Save & Exit |
| Tab | ダイアログ内のボタン間移動 |

#### 検証済みナビゲーションパターン (2026-03-20)

以下のパターンは4号機で30回以上のテストにより動作が確認されている:

**タブ切替え**: ArrowRight/ArrowLeft は常にタブを切り替える（カーソル位置に関係なく）。
タブ遷移後はカーソルが先頭項目にリセットされる。7タブで循環する。

```
Main → (ArrowRight) → Advanced → Event Logs → IPMI → Security → Boot → Save & Exit → (循環)
```

**サブメニュー進入・脱出**: ArrowDown でカーソル移動 → Enter で進入 → Escape で戻る。
**Escape 後もカーソル位置が保持される**ため、連続してサブメニューを巡回できる。

```
# 連続サブメニュー巡回パターン（Advanced タブ内）:
ArrowDown Enter    # → 2番目のサブメニューに入る
Escape             # → Advanced に戻る（カーソルは2番目のまま）
ArrowDown Enter    # → 3番目のサブメニューに入る
Escape             # → 繰り返し
```

**効率的な全サブメニュー取得**: `--screenshot-each` を使い1回のセッションで全スクリーンショット取得:
```sh
# Advanced の全16サブメニューを一括取得する例:
# (Main タブから開始)
.venv/bin/python scripts/bmc-kvm-interact.py \
    --bmc-ip 10.10.10.24 --bmc-user claude --bmc-pass Claude123 --timeout 60 \
    sendkeys ArrowRight Enter Escape \
              ArrowDown Enter Escape ArrowDown Enter Escape \
              ArrowDown Enter Escape ArrowDown Enter Escape \
              ... \
    --wait 300 --screenshot-each tmp/<sid>/adv --post-wait 500 --pre-screenshot
```

#### ナビゲーション手順の例

**Advanced > CPU Configuration へ移動**:
```
1. ArrowRight で Advanced タブに移動（Main から1回）
2. ArrowDown で "CPU Configuration" に移動（Boot Feature の次、1回下）
3. Enter でサブメニューに入る
4. 完了後 Escape で Advanced に戻る
```

### サブコマンド: set

設定値を変更する。

1. `navigate` で対象設定まで移動
2. Enter で設定値の変更ダイアログを開く
3. ArrowUp/ArrowDown で値を選択、Enter で確定
4. screenshot で変更が反映されたことを確認

### サブコマンド: verify

設定値を確認する。

1. `navigate` で対象設定まで移動
2. screenshot で現在の値を読み取る

### サブコマンド: save-exit

変更を保存して BIOS を終了する。**pve-lock 必須** (再起動を伴う)。

```
1. F4 キーを送信 (Save & Exit ショートカット)
   → または Save & Exit タブに移動して "Save Changes and Exit" を選択
2. 確認ダイアログで Enter (Yes) を押す
3. サーバが再起動、OS が起動するまで待機
4. SSH で接続確認
```

**POST 92 スタック対策**: Save & Exit 後に POST 92 でスタックした場合:
```sh
./pve-lock.sh run ./scripts/bmc-power.sh forceoff 10.10.10.24 claude Claude123
# 20秒待機
./pve-lock.sh run ./scripts/bmc-power.sh on 10.10.10.24 claude Claude123
```

## Exit ダイアログの操作

BIOS のトップレベルで Escape を押すと "Exit Without Saving - Quit without saving?" ダイアログが表示される。

| 操作 | 方法 |
|------|------|
| "No" を選択 (BIOS に留まる) | Tab → Enter |
| "Yes" を選択 (保存せず終了) | Enter (Yes がデフォルト選択) |

**重要**: Escape キーは Exit ダイアログを出すだけで、キャンセルには Tab+Enter が必要。Escape の連打は避けること。

## Boot タブ操作リファレンス (2026-03-21 検証)

### Boot タブ構造 (DUAL モード)

Boot タブには **24個の選択可能項目** がある。初期画面では Boot Option #15 までしか見えないが、ArrowDown でスクロールすると #16, #17 とサブメニューが出現する。

| # | 項目 | 種類 |
|---|------|------|
| 1 | Boot mode select [DUAL] | enum (LEGACY/UEFI/DUAL) |
| 2 | LEGACY to EFI support [Disabled] | enum |
| 3-19 | Boot Option #1 ~ #17 | dropdown (18値) |
| 20 | ► Add New Boot Option | サブメニュー |
| 21 | ► Delete Boot Option | サブメニュー |
| 22 | ► UEFI Hard Disk Drive BBS Priorities | サブメニュー (debian NVMe) |
| 23 | ► UEFI Application Boot Priorities | サブメニュー (EFI Shell) |
| 24 | ► Hard Disk Drive BBS Priorities | サブメニュー (SATA 4台) |
| 25 | ► Network Drive BBS Priorities | サブメニュー (IBA + FlexBoot) |

- カーソル上下: ArrowDown/ArrowUp は**リスト端でラップ（循環）**する
- Boot mode select → ArrowDown 2回 → Boot Option #1（"FIXED BOOT ORDER Priorities" ラベルはスキップされる）

### Boot Option ドロップダウン

Boot Option は Enter でダイアログを開いて値を選択する。ダイアログ内の値リスト（DUAL モード、18項目）:

| Index | 値 |
|-------|-----|
| 0 | CD/DVD |
| 1 | UEFI USB CD/DVD |
| 2 | USB CD/DVD |
| 3 | Network:IBA 40-10G Slot 1800 v1060 |
| 4 | USB Key |
| 5 | Hard Disk: ST3500418AS |
| 6 | UEFI AP:UEFI: Built-in EFI Shell |
| 7 | USB Hard Disk |
| 8 | USB Floppy |
| 9 | USB Lan |
| 10 | UEFI Hard Disk:debian |
| 11 | UEFI CD/DVD |
| 12 | UEFI USB Hard Disk |
| 13 | UEFI USB Key |
| 14 | UEFI USB Floppy |
| 15 | UEFI USB Lan |
| 16 | UEFI Network |
| 17 | Disabled |

#### ダイアログ操作

| キー | 動作 |
|------|------|
| ArrowDown/ArrowUp | 値を選択（**双方向ラップ**: 末尾→先頭、先頭→末尾で循環） |
| PageDown | **末尾 (Disabled) にジャンプ** |
| PageUp | **先頭 (CD/DVD) にジャンプ** |
| Home / End | **無効**（何も起きない） |
| Enter | 選択値を確定 |
| Escape | キャンセル（値変更なし） |

#### 推奨: Disabled 設定手順

```
Enter → PageDown → Enter
```
PageDown で Disabled（末尾）に一発到達できるため、3キーで任意の Boot Option を Disabled に設定可能。

### +/- キー (ダイアログ不要の値変更)

Boot Option にカーソルを合わせて +/- を押すとダイアログなしで値が変わる。

| キー | Playwright キー名 | 方向 |
|------|------------------|------|
| `-` (Minus) | `Minus` | index **減少**方向（前のアイテムへ） |
| `+` (Plus) | `Shift+Equal` | index **増加**方向（次のアイテムへ） |

- `Equal` 単体は**無効**。必ず `Shift+Equal` を使うこと
- **双方向ラップ**: Disabled(17) の次は CD/DVD(0)、CD/DVD(0) の前は Disabled(17)
- 速度: 200ms 間隔でも問題なく動作
- ダイアログ方式と異なり、**即座に値が確定**する（Enter 不要）

### 値スワップルール

Boot Option の値を変更すると、以下のルールで**自動スワップ**が発生する:

1. **通常の値** (CD/DVD, USB Key 等): 他の Boot Option が既に持っている値に設定すると、**2つの Boot Option の値が自動的に入れ替わる**
2. **Disabled**: スワップ対象外。**複数の Boot Option を同時に Disabled に設定可能**

スワップはダイアログ方式・+/- 方式のどちらでも同様に発生する。

### Boot mode select の危険性

Boot mode select を変更すると **Boot タブのレイアウトが即座に変わる**:

| モード | Boot Option 数 | 追加メニュー |
|--------|---------------|-------------|
| DUAL | 17 | Add/Delete Boot Option, 3つの BBS Priorities |
| UEFI | 9 (UEFI 項目のみ) | Add/Delete Boot Option, BBS Priorities |
| LEGACY | (未検証) | (未検証) |

**警告**: Boot mode を変更すると Boot Option の値が再構成される。意図しない変更は F2 (Previous Values) で復元可能だが、保存してしまうと OS が起動しなくなる可能性がある。

### F2/F3/F4 の Boot タブでの挙動

| キー | ダイアログ | デフォルト | 動作 |
|------|----------|----------|------|
| F2 | "Load Previous Values?" [Yes] [No] | Yes | 最後に保存された状態に全設定を復元 |
| F3 | "Load Optimized Defaults?" [Yes] [No] | Yes | 工場出荷デフォルトに復元（**危険**: VT-x 等もリセット） |
| F4 | "Save configuration and exit?" [Yes] [No] | Yes | 保存して再起動 |

- Yes がデフォルト → **Enter で即実行**
- No を選択するには **Tab → Enter**
- F2 は Boot Option の変更を元に戻すのに便利（保存前のみ有効）
- F3 は Boot mode が DUAL に戻るため Boot Option 数が変わる可能性がある

### Boot Option 変更の推奨手順

**単一値の変更** (例: Boot Option #1 を UEFI Hard Disk:debian に):
```
1. ArrowDown x2 で Boot Option #1 へ
2. Enter でダイアログを開く
3. ArrowDown で目的の値へ（UEFI Hard Disk:debian は index 10）
4. Enter で確定
5. F4 → Enter で保存
```

**複数の Boot Option を Disabled に**:
```
1. Boot Option #N へ移動
2. Enter → PageDown → Enter (3キーで Disabled)
3. ArrowUp で次の Boot Option へ
4. 繰り返し
```

**誤操作のリカバリ**:
- 保存前: **F2** (Previous Values) で全設定を復元
- 保存後: BIOS に再入場して手動修正

## Boot Option #1 を UEFI CD/DVD に設定する手順 (6号機 UEFI CD ブート)

Redfish BootOptions API が空で `find-boot-entry` / `boot-next` が使えないサーバ (6号機等) では、
BIOS Boot タブから直接 Boot Option #1 を設定して UEFI CD ブートを行う。

```
1. --no-click で Boot タブに移動 (ArrowRight x5)
2. ArrowDown x2 で Boot Option #1 へ
3. Enter でドロップダウンを開く
4. PageUp で先頭 (CD/DVD) → ArrowDown x11 で UEFI CD/DVD (index 11) へ
5. Enter で選択
6. F4 → Enter で Save & Exit
```

## PXE Boot Option の一括 Disabled 化

PXE 無限ループを防止するため、全 PXE Boot Option を Disabled に設定する。
Boot Option #1 にカーソルを合わせた状態から:

```
Enter → PageDown → Enter → ArrowDown   (1つ目を Disabled)
Enter → PageDown → Enter → ArrowDown   (2つ目を Disabled)
...
Enter → PageDown → Enter               (17個目を Disabled)
```

各 Boot Option を 3 キー (Enter → PageDown → Enter) で Disabled に設定し、ArrowDown で次へ移動。

## --no-click オプション

`--no-click` は JS `focus()` + tabindex 設定で canvas にキーボードフォーカスを与える。
デフォルトの center click が BIOS メニューカーソルを移動させてしまう問題を回避する。

| 用途 | 推奨オプション |
|------|--------------|
| BIOS Setup 操作 | `--no-click` (カーソル移動を防止) |
| EFI Shell での文字入力 | デフォルト (center click が安全) |

## 安全な設定と危険な設定

> 各設定の技術的な解説は [reference.md](reference.md) を参照。

### Advanced タブ サブメニュー詳細 (4号機, 2026-03-20 取得)

| # | サブメニュー | 主な項目 |
|---|---|---|
| 1 | Boot Feature | Quiet Boot, Option ROM Messages, Bootup NumLock, Wait For "F1" If Error, INT19 Trap, Re-try Boot, Power Config (Watch Dog, Restore on AC, Power Button, Throttle, In-band BIOS Updates) |
| 2 | CPU Configuration | Hyper-Threading [Enable], Cores Enabled [0=all], Monitor/Mwait, Execute Disable Bit, Intel Virtualization [Enable], PPIN Control, HW Prefetcher, Adjacent Cache Prefetch. CPU情報: Xeon Gold 6130 x2, 2.00GHz, L3 28160KB |
| 3 | Chipset Configuration | ► North Bridge, ► South Bridge (サブサブメニュー) |
| 4 | Server ME Information | ME FW Version 4.1.5.2, Current State: Operational, Error Code: No Error (読み取り専用) |
| 5 | PCH SATA Configuration | SATA Controller [Enable], AHCI mode, Port 0-3 設定 (Hot Plug, Spin Up, Device Type). Port 0: ST3500418AS, Port 1: SAMSUNG HD502HJ, Port 2: ST500DM002-1BD142, Port 3: WDC WD5000AAKS-402AA |
| 6 | PCH eSATA Configuration | sSATA Controller [Enable], AHCI mode, Port 0-4 (全て Not Installed) |
| 7 | PCIe/PCI/PnP Configuration | Above 4G Decoding [Enabled], SR-IOV [Disabled], ARI [Disabled], MMIO High Granularity [256G], VGA Priority [Onboard], NVMe Firmware Source, Onboard LAN Device/Option ROM 設定, NVMe1 Option ROM [EFI]. PCIe スロット: AOC-UR-i4XTF, RSC-R1UW-2E16 (SLOT1-4 X16 OPROM) |
| 8 | Super IO Configuration | Super IO Chip: AST2500, ► Serial Port 1/2 Configuration |
| 9 | Serial Port Console Redirection | COM1 [Disabled], SOL [Enabled], Legacy Serial Redirection Port [COM1], EMS [Disabled] |
| 10 | ACPI Settings | NUMA [Enabled], WHEA Support [Enabled], High Precision Event Timer [Enabled] |
| 11 | Trusted Computing | Security Device Support [Enable], TPM State [Enabled], TPM Active: Activated, TPM Owner: Owned, TxT Support [Disabled] |
| 12 | HTTP BOOT Configuration | HTTP Boot One Time [Disabled], Input description, Boot URI |
| 13 | Supermicro KMS Server Configuration | KMS Server IP, TCP Port [5696], Timeout [5], Retry Count [2], TimeZone [0], TCG NVMe KMS Policy [Do Nothing], Client Username/Password, TLS Certificate |
| 14 | TLS Authenticate Configuration | ► Server CA Configuration |
| 15 | iSCSI Configuration | iSCSI Initiator Name, ► Add/Delete/Change Attempt |
| 16 | Driver Health | Intel VROC 8.0.0.4006 VMD [Healthy], Intel DCPMM 1.0.0.3536 [Healthy] (読み取り専用) |

### Event Logs タブ サブメニュー

| サブメニュー | 主な項目 |
|---|---|
| Change SMBIOS Event Log Settings | SMBIOS Event Log [Enabled], Erase Event Log [No], When Log is Full [Do Nothing], Log System Boot Event [Disabled] |
| View SMBIOS Event Log | イベントログ表示 (日付, エラーコード, 重要度) |

### IPMI タブ サブメニュー

| サブメニュー | 主な項目 |
|---|---|
| System Event Log | SEL Components [Enabled], Erase SEL [No], When SEL is Full [Do Nothing] |
| BMC Network Configuration | Update IPMI LAN Configuration [No], IPMI LAN Selection [Dedicated], Address Source [Static], Station IP: 010.010.010.024, IPv6 Support [Enabled] |

### 変更可能 (安全)

- Boot Feature (Quiet Boot, POST delay 等)
- Serial Port Console Redirection
- ACPI Settings
- Boot Mode (UEFI/Legacy)
- Boot Order
- PCIe/PCI/PnP Configuration (一部)

### 変更禁止 (危険)

- CPU 電圧・周波数設定
- メモリ電圧・タイミング設定
- Chipset Configuration の高度な設定
- Security (Administrator Password 設定は慎重に)
- Trusted Computing (TPM 設定)

## oplog 記録

以下の操作は oplog に記録すること:
- BIOS Setup 進入のための電源操作 (cycle/forceoff/on)
- Save & Exit (設定保存)
- 設定値の変更

## KVM 接続の制約

- BMC は同時1セッションのみ安定動作 (複数同時接続でキーが累積する)
- KVM 接続に約8秒かかる（BMC ログイン + ページロード + canvas 待機）
- `--wait` オプションでキー間の待機時間を調整可能 (デフォルト 100ms)
- BIOS 画面の解像度は 800x600 (テキストモード/POST は 720x400)
- `focus_canvas()` は canvas をクリックしてフォーカスする。`safe_click=True` で右下隅をクリック（BIOS メニュー項目を誤クリックしない）
- `--screenshot-each` を使えば1セッション内で複数キー＋複数スクリーンショットを撮れる。毎回再接続する必要がないため、30キー+30スクリーンショットが約40秒で完了する

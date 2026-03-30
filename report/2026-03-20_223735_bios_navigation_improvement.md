# BIOS メニュー操作の改善とサブメニュー取得

- **実施日時**: 2026年3月21日 07:00 JST
- **対象サーバ**: 4号機 (10.10.10.24, Supermicro X11DPU)
- **参照レポート**: [bios_setup_skill](2026-03-20_213733_bios_setup_skill.md)

## 前提・目的

前回のセッションで `scripts/bmc-kvm-interact.py` と `.claude/skills/bios-setup/SKILL.md` を作成し、BIOS Setup への進入・トップレベルタブのスクリーンショット取得に成功した。以下の課題を解決する:

1. **サブメニューの内容未取得**: Advanced タブの16個のサブメニューの内容が未取得
2. **操作がぎこちない**: タブ切替えの挙動が不安定で、Escape ループやサブメニュー誤進入が頻発
3. **ツールの構造的問題**: 1キーごとにスクリーンショットを撮る場合、毎回 ~8秒の接続オーバーヘッド

## 環境情報

- サーバ: 4号機 (Supermicro X11DPU, Xeon Gold 6130 x2)
- BMC: IPMI, FW 01.73.06
- BIOS: AMI Aptio Setup Utility, Version 2.20.1276 (2023)
- OS: Debian 13.3 + Proxmox VE 9.1.6

## 実施内容

### 1. `bmc-kvm-interact.py` の改善

#### 1a. `--screenshot-each PREFIX` オプション追加

`sendkeys` コマンドに追加。各キー送信後にスクリーンショットを撮り、`PREFIX_001.png`, `PREFIX_002.png`, ... に保存。1回のブラウザセッション内で完結するため、60キー送信+60スクリーンショットが約80秒で完了する。

```sh
.venv/bin/python scripts/bmc-kvm-interact.py \
    --bmc-ip 10.10.10.24 --bmc-user claude --bmc-pass Claude123 \
    sendkeys ArrowRight ArrowDown Enter Escape \
    --wait 300 --screenshot-each tmp/<sid>/nav --post-wait 500
```

#### 1b. `--pre-screenshot` オプション追加

`--screenshot-each` と併用。キー送信前の初期状態を `PREFIX_000.png` に保存。

#### 1c. `focus_canvas()` の改善

`page.click("#noVNC_canvas")` をそのまま使用（中央クリック）。テストの結果、中央クリックが BIOS 画面でも安全に動作することを確認。`safe_click=True` 引数で右下隅クリックも可能にしたが、中央クリックがデフォルト。

**注**: `page.evaluate("document.getElementById('noVNC_canvas').focus()")` を試したが、JavaScript focus() だけでは VNC クライアントへのキーイベント伝達が不十分だった。click() が必要。

### 2. ナビゲーションテスト (30回以上)

#### テスト方法

BIOS Setup 内で `--screenshot-each` を使い、各キー操作後のスクリーンショットを取得して挙動を確認した。

#### 確認されたパターン

**タブ切替え (ArrowRight/ArrowLeft)**:
- ArrowRight は常にタブを右に切り替える（カーソル位置に関係なく安定動作）
- タブ遷移後、カーソルは先頭項目にリセットされる
- 7タブで循環: Main → Advanced → Event Logs → IPMI → Security → Boot → Save & Exit → Main

**サブメニュー操作 (Enter/Escape)**:
- Enter でサブメニューに入る（► マーク付き項目）
- Escape で親メニューに戻る
- **Escape 後もカーソル位置が保持される** — 連続してサブメニューを巡回可能

**連続巡回パターン**:
```
ArrowDown → Enter → (サブメニュー表示) → Escape → ArrowDown → Enter → ...
```
これにより、1回のセッションで全16サブメニューを取得できた。

### 3. サブメニュースクリーンショット取得

#### Advanced タブ (16サブメニュー) — 全取得完了

| # | サブメニュー | 主な設定 |
|---|---|---|
| 1 | Boot Feature | Quiet Boot [Enabled], Restore on AC Power Loss [Last State], Power Button [Instant Off] |
| 2 | CPU Configuration | Hyper-Threading [Enable], Intel Virtualization [Enable], Xeon Gold 6130 x2 |
| 3 | Chipset Configuration | North Bridge / South Bridge サブサブメニュー |
| 4 | Server ME Information | ME FW 4.1.5.2, Operational, No Error (読み取り専用) |
| 5 | PCH SATA Configuration | SATA [Enable], AHCI, 4ドライブ接続 |
| 6 | PCH eSATA Configuration | sSATA [Enable], AHCI, 全ポート未接続 |
| 7 | PCIe/PCI/PnP Configuration | Above 4G [Enabled], SR-IOV [Disabled], VGA [Onboard] |
| 8 | Super IO Configuration | AST2500, Serial Port 1/2 |
| 9 | Serial Port Console Redirection | COM1 [Disabled], SOL [Enabled] |
| 10 | ACPI Settings | NUMA [Enabled], WHEA [Enabled], HPET [Enabled] |
| 11 | Trusted Computing | TPM [Enabled/Activated/Owned], TxT [Disabled] |
| 12 | HTTP BOOT Configuration | HTTP Boot [Disabled] |
| 13 | Supermicro KMS Server Config | KMS Server IP, Port 5696 |
| 14 | TLS Authenticate Configuration | Server CA Configuration |
| 15 | iSCSI Configuration | Initiator Name, Add/Delete Attempt |
| 16 | Driver Health | Intel VROC [Healthy], Intel DCPMM [Healthy] |

#### Event Logs タブ (2サブメニュー) — 全取得完了

| サブメニュー | 主な設定 |
|---|---|
| Change SMBIOS Event Log Settings | SMBIOS Event Log [Enabled], Erase [No] |
| View SMBIOS Event Log | イベント一覧表示 |

#### IPMI タブ (2サブメニュー) — 全取得完了

| サブメニュー | 主な設定 |
|---|---|
| System Event Log | SEL Components [Enabled], Erase SEL [No] |
| BMC Network Configuration | IPMI LAN [Dedicated], Static IP: 010.010.010.024 |

### 4. BIOS 進入手順の改善

前回のセッションでは Del キー送信のタイミングが不安定だった。以下の改善を行った:

**改善前**: bmc-power.sh cycle 後に Del 連打 → タイミングが合わず失敗が多い

**改善後**: ForceOff → 15秒待機 → Power On → 3秒後に KVM 接続開始 → 60回の Delete を1秒間隔で送信

```sh
ipmitool ... power off
sleep 15
ipmitool ... power on
sleep 3
.venv/bin/python scripts/bmc-kvm-interact.py ... \
    sendkeys Delete x60 --wait 1000 --screenshot-each tmp/<sid>/bios_entry --post-wait 300
```

POST タイムライン (4号機):
- 0-15秒: 初期ハードウェア初期化 (POST code 60-79)
- 15-25秒: DXE Phase (code 70-97)
- 25-40秒: Supermicro ロゴ + "Press DEL or F2" 表示 ← **ここで Del が効く**
- 40-90秒: PXE/FlexBoot (Del は効かない)

## 修正ファイル

| ファイル | 操作 | 内容 |
|---------|------|------|
| `scripts/bmc-kvm-interact.py` | 修正 | `--screenshot-each`, `--pre-screenshot`, focus_canvas の safe_click |
| `.claude/skills/bios-setup/SKILL.md` | 更新 | ナビゲーション手順、サブメニュー詳細一覧、BIOS 進入手順改善 |

## 結論

- `--screenshot-each` の追加により、1セッションで複数キー操作＋スクリーンショットが可能になった
- ナビゲーションパターン（ArrowDown + Enter + Escape）が安定動作することを確認
- Advanced タブの全16サブメニュー + Event Logs 2 + IPMI 2 = 計20サブメニューのスクリーンショットを取得
- BIOS 進入は Power On 後すぐに接続して60秒間 Del を送り続ける方式が最も確実

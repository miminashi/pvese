# 10号機 disk first boot 不能の調査と対処 (VirtualKeyboard 経由のキー送信実装)

## Context

レポート [`report/2026-04-30_094039_server10_os_install.md`](../../../projects/pvese/report/2026-04-30_094039_server10_os_install.md) の最高優先度残タスク。

10号機 (X10DRT-P, BMC FW 3.65 stock) の OS 自動インストール (Phase B iter1d/e) は完走したが、その後の **disk からの first boot に失敗** し `Reboot and Select proper Boot device` で停止。BIOS Setup / Boot Override への入場を試みたが BMC KVM 経由の DEL/F2/F11/F12 が届かず復旧できなかった。

### 失敗原因の再分析 (本セッションの調査で判明)

過去レポートが推測した「USB HID emulation 制約」は誤り:

1. `tmp/s10vlanKySJ/p6-bios-setup.png` を確認すると、DEL 送信タイミングは既に **PXE Boot Agent 画面到達後** (BIOS Setup 受付ウィンドウは閉じている) → タイミング不正
2. `tmp/s10vlanKySJ/del-storm.sh` は `sleep 60` + `Delete x18 --wait 2500` で実行 → DEL 開始が POST 開始から ~70-90 秒後 (PXE 段階) + `--no-click` 未指定で center click によるカーソル誤移動
3. `tmp/s10vlanKySJ/p6-rescue-1-advanced.png` と `p6-rescue-2-selected.png` が **完全同一** = ISOLINUX でも矢印キー反応せず (canvas focus / DOM key event の信頼性不足)
4. `bios-setup/SKILL.md` L124-142 には 10号機向け実績 recipe (`Delete x60 --wait 1000 --no-click`) が記載済み = **適切タイミング+`--no-click`** ならキーは通るが、不安定

### 方針

ユーザの示唆通り **VirtualKeyboard 経由の確実なキー送信パスを実装** し canvas focus 依存をゼロにする。その上で BIOS Setup → Boot Order 確認 → Plan A/B/C で disk boot を復旧する。

副次発見の可能性: 現行 `send_key_rfb()` (`UI.rfb.sendKey(keysym, true/false)` の 2 引数呼び出し) は noVNC 1.x 系の 3 引数仕様 `sendKey(keysym, code, down)` と非互換。silent no-op の可能性があり、調査で sendKey arity を確認する。

---

## 実装プラン

### Step 1: VirtualKeyboard 機構の実機調査 (read-only)

**目的**: iKVM viewer 内部に VKbd UI / 関数があるかを特定し、`detect_vkbd()` の判定ロジックと JS ペイロードを確定する。

**作成**: `tmp/<sid>/probe-vkbd.py` (Playwright)

収集対象:
- `document.documentElement.outerHTML` → `tmp/<sid>/vkbd-dom.html`
- `Object.keys(window)` / iframe の `contentWindow` キー一覧
- 全 `<button>` `<a>` `<div onclick>` のテキスト/id/class
- `Object.keys(UI)`, `Object.keys(UI.rfb)` (存在する場合)
- `UI.rfb.sendKey.toString().slice(0, 200)` で **arity 確認** (2 or 3)
- 全結果を `tmp/<sid>/vkbd-probe.json` に JSON で保存

検索キーワード:
```
virtualkeyboard | vkbd | VKbd | softkbd | softkey | onScreen | OSK | keyboard
sendCAD | sendKey | sendKeySequence | keyEvent | key_event
```

期待される発見の典型:
- `UI.sendKey(keysym, code, down)` ラッパー (理想)
- `UI.rfb.sendKey` の **3 引数版** (noVNC 1.x: keysym, DOM code, down)
- VKbd UI ボタン (例: `id="vkbd_btn"`) → onclick で `UI.toggleVkbd()` 等を呼ぶ
- iframe 内に VKbd UI が分離 (`/kvm/vkbd.html` 等)

### Step 2: `bmc-kvm-interact.py` の VKbd 統合

**修正ファイル**: `scripts/bmc-kvm-interact.py`

#### 2-1. 新規定数 `DOM_CODES`

`X11_KEYSYMS` の隣 (L102 付近) に追加:
```python
DOM_CODES = {
    "Delete": "Delete", "F1": "F1", "F2": "F2", ..., "F12": "F12",
    "Enter": "Enter", "Escape": "Escape", "Tab": "Tab", "Backspace": "Backspace",
    "ArrowUp": "ArrowUp", "ArrowDown": "ArrowDown",
    "ArrowLeft": "ArrowLeft", "ArrowRight": "ArrowRight",
    "Home": "Home", "End": "End", "PageUp": "PageUp", "PageDown": "PageDown",
    "Space": "Space", "Shift": "ShiftLeft", "Control": "ControlLeft", "Alt": "AltLeft",
}
```

#### 2-2. 新規関数 `detect_vkbd(page)` (`detect_rfb_client` の直後 L316 付近)

戻り値:
- `'UI.sendKey'` — `UI.sendKey(keysym, code, down)` ラッパー検出
- `'UI.rfb.sendKey3'` — `UI.rfb.sendKey.length === 3`
- `'UI.rfb.sendKey2'` — 2 引数 (= 既存 `send_key_rfb` と等価)
- `'vkbd_button'` — VKbd ボタン DOM 検出 (DOM click フォールバック用)
- `None` — 何も検出できず

#### 2-3. 新規関数 `send_key_vkbd(page, key, vkbd_handle)` (`send_key_rfb` の直後 L344 付近)

`vkbd_handle` ごとに JS ペイロードを切り替えて `page.evaluate(...)`。

3 引数版例 (`UI.rfb.sendKey3`):
```javascript
() => {
    var k = <keysym>;
    var c = "<dom_code>";
    UI.rfb.sendKey(k, c, true);
    UI.rfb.sendKey(k, c, false);
    return true;
}
```

#### 2-4. `send_keys()` 統合 (L347-375 を書き換え)

優先順位制御を追加:
```python
def send_keys(page, keys, wait_ms, rfb_obj_name=None, vkbd_handle=None,
              prefer="auto", ...):
    focus_canvas(...)
    for i, key in enumerate(keys, 1):
        order = {
            "auto":       ["vkbd", "rfb", "playwright"],
            "vkbd":       ["vkbd", "rfb", "playwright"],
            "rfb":        ["rfb", "vkbd", "playwright"],
            "playwright": ["playwright"],
        }[prefer]
        sent = False
        for path in order:
            if path == "vkbd" and vkbd_handle:
                sent = send_key_vkbd(page, key, vkbd_handle)
            elif path == "rfb" and rfb_obj_name in ("rfb", "window.rfb", "UI.rfb"):
                sent = send_key_rfb(page, key, rfb_obj_name)
            elif path == "playwright":
                send_key_playwright(page, key); sent = True
            if sent:
                log(f"  -> sent via {path}"); break
        time.sleep(wait_ms / 1000.0)
        # screenshot_each ロジックは現行のまま
```

#### 2-5. CLI フラグ追加 (`p_sendkeys` / `p_type`)

```python
p_sendkeys.add_argument(
    "--prefer", choices=["auto", "vkbd", "rfb", "playwright"], default="auto",
    help="Key injection path priority (default: auto = vkbd > rfb > playwright)",
)
```

#### 2-6. `cmd_sendkeys` で `detect_vkbd(page)` を `detect_rfb_client` の直後で呼び、両方を `send_keys` に渡す

VKbd 検出失敗時 (`None`) → 従来 `rfb` / `playwright` のみ動作 (4-9号機デグレなし)。

### Step 3: 統合テスト

#### 3-1. 4号機 (X11DPU) 非リグレッション確認

```sh
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 power off
sleep 15
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 power on
sh tmp/<sid>/regression-x11dpu.sh   # Delete x60 --wait 1000 (--prefer 未指定 = auto)
```

判定: 最終 screenshot に `Aptio Setup Utility` が映る + ログに `VKbd detection: <result>` と `sent via <path>` が出る。

完了後 4 号機を元の状態に復元。

#### 3-2. 10号機 BIOS Setup 入場テスト (本命)

```sh
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 power off
sleep 15
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 power on
sh tmp/<sid>/test-bios-vkbd.sh
```

`test-bios-vkbd.sh`:
```sh
#!/bin/sh
set -eu
sleep 3
.venv/bin/python ./scripts/bmc-kvm-interact.py \
    --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 --timeout 90 \
    sendkeys Delete Delete Delete Delete Delete Delete Delete Delete Delete Delete \
              Delete Delete Delete Delete Delete Delete Delete Delete Delete Delete \
              Delete Delete Delete Delete Delete Delete Delete Delete Delete Delete \
              Delete Delete Delete Delete Delete Delete Delete Delete Delete Delete \
              Delete Delete Delete Delete Delete Delete Delete Delete Delete Delete \
              Delete Delete Delete Delete Delete Delete Delete Delete Delete Delete \
    --wait 1000 --no-click --prefer vkbd \
    --screenshot-each tmp/<sid>/bios_entry --post-wait 300
```

判定: `bios_entry_NNN.png` のいずれかに `Aptio Setup Utility` が映る (canvas が 720x400 → 800x600 に切り替わる)。

### Step 4: BIOS Setup での確認 (3 項目)

#### 4-1. Boot タブ — Boot Order

```sh
.venv/bin/python ./scripts/bmc-kvm-interact.py \
    --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 \
    sendkeys ArrowRight ArrowRight ArrowRight ArrowRight ArrowRight \
    --wait 500 --no-click --prefer vkbd \
    --screenshot tmp/<sid>/boot-tab.png
```

期待: Legacy Boot Order #5 = "Hard Disk" (`reference.md` L1580)。Disabled なら Boot Order が壊れている → 修正対象。

#### 4-2. Advanced > SATA Configuration

ArrowLeft x4 で Advanced タブへ → ArrowDown で SATA Configuration を選択 → Enter → Port 0 等に SSD モデル名を確認。

`Not Installed` なら BIOS が disk を認識していない → 物理問題。

#### 4-3. Boot Mode

LEGACY のままになっているか確認 (preseed は MBR + grub-pc 前提)。UEFI に切替わっていたら起動不能。

### Step 5: Disk Boot 復旧 (Plan A → B → C)

#### Plan A: Boot Override / Boot Order 修正 (10 分)

Save & Exit タブで Boot Override に "Hard Disk" or "SATA: <model>" が見えれば Enter で実行。
見えなければ Boot タブで Boot Order #5 を直接修正 → F4 → Enter で Save & Reset。

成功判定: `./scripts/ssh-wait.sh 10.10.10.210 --timeout 240 --interval 10` で SSH 到達。

#### Plan B: Stock ISO rescue mode + chroot grub-install (30 分)

Plan A NG 時。Stock Debian 13.3 ISO を BMC mount → power cycle → ISOLINUX で Advanced options → Rescue mode を `--prefer vkbd` で選択。

Rescue TUI を Enter 連打で進める → Network skip → `/dev/sda1` を root に選択 → Execute a shell。

シェル内で確認:
- `cat /var/log/installer/syslog | grep -i grub`
- `ls -la /boot/grub`
- `dpkg -l | grep grub`
- `blkid /dev/sda1`
- `fdisk -l /dev/sda`

修復:
- `grub-install /dev/sda` (`Installation finished. No error reported.` を期待)
- `update-grub`
- `exit` → reboot → SSH 確認

#### Plan C: preseed late_command 修正 + フル再インストール (60 分)

Plan B で `dpkg -l grub-pc` 不在等が判明した場合。

`preseed/preseed.cfg.template` に追加:
```
d-i grub-installer/bootdev string /dev/<DISK>
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
```

`scripts/generate-preseed.sh` の VLAN モード分岐で:
- `pkgsel/include` に `grub-pc` を追加
- `late_command` で `in-target /usr/sbin/grub-install /dev/sda; in-target /usr/sbin/update-grub` を先頭に追加

Phase 2-5 を re-run (`os-setup-phase.sh reset` + 通しテスト)。

#### Plan 採用判定基準

| 観測 | 採用 |
|------|------|
| BIOS で SSD 認識 + Boot Override に Hard Disk あり | A |
| BIOS で SSD 認識だが Boot Override に出ない | A の Boot Order 修正 → 効かなければ B |
| BIOS で SSD = Not Installed | 物理確認後 B |
| rescue で `/boot/grub` が空 | B (chroot grub-install) |
| rescue で `dpkg -l grub-pc` が無い | C |

### Step 6: ドキュメント・メモリ更新

- `~/.claude/projects/-home-ubuntu-projects-pvese/memory/bmc_kvm.md` に「VirtualKeyboard 経由のキー送信」セクション追加 (4 系統 + sendKey arity 注意)
- `.claude/skills/bios-setup/SKILL.md`:
  - 「`--prefer` オプション」節を新設 (auto / vkbd / rfb / playwright)
  - 10号機 recipe (L124-142) を `--prefer vkbd` 付きに更新
- `.claude/skills/os-setup/SKILL.md` Phase 6 に「ディスクからブート失敗時のリカバリ手順」(Plan A/B/C 判定フロー) を追加
- `report/2026-04-30_094039_server10_os_install.md` の「残タスク」最高優先度行を follow-up レポートへのリンクに置換
- 完了時に新規 follow-up レポート `report/<timestamp>_server10_disk_first_boot_recovery.md` を作成 (採用 Plan、VKbd 機構の発見内容、復旧手順の再現コマンド)

---

## Critical Files

- `/home/ubuntu/projects/pvese/scripts/bmc-kvm-interact.py` (主修正対象 — VKbd 関数追加 + send_keys 統合 + --prefer flag)
- `/home/ubuntu/projects/pvese/.claude/skills/bios-setup/SKILL.md` (`--prefer` 説明追加, 10号機 recipe 更新)
- `/home/ubuntu/projects/pvese/.claude/skills/bios-setup/reference.md` (X10DRT-P BIOS UI 詳細 — 参照のみ、編集なし)
- `/home/ubuntu/projects/pvese/.claude/skills/os-setup/SKILL.md` (Phase 6 リカバリ手順追記)
- `/home/ubuntu/projects/pvese/scripts/generate-preseed.sh` (Plan C 時のみ修正)
- `/home/ubuntu/projects/pvese/preseed/preseed.cfg.template` (Plan C 時のみ修正)
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/bmc_kvm.md` (auto-memory 更新)

## 検証 (End-to-End)

1. **VKbd 検出**: `tmp/<sid>/vkbd-probe.json` に sendKey arity / UI.sendKey / vkbd ボタンの何かが記録される
2. **4号機非リグレッション**: 4号機で BIOS Setup 入場再現 (`bios_entry_NNN.png` に Aptio Setup Utility)
3. **10号機 BIOS Setup**: `bios_entry_NNN.png` のいずれかに Aptio Setup Utility が映る
4. **disk first boot 成功**: power cycle 後 (Plan A/B/C いずれか経由) `./scripts/ssh-wait.sh 10.10.10.210 --timeout 240` が成功
5. **ssh 経由で確認**: `ssh -F ssh/config pve10 'lsblk; cat /etc/debian_version; uname -r'` が正常応答
6. (任意) Phase 7 PVE インストール / Phase 8 bridge セットアップへ継続

## 想定タイムライン

| Step | 所要 |
|------|------|
| 1. probe-vkbd.py 実装 + 実機調査 | 30 分 |
| 2. bmc-kvm-interact.py 編集 | 30 分 |
| 3-1. 4号機非リグレッション | 15 分 |
| 3-2. 10号機 BIOS 入場テスト | 15 分 |
| 4. BIOS で Boot Order/SATA/Mode 確認 | 15 分 |
| 5. Plan A | 10 分 |
| 5. Plan B (必要時) | +30 分 |
| 5. Plan C (必要時) | +60 分 |
| 6. ドキュメント更新 + follow-up レポート | 30 分 |

順調なら **約 2.5 時間**、Plan B 必要時 約 3 時間、Plan C まで必要時 約 4.5 時間。

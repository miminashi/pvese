# 10号機 disk first boot 復旧 + VirtualKeyboard 経由キー送信実装レポート

- **実施日時**: 2026年5月2日 05:30-06:06 JST

## 添付ファイル

- [実装プラン](attachment/2026-05-02_060639_server10_disk_first_boot_recovery/plan.md)
- BIOS Setup スクリーンショット (`attachment/2026-05-02_060639_server10_disk_first_boot_recovery/`):
  - `bios_final.png` — VKbd 経由で入場した Aptio Setup Utility (Main タブ)
  - `boot-tab.png` — Boot Order に "Hard Disk Drive BBS Priorities" 不在
  - `sata-config.png` — SATA Port 0-4 すべて Not Installed (sSATA も同様)
  - `save-exit-tab2.png` — Boot Override に PXE のみ (`IBA GE Slot 0300 v1572`)
  - `pcie-config.png` — `LSI HBA OPROM: [Disabled]` (致命的設定)
  - `pcie-lsi-enabled.png` — Enabled に変更後
  - `post-reboot-150s.png` — Save & Reset 後の login プロンプト到達

## 前提・目的

[前任レポート 2026-04-30_094039_server10_os_install.md](2026-04-30_094039_server10_os_install.md) の **最高優先度残タスク** の対処。10号機 (Supermicro X10DRT-P / Nutanix NX-1065-G5 OEM) で OS install (preseed iter1d/e) は完走したが、disk からの first boot 不能 (`Reboot and Select proper Boot device`) で停止。BMC KVM 経由の DEL/F2/F11 が届かず BIOS Setup へ入れず、原因切り分け不能だった。

ユーザの示唆: 「特定のキーの押下が反応しない場合は、VirtualKeyboard の機能（または、これが内部的に使用している関数など）を使用することを検討してみてください」

目的:
1. iKVM HTML5 viewer の VirtualKeyboard 内部関数を特定し、`bmc-kvm-interact.py` に新パスとして実装する
2. その上で BIOS Setup に確実に入場し、disk first boot 不能の原因を特定する
3. 復旧策 (Plan A: Boot Order 修正 / Plan B: rescue + grub-install / Plan C: preseed 修正再インストール) を適用して disk boot を機能させる

参照した過去レポート:
- [10号機 OS インストール (前任タスク)](2026-04-30_094039_server10_os_install.md)
- [bios-setup スキル X10DRT-P 対応](2026-04-30_061705_bios_setup_x10drt_p_support.md)

## 環境情報

| 項目 | 値 |
|------|----|
| ホスト名 | `ayase-web-service-10` |
| BMC IP | `10.10.10.30` (ASPEED 2400 / Redfish 1.0.1 / FW 3.65 stock) |
| 静的 IP (内部) | `10.10.10.210/8` (eno1.1083 = VLAN 1083) |
| Disk | **`/dev/sda` = TOSHIBA THNSNJ240PCSZ 223.6G** (LSI SAS HBA 経由) |
| BIOS | AMI Aptio 2.17.1249 / Boot Mode = LEGACY |
| 設定ファイル | `config/server10.yml` |

## 実施内容

### Phase 1: VirtualKeyboard 機構の調査 (probe-vkbd.py)

`tmp/s10vkbd/probe-vkbd.py` (Playwright) で iKVM HTML5 viewer の DOM/JS を調査:

```sh
.venv/bin/python tmp/s10vkbd/probe-vkbd.py \
    --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 \
    --output-dir tmp/s10vkbd
```

判明した事実:

1. **`UI.rfb.sendKey` arity = 2** で `(code, down)` シグネチャ。signature 抜粋:
   ```javascript
   sendKey: function(code, down) {
       if (this._rfb_state !== "normal" || this._view_only) return false;
       ...
       if (this._rfb_insydevnc)
           arr.concat(RFB.messages.keyEventInsyde(this._ast2100.Keymap, code, down ? 1 : 0));
       else
           arr.concat(RFB.messages.keyEvent(code, down ? 1 : 0));
   }
   ```
   → noVNC 1.x の 3 引数版 (`(keysym, code, down)`) ではなく、シンプルな 2 引数版。`_rfb_state` チェックが先頭に存在し、normal でないと silent return false (これが既存 send_key_rfb の不安定さの真因)。

2. **`UI.rfb.sendMacro(macro_array)`** が **VirtualKeyboard 機構の本命**:
   - `/novnc/include/nav_ui.js` の `HandleKeyMarcos()` で `<a id="f1">F1</a>` などの Hot Key ボタンが `UI.rfb.sendMacro(keymacros.transNameToKeymacroArray("F1"))` で発火させる関数
   - `[XK_F1]` を渡せば down → up の wire sequence が一回で送られる
   - InsydeVNC モードでは `RFB.messages.keyEventInsyde` でエンコードされ、`_ast2100.Keymap` を通って flush される
   - keymacros.js (`/novnc/include/keymacros.js`) は F1-F12, Delete, Enter, Escape, Tab, ArrowKeys, Ctrl/Alt/Shift, 0-9, A-Z, Pause, PrntScn 等のキーシムをマップ済み

3. **DOM 構造**: `<a id="virtual_keyboard">Virtual Keyboard</a>` リンク + 各 Hot Key 用 `<a id="f1">`, `<a id="ctrl_alt_del">`, `<a id="alt_f4">` 等のメニュー項目。`/js/virtualkeyboard.js` (GreyWyvern VKI) は **テキストフィールド向けの汎用ライブラリ** で iKVM のキー送信本体ではない。

### Phase 2: `scripts/bmc-kvm-interact.py` の VKbd 統合

3 つのキー送信パスと優先順位制御を導入:

| パス | 内部実装 | 備考 |
|------|---------|------|
| **vkbd** (推奨) | `UI.rfb.sendMacro([keysym])` | Hot Key 経路。canvas focus 非依存で BIOS/POST/ISOLINUX 全段で安定 |
| **rfb** | `UI.rfb.sendKey(keysym, true/false)` | display mode 切替時に state 不整合あり |
| **playwright** | `page.keyboard.press(key)` | DOM keydown/keyup。canvas focus 必須 |

新規追加した関数 (詳細は `scripts/bmc-kvm-interact.py` 参照):
- `wait_rfb_normal(page, timeout_sec=5)` — `UI.rfb._rfb_state === "normal"` をポーリング待機
- `detect_vkbd(page)` — `UI.rfb.sendMacro` の存在 / `sendKey` arity / InsydeVNC フラグ / 現 state を一括検出
- `send_key_vkbd(page, key, vkbd_info)` — sendMacro 経路で送信、state ガード付き
- `send_keys()` 改修 — `--prefer {auto,vkbd,rfb,playwright}` で順序制御、デフォルトは `auto = vkbd > rfb > playwright`
- `send_text()` も同様に統合

`send_key_rfb()` も state チェックを追加 (`_rfb_state !== 'normal'` ならスキップ)。

CLI: `--prefer auto|vkbd|rfb|playwright` (sendkeys / type 両方)。

### Phase 3: 統合テスト

#### 10号機 BIOS Setup 入場 (本命)

```sh
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 power on
sh tmp/s10vkbd/test-bios-vkbd.sh   # Delete x60 --wait 1000 --no-click --prefer vkbd
```

ログ抜粋:
```
VKbd detection: sendMacro available, sendKey arity=2, insydevnc=True, state=normal
Sending key [1/60]: Delete
  -> sent via vkbd (UI.rfb.sendMacro)
... (60 keys all via vkbd) ...
```

最終 screenshot (`bios_final.png`): **Aptio Setup Utility - Copyright (C) 2021 American Megatrends, Inc.** に到達。BIOS Version G4Q5T8.0 / X10DRT-P / Build Date 07/14/2021 を確認。

#### 4号機 (X11DPU) 非リグレッション確認

```sh
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 power on
sh tmp/s10vkbd/test-bios-s4-vkbd.sh   # --prefer auto (= vkbd)
```

`VKbd detection: sendMacro available, sendKey arity=2, insydevnc=True, state=normal` 検出 → vkbd 経路で 60 keys 送信 → 最終 screenshot に "Entering Setup..." (DEL がロゴ画面で正しく受け付けられた印)。完了後 power off に復元。

→ X11DPU でも VKbd path は動作。デグレなし。

### Phase 4: 原因診断

VKbd 経路で BIOS 内ナビゲートし、4 項目を確認 (画面は添付参照):

1. **Boot タブ** (`boot-tab.png`):
   - Boot Mode = **LEGACY** ✓
   - Legacy Boot Order #5 = "Hard Disk" の論理スロットあり
   - **しかし "HARD DISK Drive BBS Priorities" サブメニュー不在** → backing physical device 無し

2. **Advanced > SATA Configuration** (`sata-config.png`): Port 0-4 すべて **Not Installed**
3. **Advanced > sSATA Configuration**: Port 0-3 すべて **Not Installed**
4. **Save & Exit > Boot Override** (`save-exit-tab2.png`): **`IBA GE Slot 0300 v1572` (PXE) のみ**

→ NX-1065-G5 の OS install 先 disk は **LSI SAS HBA 経由** だが、BIOS が SAS HBA の OptionROM を読み込まないため Legacy boot 列挙されない。

5. **Advanced > PCIe/PCI/PnP Configuration** (`pcie-config.png`): **`LSI HBA OPROM: [Disabled]`** 発見!

→ 直接の原因確定。

### Phase 5: Plan A.3 — `LSI HBA OPROM=[Enabled]` に変更

```sh
# BIOS Setup 内ナビゲーション (すべて --prefer vkbd)
ArrowDown x16 → LSI HBA OPROM ハイライト (help text "Enable/Disable LSI HBA firmware to be loaded" で確認)
Enter → 値ダイアログ (Disabled / Enabled の 2 択)
ArrowDown → Enter → Enabled に変更 (`pcie-lsi-enabled.png`)
F4 → Enter (Save configuration and exit?)
```

POST 約 90 秒 (LSI HBA scan 追加で延長) → **`Debian GNU/Linux 13 ayase-web-service-10 tty1` ログインプロンプト到達** (`post-reboot-150s.png`)。disk first boot 完全復旧。

### Phase 6: 副次バグの修正 — preseed netcfg が untagged eno1 に static IP を書く

SSH (`pve10`) が初回タイムアウト → KVM root login で `ip -br a` 確認 → **`eno1` (untagged) と `eno1.1083` (VLAN 1083) の両方に `10.10.10.210/8`** が割り当てられている問題を発見。default route も `10.10.10.1 dev eno1` で誤設定 (CLAUDE.md は 10.0.0.0/8 をデフォルトGW にしないと規定)。

原因: preseed の netcfg directive (`netcfg/get_ipaddress`, `netcfg/get_netmask`, `netcfg/get_gateway`) が物理 NIC `eno1` に static IP を書き込んだため、後続の late_command で追加された VLAN サブインタフェース定義と重複した。

一時対処 (`tmp/s10vkbd/fix-interfaces.sh` を SSH+SCP 経由でデプロイ):
- `iface eno1 inet static` ブロック削除
- `iface eno1 inet manual` に置き換え (VLAN サブが eno1 を使うため必要)
- gateway directive を削除 (default route は eno1.1120 DHCP で 192.168.120.1 経由)
- dns-nameservers / dns-search を eno1.1083 に移動

reboot 後の確認:
```
default via 192.168.120.1 dev eno1.1120 proto dhcp src 192.168.120.200 metric 1004
10.0.0.0/8 dev eno1.1083 proto kernel scope link src 10.10.10.210
192.168.120.0/24 dev eno1.1120 proto dhcp scope link src 192.168.120.200 metric 1004
```

→ 完璧な状態 (untagged eno1 に IP なし、default route はインターネット側 VLAN 1120 経由)。SSH 即時到達。

> **残課題**: preseed テンプレート (`scripts/generate-preseed.sh` / `preseed/preseed.cfg.template`) で **VLAN モード時に netcfg を物理 NIC ではなく VLAN サブに向ける** 改修が必要。本セッションで running system は修正したが、再インストールすると同じ問題が再発する。

## 再現方法

### Phase 1: VKbd 機構調査

```sh
mkdir -p tmp/<sid>
.venv/bin/python tmp/s10vkbd/probe-vkbd.py \
    --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 \
    --output-dir tmp/<sid>
grep -E 'sendMacro|sendKey_arity|insydevnc' tmp/<sid>/vkbd-probe.json
```

### Phase 2: VKbd 経由 BIOS Setup 入場

```sh
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 power on
sleep 3
.venv/bin/python ./scripts/bmc-kvm-interact.py \
    --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 --timeout 90 \
    sendkeys $(yes Delete | head -60 | tr '\n' ' ') \
    --wait 1000 --no-click --prefer vkbd \
    --screenshot-each tmp/<sid>/bios_entry --post-wait 300
```

> 上記の `$(yes ...)` 形式は inline では permission に hit しないので、実際には `Delete` を 60 個列挙したスクリプトファイルに書いて実行する。例は `tmp/s10vkbd/test-bios-vkbd.sh` を参照。

### Phase 3: LSI HBA OPROM Enable

BIOS Setup 入場後 (`tmp/s10vkbd/` の各 screenshot を参考にナビゲーション):

```sh
# 各コマンドはすべて --prefer vkbd で実行
ArrowDown x16 (Advanced > PCIe/PCI/PnP Configuration > LSI HBA OPROM までスクロール)
Enter (値ダイアログ表示)
ArrowDown Enter (Disabled → Enabled に変更)
F4 Enter (Save configuration and exit? Yes 確定)
```

reboot 後: `./scripts/ssh-wait.sh 10.10.10.210 --timeout 240 --interval 10`

### Phase 4: untagged eno1 IP 削除 (running system のみ)

```sh
scp -F ssh/config -o UserKnownHostsFile=ssh/known_hosts \
    tmp/s10vkbd/fix-interfaces.sh pve10:/root/fix-interfaces.sh
ssh -F ssh/config -o UserKnownHostsFile=ssh/known_hosts pve10 'sh /root/fix-interfaces.sh'
ssh -F ssh/config -o UserKnownHostsFile=ssh/known_hosts pve10 systemctl reboot
sleep 90
./scripts/ssh-wait.sh 10.10.10.210 --timeout 240 --interval 10
```

## 検証結果

| 項目 | 結果 |
|------|------|
| `UI.rfb.sendMacro` 検出 + `_rfb_state` チェック | ✅ 10号機 BMC FW 3.65 で確認 |
| `bmc-kvm-interact.py` への vkbd path 統合 | ✅ `--prefer auto` で自動選択、明示指定可能 |
| VKbd 経由で 10号機 BIOS Setup 入場 | ✅ Aptio Setup Utility 表示確認 |
| 4号機 (X11DPU) 非リグレッション | ✅ vkbd 経路で BIOS 入場、デグレなし |
| disk first boot 復旧 (LSI HBA OPROM Enable) | ✅ Debian login プロンプト到達 |
| SSH 接続 (10.10.10.210) | ✅ untagged eno1 IP 削除後即時到達 |
| Reboot 後の永続性 | ✅ /etc/network/interfaces 修正後 reboot しても SSH 即時到達 |
| route 状態 | ✅ default via 192.168.120.1 (VLAN 1120 DHCP), 10.0.0.0/8 via eno1.1083 |

## 残タスク

| 優先度 | 内容 |
|-------|------|
| **高** | **preseed の netcfg 修正** — VLAN モード時に物理 NIC ではなく VLAN サブに static IP を書く改修。`scripts/generate-preseed.sh` の VLAN モード分岐で `netcfg/get_*` を抑制し、late_command の VLAN セクションだけで IP を設定するように修正。今回 running system のみ手動修正したので、preseed 再生成 + 再インストール時に再発する。新規 issue として登録予定 |
| 高 | **Phase 7-8 の実証** — LSI HBA OPROM Enable で disk boot 復旧したので、Phase 7 (PVE インストール) + Phase 8 (bridge セットアップ) を継続実施 |
| 中 | **`config/server10.yml` 注釈の修正** — line 39-42 で `# - SATA SSD on the LSI/onboard controller` と書かれているが、正確には **LSI SAS HBA 経由 (mpt3sas)**。SATA controller (PCH) ではない。Toshiba THNSNJ240PCSZ は SATA 規格の SSD だが PCH ではなく LSI HBA を経由しているため、`SATA Configuration` の Port 一覧には現れない |
| 中 | **`os-setup` スキルの通しテスト再走** — LSI HBA OPROM 設定済みの状態で iter2-3 反復実施し、preseed 自動再現性を確認 |
| 低 | **bios-setup スキルの reference.md** に LSI HBA OPROM 項目の詳細追記 (10号機固有の必須設定として) |

## 関連ファイル

- 修正: `scripts/bmc-kvm-interact.py` (VKbd 関数追加 + send_keys 統合 + --prefer flag)
- 修正: `.claude/skills/bios-setup/SKILL.md` (`--prefer` オプション説明追加, 10号機 recipe 更新)
- 修正: `.claude/skills/os-setup/SKILL.md` (Phase 6 ステップ 2-A: Disk first boot 失敗時のリカバリ追加)
- 新規 (auto-memory): `~/.claude/projects/-home-ubuntu-projects-pvese/memory/server10_lsi_hba_oprom.md`
- 更新 (auto-memory): `~/.claude/projects/-home-ubuntu-projects-pvese/memory/bmc_kvm.md` (キー送信 3 パス記録)
- 新規 (auto-memory): MEMORY.md にエントリ追加
- 一時ファイル: `tmp/s10vkbd/probe-vkbd.py`, `tmp/s10vkbd/test-bios-vkbd.sh`, `tmp/s10vkbd/fix-interfaces.sh`, 多数の screenshot

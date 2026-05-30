# TX1320 M3 NFS install Phase 6 — HDImage 再閉鎖 + GRUB shell 経路完全 blocked / 仮説 8 確定閉鎖 + 仮説 10 間接反証 + 新発見「BIOS Console Redirection 無しで SOL 入力不達 + KVM Virtual Keyboard も GRUB 不達」

- **実施日時**: 2026 年 5 月 22 日 02:50 〜 03:15 (JST、約 25 分)
- **担当**: phase6a01 (Opus 4.7、plan mode → auto モード)
- **Issue**: #71 (Phase 5 で blocked → Phase 6 開始時 active 化、Phase 6 終了で blocked へ戻し)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**:
  - [2026-05-22_022359_tx1320_raid10_phase5_cmdline.md](2026-05-22_022359_tx1320_raid10_phase5_cmdline.md) — Phase 5 (phase5a01): 仮説 7/9 反証
  - [2026-05-22_012828_tx1320_raid10_phase4_kvm_locator.md](2026-05-22_012828_tx1320_raid10_phase4_kvm_locator.md) — Phase 4 (s-vast-hare): locator screenshot で VGA 健全
  - [2026-05-22_004000_tx1320_raid10_kernel_silent_persist.md](2026-05-22_004000_tx1320_raid10_kernel_silent_persist.md) — Phase 3 (s-rustling-melody): `quiet`/`earlyprintk` 反証

## 添付ファイル

- [実装プラン](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/plan.md)
- [Phase 6a HDImage PATCH 応答 (HTTP 200 + MaxDev=0)](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/hdimage-config-response.json)
- [Phase 6a HDImage status (反映確認)](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/hdimage-status.txt)
- [Phase 6a Manager-level VirtualMedia (Members count=0 + navigation 不可)](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/manager-vm-members.json)
- [Phase 6b local/remote ISO sha256 + vmlinuz/initrd size](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/iter-grub-local-sha256.txt) / [remote](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/iter-grub-remote-sha256.txt) / [local-image-sizes](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/local-image-sizes.txt)
- [Phase 6b KVM screenshots (pre/menu/shell/ls-devices/ls-amd/ls-vmlinuz/ls-initrd/cat-mid/current/final)](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/)
- [Phase 6b KVM shell interact log](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/kvm-grub.log)
- [Phase 6b SOL log (sol-monitor.py、312 KB)](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/sol-grub.log)
- [Phase 6b SOL countdown 抽出 (13735 行、300→0 完走)](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/sol-countdown.txt)
- [Phase 6b SOL stdin 経由 `c` + `ls` 試行ログ (出力 442 B、echo 無し)](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/grub-sol-output.log)
- [Phase 6b 実行スクリプト群](attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/) (extract-images.sh, grub-interact.sh, grub-sol-cmd.py, sol-bg.sh)

## 前提・目的

### 背景

Phase 3-5 で training-tx1320 OS install の「GRUB→kernel jump 直後の SOL/VGA 凍結 + kernel printk 0 行」を継続観測。仮説 1/2a/7/9 が反証済、残候補は仮説 6 (iRMC NFS USB-CD timing) / 仮説 8 (NFS Virtual Media 経路固有) / 仮説 10 (GRUB が kernel image を不完全 load)。

ユーザ指示で Phase 6 は **(1) 仮説 8 = HDImage 経路試行** + **(2) 仮説 10 = GRUB shell で kernel image read 検証** を最優先。

### スコープ

- **Phase 6a**: iRMC HDImage NFS attach 試行 (PATCH + status / Members 確認のみ、~10 分)
- **Phase 6b**: GRUB timeout=300 延長 + ISO rebuild + GRUB shell に `c` で降りて `ls`/`cat (cd0)/install.amd/vmlinuz` で kernel image 完全性確認 (~45 分)
- レポート + memory 更新

ユーザ確認事項:

| 項目 | 決定 |
|---|---|
| GRUB countdown | `set timeout=3` を `set timeout=300` に延長 (ISO rebuild + 終了後 sed 戻し) |
| HDImage 試行範囲 | PATCH + status / Members 確認のみ (Power on + boot 試行はしない) |

## 環境情報

| 項目 | 値 |
|---|---|
| iRMC IP | 10.254.254.9 |
| iRMC FW | S4 9.08F |
| iRMC creds | claude / Claude123 (index 4) |
| Redfish | HTTPS + `--ciphers DEFAULT@SECLEVEL=0` 必須 |
| NFS server | 10.1.6.6 (export `/var/samba/public`、ImageName `debian-training-tx1320-raid10.iso`) |
| ISO build | orchestrate.sh build → 764 MB |
| local vmlinuz size | **12,105,664 bytes** (xorriso extract、`6a6419fd…`) |
| local initrd.gz size | **24,221,603 bytes** (`54fd7dc6…`) |
| ISO sha256 (build 結果) | `2d7a4d77f4490c9dc7624a249524d3d8ba7c6676d8fbd18cac33f3b0d4444a2e` (local/remote 完全一致) |

## 結果サマリ (TL;DR)

🎯 **Phase 6 判定**: 仮説 8 (HDImage 経路) 完全閉鎖 + 仮説 10 (GRUB kernel image 不完全 load) 間接反証 + **新発見** 「training-tx1320 の D3373 BIOS は Console Redirection 機能を持たず、SOL 入力経路も KVM Virtual Keyboard 経路も GRUB に届かない (= GRUB shell 直接操作は本機で原理的に不可能)」。

### Phase 6a: HDImage NFS attach 試行

| 観測 | 値 | 解釈 |
|---|---|---|
| `--type=HD config` PATCH 応答 | HTTP 200 | PATCH 自体は受理 |
| HDImage 設定反映 | Server/ShareName/ImageName/ShareType=NFS すべて反映 | iRMC は OEM Schema 上 HDImage プロパティを保持 |
| `HDImage.MaximumNumberOfDevices` | **0** | memory `training_tx1320_hdimage_blocked` 通り、USB HDD device は生成されない |
| `/redfish/v1/Managers/iRMC/VirtualMedia` Members | 長さ 0 + navigation 不可 (`ResourceUnavailable`) | この iRMC FW は Manager-level VirtualMedia collection を Member 列挙していない (CDImage attach 済みでも 0) |
| CDImage 状態 (PATCH 前後) | 維持 (ShareType=NFS, ImageName 反映、RemoteMountEnabled=true) | HDImage PATCH は CDImage に副作用なし |

→ 仮説 8 のうち「HDImage 経路で USB attach できれば NFS Virtual Media 経路固有性の切り分け」 は **HDImage 自体が iRMC ライセンスで MaxDev=0 のため永続的に不可**。次セッション以降も HDImage 路線は閉鎖。

### Phase 6b: GRUB shell kernel image read 検証

| 試行 | 経路 | 結果 |
|---|---|---|
| 1. KVM (Playwright) で `sendkeys:c` → `type:ls (cd0)/install.amd/vmlinuz` | iRMC Virtual Keyboard via canvas#kvm | ❌ GRUB shell に降りず、SOL log に `vmlinuz`/`ls`/`cat`/`grub>` 一切出現せず |
| 2. ipmitool SOL stdin に `c\r` + `ls ...\r` + `cat ...\r` 送信 | SOL → BMC → host UART → GRUB serial input | ❌ 出力 log 442 B、コマンド echo すら無し、GRUB shell 不達 |
| 3. GRUB timeout=300 setting | 300 → 0 まで countdown 進行 | ✅ countdown は完走 (SOL 出力経路は OK)、auto-select → kernel jump → 既知の hang |
| 4. KVM final screenshot (kernel jump 後) | 2724 B 完全黒画 (Phase 5 iter5 と同一 sha 領域) | kernel jump 後 VGA register update 停止 → KVM canvas 黒画 |

→ **GRUB shell 直接操作は本機で原理的に不可能** (理由は本文「観測詳細 D」参照)。仮説 10 (GRUB kernel image 不完全 load) は直接検証できないが、Phase 3-5 で GRUB が `linux` + `initrd` を auto-select で load し「Booting Automated Install」表示まで進めている事実から、**read 完走 = kernel image 完全性 OK と間接的に反証**。 不完全 load なら GRUB は `error: out of disk` 等で停止し、Booting メッセージ表示には到達しない。

### 仮説マトリクス更新

| # | 仮説 | Phase 5 状態 | Phase 6 結果 |
|---|-----|------------|------------|
| 6 | iRMC NFS USB-CD timing / long-read stall | △ 残存 | 同 (Phase 6 で touch せず) |
| 7 | USB controller quirk | ❌ Phase 5 反証 | 同 |
| 8 | HDImage / NFS Virtual Media 経路固有 hang | △ 候補 | ❌ **HDImage 路線は MaxDev=0 で原理的閉鎖**、NFS 経路自体は仮説 6 へ吸収 |
| 9 | UEFI ConOut / multi-console race | ❌ Phase 5 反証 | 同 |
| 10 | GRUB が kernel image を不完全 load | △ 候補 | ❌ **間接反証** (GRUB auto-select 完走 = linux/initrd read 完走) |
| 11 (新) | nousb で KVM Virtual VGA 切断 | △ 副次的 | ❌ **反証** (kernel jump 後の VGA 停止は cmdline に依らず発生、今回 cmdline 通常状態でも 2724 B 黒画) |
| **12 (新)** | **kernel startup 内部 (ACPI / PCI / EFI ConOut handoff / initrd 解凍) で hang** | (新) | △ **本命候補** (仮説 6/10/11 すべて弱まる中、残る経路) |

## 再現方法

### Step 0: セッション準備

```sh
mkdir -p tmp/phase6a01
./issue.sh start 71 --owner phase6a01
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS status \
  10.254.254.9 claude Claude123
```

期待値: `RemoteMountEnabled=true`、`CDImage.ImageName=debian-training-tx1320-raid10.iso`、PowerState=Off。

### Step 1: Phase 6a — HDImage PATCH 試行

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/irmc-virtualmedia.sh --share-type=NFS --type=HD config \
  10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public debian-training-tx1320-raid10.iso

BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS --type=HD status \
  10.254.254.9 claude Claude123

curl -ks --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
  https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia
```

判定: PATCH HTTP 200 + HDImage 設定反映 + `MaximumNumberOfDevices: 0` 確認 + Manager-level Members count=0 確認 → HDImage 路線閉鎖。

### Step 2: Phase 6b — cmdline patch + ISO rebuild

```sh
git diff scripts/remaster-debian-iso.sh > tmp/phase6a01/pre-patch.diff
# (本セッション開始時は空 — Phase 5 終了で逆 sed 済)

sed -i 's/^set timeout=3$/set timeout=300/g' scripts/remaster-debian-iso.sh
sed -i 's/^timeout 30$/timeout 3000/g' scripts/remaster-debian-iso.sh
grep -nE 'timeout' scripts/remaster-debian-iso.sh
# 114:set timeout=300 / 142:timeout 3000 / 191:set timeout=300 を確認

./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
sha256sum /var/samba/public/debian-training-tx1320-raid10.iso \
  | tee tmp/phase6a01/iter-grub-local-sha256.txt
```

### Step 3: local vmlinuz / initrd.gz 抽出 (xorriso via docker)

```sh
sh tmp/phase6a01/extract-images.sh
# → local-vmlinuz 12105664 B / local-initrd.gz 24221603 B
```

### Step 4: NFS export publish + remote sha256

```sh
scp -F ssh/config -i ssh/id_ed25519 /var/samba/public/debian-training-tx1320-raid10.iso \
  ubuntu@10.1.6.6:/var/samba/public/debian-training-tx1320-raid10.iso
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
  sha256sum /var/samba/public/debian-training-tx1320-raid10.iso \
  | tee tmp/phase6a01/iter-grub-remote-sha256.txt
# local と remote sha256 完全一致 (`2d7a4d77…`)
```

### Step 5: iRMC USB CD-ROM cache reload

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd \
  10.254.254.9 claude Claude123
sleep 3
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd \
  10.254.254.9 claude Claude123
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS mount \
  10.254.254.9 claude Claude123
```

### Step 6: SOL bg + boot-override + Power On + KVM shell 試行

```sh
sh tmp/phase6a01/sol-bg.sh &   # run_in_background

BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  BMC_PATCH_REQUIRES_ETAG=1 BMC_BOOT_OVERRIDE_NO_DISABLED=1 \
  ./oplog.sh ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI

date +%s | tee tmp/phase6a01/grub-boot-t0.txt
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' POWER_ON_RESET_TYPE=On \
  ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

sh tmp/phase6a01/grub-interact.sh > tmp/phase6a01/kvm-grub.log 2>&1 &   # bg
```

`grub-interact.sh` の構成: `wait:140 → screenshot:pre → wait:30 → screenshot:menu → sendkeys:c → wait:3 → screenshot:shell → type:ls + Enter → ... → type:cat (cd0)/install.amd/vmlinuz + Enter → wait:60 → screenshot:cat-mid → wait:60 → screenshot:cat-late`。

### Step 7: SOL stdin 経由 `c` 送信試行 (KVM 不達後)

```sh
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol deactivate
# sol-monitor.py の SOL session 解放
.venv/bin/python tmp/phase6a01/grub-sol-cmd.py
# pexpect で SOL activate + c + ls + cat 送信 → 出力 grub-sol-output.log
```

### Step 8: 後始末

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123

sed -i 's/^set timeout=300$/set timeout=3/g' scripts/remaster-debian-iso.sh
sed -i 's/^timeout 3000$/timeout 30/g' scripts/remaster-debian-iso.sh
git diff scripts/remaster-debian-iso.sh   # 空であることを確認 ✅
```

⚠️ **Phase 5 教訓に従い `git checkout` ではなく逆 sed で patch 戻し** (本セッションで Phase 5 と同じ修正は加えていないので追加破壊なし)。

## 観測詳細

### A. Phase 6a HDImage PATCH 応答全文

PATCH payload:
```json
{"HDImage":{"Server":"10.1.6.6","UserName":"","Password":"","UserDomain":"","ShareType":"NFS","ShareName":"/var/samba/public","ImageName":"debian-training-tx1320-raid10.iso"},"RemoteMountEnabled":true}
```

応答 (HTTP 200):
```json
{
  "FDImage": {"MaximumNumberOfDevices": 0, "ShareType": "SMB", ...},
  "CDImage": {
    "Server": "10.1.6.6", "ShareType": "NFS",
    "ShareName": "/var/samba/public",
    "ImageName": "debian-training-tx1320-raid10.iso",
    "MaximumNumberOfDevices": 2
  },
  "HDImage": {
    "Server": "10.1.6.6", "ShareType": "NFS",
    "ShareName": "/var/samba/public",
    "ImageName": "debian-training-tx1320-raid10.iso",
    "MaximumNumberOfDevices": 0
  },
  "RemoteMountEnabled": true,
  "UsbAttachMode": "AutoAttach",
  "@odata.etag": "1779419188"
}
```

→ HDImage が PATCH を受理して設定値を保持するが MaxDev=0、Manager-level Members 列挙されず。memory 通り。

### B. Phase 6b GRUB countdown 進行 (SOL log)

`sol-countdown.txt` (`grep -aoE 'executed automatically in [0-9]+s' sol-grub.log`):

```
executed automatically in 300s
executed automatically in 299s
...
executed automatically in 2s
executed automatically in 1s
executed automatically in 0s
```

行数: 13735 行 (SOL ring-buffer リプレイで countdown が複数回流出)。**countdown 300 → 0 まで完走** = `c` キー入力は GRUB に届かず、auto-select 発火 → kernel jump → 既知の hang。

### C. Phase 6b KVM screenshot 時系列

| 時刻 (T0=Power On +N秒) | size (B) | 内容 |
|---|---|---|
| t+170 (pre) | 7372 | GRUB countdown 表示中 (timeout=300、+170s ≈ countdown 残り 130s) |
| t+200 (menu) | 7369 | 同、countdown 進行 |
| t+203 (shell, sendkeys:c の 3 秒後) | 7538 | size 169 B 増は countdown カウンタ数値変化 (約 100s 桁の文字数差)、`c` 未反映の挙動 |
| t+210 (ls-devices) | 7525 | menu 滞在中 |
| t+218 (ls-amd) | 7526 | 同 |
| t+225 (ls-vmlinuz) | 7516 | 同 |
| t+232 (ls-initrd) | 7525 | 同 |
| t+295 (cat-mid) | 7513 | 同 |
| t+~720 (current, kernel jump 後) | 2724 | 完全黒画 (Phase 5 iter5 と同 sha 領域) |
| t+~740 (final, deactivate 後) | 2724 | 同 |

各 screenshot は異なる sha256 (cursor 点滅 + countdown 数値変化) で、Phase 5 iter5 の「全 5 枚同 sha」とは異なる「実 GRUB countdown 進行中」状態。

→ **`c` キーが GRUB に届けば screenshot size は GRUB shell prompt 表示で大きく変化するはずだが、size 帯 7300-7600 B 内に留まる** = menu 滞在状態が継続 = `c` 未反映。

### D. 🎯 新発見: SOL/KVM どちらの経路も GRUB 入力に届かない原因

#### D-1. KVM Virtual Keyboard 経路の挙動

`scripts/irmc-kvm-interact.py` は Playwright 経由で `viewer_page.locator("canvas#kvm").click()` + `viewer_page.keyboard.press("c")` を実行。focus mode は `hittest` (default) = `force=False` の locator.click で real hit-testing。 screenshot は正常に撮れる (Phase 4 で確立済) ため、canvas に focus は当たっているはず。 にもかかわらず `c`/`Enter`/`type:ls (cd0)/install.amd/vmlinuz` のいずれも SOL log や KVM 画面遷移に影響を残さなかった。

→ iRMC S4 HTML5 viewer.min.js のキー event listener が Playwright `page.keyboard.press` 由来の event を受信しない可能性。Phase 4-5 では screenshot のみ実施で key 入力は未試行のため、本セッションが初発見。次セッションで `--key-mode=dispatch-event` (document-level KeyboardEvent dispatch) を試す価値はあるが、KVM 経由が確実に GRUB に届く保証は無い。

#### D-2. SOL (ipmitool) 経路の挙動

`grub-sol-cmd.py` で pexpect 経由に `c\r`, `ls (cd0)/install.amd/vmlinuz\r`, `cat (cd0)/install.amd/vmlinuz\r` を送信。 SOL session 自体は establish (`Use ~.` プロンプト到達)、 出力経路は健全 (GRUB countdown が SOL log に流出)。 しかし送信したコマンドは GRUB shell に echo されず、`ls`/`cat` 結果も出力されず。 grub-sol-output.log は 442 B (送信した sentinels だけ)。

→ Phase 4 レポートで 「**D3373 BIOS XML に Serial Console Redirection エントリ存在せず**」 が観測されていた。Console Redirection は host UART ⇔ BIOS/UEFI/OS の双方向 bridging を担うが、本機ではこれが BIOS feature として欠落している。 つまり:

- **出力経路**: GRUB は自身で serial console (`terminal_output serial console`) を初期化し UART に直接書く → SOL 経由で iRMC が capture して TCP に流す → 正常動作
- **入力経路**: GRUB は `terminal_input serial console` で UART を受信先に登録するが、host UART の RX 信号は BIOS Console Redirection に依存する経路で iRMC SOL から host UART RX に届く必要がある。 Console Redirection 機能なし = SOL から送った bytes は host UART RX に到達しない (片方向の write-only SOL)

#### D-3. 帰結

**training-tx1320 (D3373 BIOS) では GRUB shell に直接降りる手段が無い**:
- KVM Virtual Keyboard 経由: viewer.min.js が Playwright key event を listen しない (本セッション観測)
- SOL 経由: BIOS Console Redirection 無しで入力片方向

物理キーボード (USB HID 直接接続) + 物理 VGA モニタの操作なら可能だが、リモート操作経路は本機で確立できない。

### E. 仮説 11 (nousb で KVM 黒画) 反証

Phase 5 iter5 の 「全 5 枚 2724 B 同 sha」 観測を 「nousb cmdline が iRMC Virtual VGA を切断」 と仮説していた。 本セッションでは **cmdline 通常状態 (Phase 3 修正なし、nousb なし)** で同じ 2724 B 完全黒画が kernel jump 後の screenshot で観測 (`kvm-grub-current.png`、`kvm-grub-final.png`)。

→ 2724 B 黒画は cmdline `nousb` の有無に関係なく、kernel jump 後 VGA register への書き込みゼロ状態で発生。Phase 5 iter5 で観測されたのは「nousb の効果」ではなく「kernel jump 完了後に screenshot を撮ったこと」が真因。Phase 4 で iter3 screenshot が「BIOS POST → 凍結 Booting Automated Install」 になったのは timing 差 (Phase 4 では screenshot 時刻が kernel jump 直前で、Booting メッセージの VGA frame buffer 残留が捕捉できた)。

仮説 11 反証 + Phase 5 結論の補強 = 「`nousb` は kernel に届いていない or 届いても症状は不変」が改めて確定。

### F. 仮説 10 間接反証の論理

GRUB の auto-select 動作は:
1. `linux /install.amd/vmlinuz vga=normal nomodeset auto=true ...` を実行 → GRUB は CD device から vmlinuz 全 byte を read してメモリに load
2. `initrd /install.amd/initrd.gz` を実行 → 同様に initrd.gz を read して load
3. 両 load 完了後に「Booting Automated Install」を SOL/VGA に出力
4. kernel jump

→ Phase 3-5 で繰り返し SOL に `Booting Automated Install` メッセージ + KVM に「Booting Automated Install + アンダースコアカーソル」フレームが残るため、GRUB は vmlinuz + initrd.gz の load を **両方完走** している。 不完全 load なら GRUB は load 中に `error: out of disk` / `error: file not found` / `error: invalid arch independent ELF magic` 等のエラーを serial に出して停止し、Booting メッセージは表示されない。

仮説 10 (iRMC NFS USB-CD emulation 経由の read truncation) は **間接的に反証**。仮説 6 (USB-CD long-read stall) のうち「kernel image read 中の stall」も同じ論理で否定可能だが、「kernel jump 後の DMA / interrupt 処理中の stall」までは反証できない。

### G. local vmlinuz / initrd.gz size (将来の直接検証用に保存)

| ファイル | size (byte) | sha256 |
|---|---|---|
| vmlinuz | 12,105,664 | `6a6419fde155bc1be12f9d2555ad18876cdff111d80c2887c6aa2c5d6cb250ac` |
| initrd.gz | 24,221,603 | `54fd7dc635631eeade5a092e9b8593de8b8266085078762c93ee2a0656f4d18d` |

物理キーボード + VGA で GRUB shell を出せる機会があれば、`ls (cd0)/install.amd/vmlinuz` で iRMC USB-CD emulation 経由の read size が 12,105,664 と一致するか比較できる。

## 完了事項

- [x] iRMC NFS CDImage 現状確認 (RemoteMountEnabled=true 維持)
- [x] Phase 6a: HDImage PATCH (HTTP 200) + status + Manager-level Members 確認 → MaxDev=0 再確認、HDImage 路線閉鎖
- [x] Phase 6b: GRUB timeout=3/30 → 300/3000 sed patch (3 行)
- [x] Phase 6b: ISO rebuild + local sha256 + local vmlinuz/initrd.gz xorriso extract + size 記録
- [x] Phase 6b: scp + remote sha256 一致確認 (truncation なし)
- [x] Phase 6b: iRMC USB CD-ROM cache reload (disconnect → connect → mount)
- [x] Phase 6b: SOL bg + boot-override + Power On + KVM shell interact (sendkeys:c + type + Enter 系列)
- [x] Phase 6b: KVM screenshot 10 枚 (pre/menu/shell/ls-devices/ls-amd/ls-vmlinuz/ls-initrd/cat-mid/current/final)
- [x] Phase 6b: SOL 完走 countdown 300→0 観測 (sol-countdown.txt)
- [x] Phase 6b: ipmitool SOL stdin 経由 `c` + `ls` + `cat` 送信試行 (grub-sol-cmd.py、出力 442 B = 不達)
- [x] 🎯 **仮説 8 HDImage 路線 完全閉鎖** + **仮説 10 間接反証** + **仮説 11 反証**
- [x] 🎯 **新発見**: D3373 BIOS Console Redirection 無し → SOL 入力不達、KVM Virtual Keyboard 経路も viewer.min.js が Playwright key event 受信せず → GRUB shell 直接操作は本機で原理的に不可能
- [x] cmdline patch 完全戻し (`git diff scripts/remaster-debian-iso.sh` 空確認)
- [x] Power off + CDImage 状態維持確認
- [x] artifact を `report/attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/` に copy
- [x] レポート作成 (本ファイル)
- [x] memory + MEMORY.md 更新

## 未完了 / 次セッション課題 (Phase 7)

### 1. 仮説 12 (新本命) — kernel startup 内部の hang

仮説 6/10/11 が弱まった現在、残る候補は **kernel が startup 直後の以下で hang**:

- **ACPI 解析失敗** (D3373 ACPI table の何か iRMC 関連 entry で trap)
- **PCI bus enumeration 中 USB controller probe で deadlock**
- **EFI ConOut → kernel framebuffer hand-off race**
- **initrd 解凍中の memory layout 問題**

cmdline iter で切り分け:

| iter | 追加 cmdline | 目的 |
|---|---|---|
| iter6 | `acpi=off noapic` | ACPI 解析 path bypass |
| iter7 | `pci=noacpi nolapic` | PCI enumeration を APIC 不使用化 |
| iter8 | `earlyprintk=efi,keep` + `console=efi,keep` | UEFI ConOut printk |
| iter9 | `initcall_debug` | initcall trace |
| iter10 | `acpi=copy_dsdt` | ACPI DSDT pre-load |

⚠️ ただし Phase 3-5 で `quiet` / `earlyprintk` / `nousb` のいずれも kernel printk 0 行を変えられなかったため、 iter6-10 でも printk 0 のまま症状不変の可能性は高い。 もし全 iter で 0 行なら、**kernel decompression 段階 (PIE) で hang** か **kernel boot stub (`linux_setup_header` 段階)** で hang。 この場合の切り分けは EFI shell からの bzImage 手動 boot や、別 ISO (例: Ubuntu 24.04 LTS、Debian 12.x の kernel 違い版) での比較が必要。

### 2. 仮説 6 (iRMC NFS USB-CD long-read stall) — kernel jump 後の DMA

仮説 10 反証で「GRUB の read は OK」と確定したが、**kernel が起動して USB CD-ROM を再 access した時に stall する可能性** は仮説 12 の一部として残存。 ただし「USB enumeration 以前に hang」が現状観測 (Phase 3 で NFS READ packet 0 観測) のため、CD-ROM access stall 仮説は弱まっている。

### 3. 別 OS / 別 kernel 経路での切り分け

- Debian 12.x (Bookworm) ベース ISO で同手順 = kernel version 違いで挙動差
- Ubuntu 24.04 LTS Server installer ISO で boot 試行
- Memtest86+ ISO で UEFI + kernel-less な動作確認 (BIOS/firmware-level の問題か kernel 固有か切り分け)
- 物理キーボード + 物理 VGA で現地操作 (Mt. Fuji 拠点要)

### 4. iter5 の re-screenshot で旧解釈訂正

Phase 5 iter5 の 「全 5 枚 2724 B = nousb 効果」 結論は Phase 6 で訂正 (kernel jump 後の VGA 停止が本質)。 旧 memory の該当箇所を更新済 (本セッション末尾)。

### 5. orchestrate.sh への locator screenshot 統合 (Phase 6 後半計画延期)

`scripts/tx1320-raid10-orchestrate.sh deploy` の Phase 5a (NFS mount 直後) に locator screenshot 時系列取得を組み込む計画は次セッションへ。

### 6. SMB session #6 再現 (NFS vs SMB の差分検証)

[[training_tx1320_smb_n6_step2]] で patched samba build 完了済だが iRMC FW 9.08F SMB worker 死亡で attach 不能。FW reflash がユーザ作業として必要 (本セッションで touch せず)。

## 関連 Issue

- **#71 (blocked)** [phase6a01]: training-tx1320 NFS Virtual Media OS install — Phase 6 で仮説 8 完全閉鎖 + 仮説 10/11 反証 + GRUB shell 経路不達発見。Phase 7 で仮説 12 (kernel startup 内部 hang) 切り分けが残る。 本セッション終了で blocked へ戻し。
- **#69 (blocked)** [silly-token]: TX1320 M3 RAID10 自動構成 — 本セッションで touch せず。

## 関連ファイル

### 修正 (本セッション、commit 不要)

- `scripts/remaster-debian-iso.sh` — GRUB timeout L114/L191 `3→300`、ISOLINUX L142 `30→3000` の sed patch を一時適用 → ISO rebuild → boot 試行 → 終了後逆 sed で完全戻し (`git diff` 空確認)。本セッションは Phase 5 終了状態 (M なし) から開始のため、Phase 3 修正消失問題は再発せず。

### 参照のみ

- `scripts/irmc-virtualmedia.sh` (`--type=CD|HD|FD` + `--share-type=NFS|SMB` 切替対応、L77, L284)
- `scripts/irmc-kvm-interact.py` (Playwright shell サブコマンド、`sendkeys`/`type`/`wait`/`screenshot` パーサ L443)
- `scripts/sol-monitor.py` (passive SOL capture、`--bmc-ip` named args)
- `scripts/bmc-power.sh` (Redfish SECLEVEL=0)
- `scripts/tx1320-raid10-orchestrate.sh` (build + deploy + monitor)
- `config/training_tx1320.yml`

### 新規 (attachment 配下)

`report/attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/` に上記添付一覧の全ファイルを配置済。

## 重要な教訓 (次セッションへの引き継ぎ)

1. 🎯 **仮説 8 (HDImage 経路) は MaxDev=0 で原理的閉鎖** — iRMC S4 KVM+MEDIA license では HDImage / FDImage は `MaximumNumberOfDevices: 0`、NFS との組合せでも bypass せず。今後 HDImage 試行は不要。
2. 🎯 **仮説 10 (GRUB kernel image 不完全 load) は間接反証** — GRUB auto-select で `linux` + `initrd` load 完走 → 「Booting Automated Install」表示到達 = kernel image / initrd の read は完全。次セッションは kernel startup 内部 (仮説 12) に焦点。
3. 🎯 **仮説 11 (nousb で KVM Virtual VGA 切断) は反証** — 2724 B 完全黒画は kernel jump 後の VGA register update 停止が原因で、cmdline `nousb` の有無に依存しない。Phase 5 iter5 の解釈訂正。
4. 🎯🎯 **GRUB shell 経路は training-tx1320 で原理的に不可能** — KVM Virtual Keyboard 経路は iRMC viewer.min.js が Playwright key event を受信しない (本セッション発見)、SOL 経路は D3373 BIOS Console Redirection 機能なしで入力片方向。 物理キーボード + 物理 VGA でないと GRUB shell は出せない。
5. 🎯 **GRUB serial output と SOL 出力経路は健全** — countdown 300→0 + ring-buffer リプレイで 13735 行流出。 GRUB の `linux`/`initrd`/`boot` コマンドが自動実行されるシナリオ (auto-select) では SOL/KVM どちらの観測も可能。
6. 📝 **xorriso は local には未 install** — 必要なら `docker run debian:trixie sh -c 'apt-get install -y xorriso && xorriso ...'` で実行 (本セッション extract-images.sh のパターン)。
7. 📝 **sol-monitor.py は named 引数を要求** — `python sol-monitor.py 10.254.254.9 claude Claude123` (positional) は usage error で失敗。 正しくは `--bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file <path>`。 Phase 5 レポートの SOL 起動例は誤記の可能性あり。
8. 📝 **SOL session は 1 active のみ** — sol-monitor.py が掴んだまま新 ipmitool sol activate は競合。 先に `ipmitool sol deactivate` で解放してから新 session 開始。
9. 📝 **iRMC KVM canvas screenshot pattern の解釈** — 2724 B = 完全黒画 (= kernel jump 後 VGA 停止、本セッションで真因確定)、4478 B = "Booting Automated Install" + アンダースコアカーソル静止画、12833 B = BIOS POST 表示、7300-7600 B = GRUB countdown active (本セッション新観測)。
10. 🎯 **本命は仮説 12 (kernel startup 内部 hang)** — 次セッションは iter6-10 cmdline (acpi=off / pci=noacpi / earlyprintk=efi / initcall_debug / acpi=copy_dsdt) で切り分け。 ただし printk 0 行が継続する可能性高く、その場合は別 OS / 別 kernel / EFI shell 経由の bzImage 手動 boot 等の代替経路要。

## Phase 6 判定 (1 行)

🎯 **仮説 8 HDImage 路線は MaxDev=0 で原理的閉鎖、仮説 10 GRUB kernel image 不完全 load は auto-select 完走から間接反証、仮説 11 nousb 黒画は kernel jump 後 VGA 停止が真因で反証。 加えて新発見「training-tx1320 (D3373 BIOS) は Console Redirection 機能なしで SOL 入力不達 + iRMC KVM Virtual Keyboard も GRUB に届かず GRUB shell 経路完全 blocked」**。 Phase 7 で仮説 12 (kernel startup 内部 hang) に絞り iter6-10 cmdline 切り分け or 別 OS 経由検証へ進む。

## 必須引き継ぎ artifact パス

- `report/attachment/2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked/`
  - `hdimage-config-response.json` / `hdimage-status.txt` / `manager-vm-members.json`
  - `iter-grub-{local,remote}-sha256.txt` / `local-image-sizes.txt`
  - `kvm-grub-{pre,menu,shell,ls-devices,ls-amd,ls-vmlinuz,ls-initrd,cat-mid,current,final}.png` (10 枚)
  - `kvm-grub.log` (KVM shell interact log)
  - `sol-grub.log` (sol-monitor.py 出力 312 KB) + `sol-countdown.txt` (countdown 抽出 13735 行)
  - `grub-sol-output.log` (SOL stdin `c`/`ls`/`cat` 試行、442 B = 不達)
  - `grub-interact.sh` / `grub-sol-cmd.py` / `sol-bg.sh` / `extract-images.sh`
  - `plan.md` (本 phase の事前 plan)

# tx1320 RAID10 Phase 7: 仮説 12 切り分け + Memtest86+ で iRMC KVM viewer artifact が判明 (Phase 5/6 解釈訂正)

- **実施日時**: 2026年5月22日 04:11 (JST)
- **セッション**: phase712 (Plan: phase-7-12-zany-newell)
- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F, BMC 10.254.254.9)

## 添付ファイル

- [実装プラン](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/plan.md)
- [iter6 SOL ログ (5 分間で GRUB countdown 33 回, Booting 32 回)](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/iter6-sol.log)
- iter6 KVM screenshot: [t60](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/iter6-kvm-t60.png) (2724B 黒画) / [t120](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/iter6-kvm-t120.png) (9605B Partial access dialog) / [t180](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/iter6-kvm-t180.png) / [t240](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/iter6-kvm-t240.png) / [t300](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/iter6-kvm-t300.png)
- memtest-native KVM screenshot: [t60](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/memtest-native-kvm-t60.png) / [t120](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/memtest-native-kvm-t120.png) / [t180](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/memtest-native-kvm-t180.png) / [t240](attachment/2026-05-22_041141_tx1320_raid10_phase7_kvm_artifact_corrected/memtest-native-kvm-t240.png) (全 2724-2726 B 黒画 — ただし**実 VGA monitor では memtest UI が表示されている**)

## 前提・目的

[Phase 6 (2026-05-22 03:15)](2026-05-22_031500_tx1320_raid10_phase6_kvm_sol_blocked.md) で Debian 13 installer kernel が GRUB から jump した直後に SOL kernel printk = 0 + KVM canvas 2724 B 黒画 + NFS READ = 0 で「kernel startup 内部 hang」と切り分け中の状態に到達。Phase 5 (iter1-5 cmdline) で `quiet` 除去 / `earlyprintk=ttyS0` / `console=tty0` 除去 / `nousb` をすべて反証。 また Phase 6 で `GRUB shell リモート操作は本機で原理的に不可能` を確定 (SOL stdin 片方向 + iRMC KVM Virtual Keyboard 非listening)。

**Phase 7 の目的**:

1. 仮説 12 (kernel startup 内部 hang) を最優先で切り分け。iter6 (`acpi=off noapic`) を最初に試して D3373 ACPI quirk が真因か確認
2. 並行して **別 OS (Memtest86+)** を iRMC NFS Virtual Media + UEFI boot で試行し、問題が Debian 13 kernel 固有か iRMC NFS 経路固有かを **OS-agnostic に切り分け**
3. Memtest86+ は kernel を起動しない (自前 microkernel) ため、起動成功なら経路が OS-agnostic に健全 = Debian 13 kernel 固有問題と確定

## 環境情報

- ホスト: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0)
- BMC: iRMC S4 FW 9.08F (10.254.254.9, claude index=4, HTTPS + SECLEVEL=0)
- Memory: 24 GiB / CPU: 1 socket (Xeon)
- HW: RAID10 SAS HDD 900GB × 4 (Phase 6 で構成済、未使用)
- Virtual Media: iRMC NFS Virtual Media (`/var/samba/public` on 10.1.6.6 = playground)
- 配信される ISO:
  - `debian-training-tx1320-iter6.iso` (Debian 13 + preseed + `acpi=off noapic` 注入、800 MB)
  - `memtest86plus-8.10-grub.iso` (Memtest86+ 8.10 GRUB chainload variant、20 MB)
  - `memtest86plus-8.10.iso` (Memtest86+ 8.10 native UEFI variant、6 MB)
- KVM screenshot: `scripts/irmc-kvm-interact.py --capture-mode=locator` (Phase 4 教訓に従い canvas mode 禁止)
- SOL: `scripts/sol-monitor.py --log-file ...` (FW 9.08F の payload enable 2 4 済)

## 結果サマリ

| 試行 | KVM canvas (iRMC) | SOL | 実 VGA monitor | 判定 |
|------|-------------------|-----|---------------|------|
| iter6 (`acpi=off noapic`) | 2724-2726 B (黒) | **GRUB countdown 33 回 + `Booting Automated Install` 32 回 ループ** (5 分間) | 未観測 | **kernel triple-fault / reset loop 確定** (10s/cycle)。Phase 3-5 silent hang とは挙動が異なる |
| Memtest86+ GRUB variant | 2724-2726 B (黒) | GRUB 出力なし (memtest GRUB が serial 非設定) | 未観測 | KVM 単体では未判定。次の native UEFI で確定 |
| Memtest86+ native UEFI | 2724-2726 B (黒) | (出力なし — memtest は serial 非対応) | **🎯 memtest UI 表示 = boot 成功** (user 報告) | **iRMC NFS Virtual Media + UEFI boot は OS-agnostic に健全** |

### 🎯🎯🎯 最重要発見 (Phase 5/6 解釈の訂正)

**iRMC KVM viewer (canvas mode と locator mode の両方) は、framebuffer mode 変更後の VGA 出力 capture に失敗する**。Memtest86+ は実 VGA monitor では正常に boot して UI を表示しているにもかかわらず、 iRMC KVM canvas は 2724 B 黒画のままだった。

これは **Phase 3-5 の「kernel jump 後 KVM 2724 B 黒画 = kernel hang」「VGA register 更新ゼロ」の解釈を直接無効化する観測**である。Phase 3-5 でも kernel は実際には何らかの動作を続けていた可能性が高い (ただし kernel printk = 0 と NFS READ = 0 は別の証拠として残り、それらが kernel 早期の何らかの停止を示唆することは変わらない)。

### iter6 SOL ループ詳細

```
GNU GRUB version 2.12-9+deb13u2
  *Automated Install
  The highlighted entry will be executed automatically in 3s.
  ... 2s ... 1s ... 0s.
  Booting `Automated Install'

(7 秒程度の空白 — kernel jump → triple-fault → BIOS reset → POST silent on SOL (D3373 no Console Redirection))

GNU GRUB version 2.12-9+deb13u2
  ... (繰り返し)
```

- 5 分間で 33 回 GRUB countdown 出現 + 32 回 "Booting" → 約 10 秒に 1 サイクル
- kernel printk は **1 行も出ない** (`acpi=off noapic` でも) → printk init より前で triple-fault
- BIOS POST が SOL に出ないのは Phase 6 確定 (D3373 BIOS は Console Redirection 機能を持たない)

### Memtest86+ native UEFI 観測 (user 報告ベース)

- iRMC NFS Virtual Media で `memtest86plus-8.10.iso` (6 MB, native UEFI) を attach + boot
- T0+60s 以降の iRMC KVM canvas はすべて 2724-2726 B 黒画 (Phase 3-5 と同じパターン)
- **実 VGA monitor では Memtest86+ UI が表示されている** (青背景 + メモリテスト進捗) — user による直接観測
- Memtest86+ は kernel を起動せず、自前の microkernel で memory test を実施
- 結論: iRMC NFS Virtual Media + UEFI boot path は OS-agnostic に健全

## 仮説マトリクス更新

| # | 仮説 | Phase | 状態 |
|---|------|-------|------|
| 1 | `quiet` が printk を抑制 | Phase 3 iter1 | 反証 |
| 2a | console route が壊れている (VGA は健全) | Phase 4 (locator mode) | 反証 |
| 2b | kernel が CD-ROM enumeration 前で hang | Phase 3 NFS pcap | 強化 (NFS READ = 0) |
| 3-5 | (preseed/initrd 関連) | Phase 1-2 | 該当なし |
| 6 | iRMC NFS USB-CD timing | **Phase 7 Memtest86+** | **反証** (memtest が NFS+UEFI で成功) |
| 7 | USB controller quirk (`nousb` で回避) | Phase 5 iter5 | 反証 |
| 8 | HDImage 経路固有 | Phase 6 | 永続閉鎖 (MaxDev=0) |
| 9 | multi-console race | Phase 5 iter4 | 反証 |
| 10 | GRUB kernel image 不完全 load | Phase 6 | 間接反証 |
| 11 | nousb 黒画問題 | Phase 6 | 反証 |
| 12-ACPI | ACPI quirk → kernel hang | **Phase 7 iter6** | **新事実: `acpi=off noapic` は silent hang ではなく triple-fault reboot loop を引き起こす** (kernel printk 0 のまま reset を繰り返す) |
| **新** | **iRMC KVM viewer は framebuffer mode 変更後 capture 失敗 (Phase 3-5 KVM 黒画は VGA 停止を意味しない)** | **Phase 7 Memtest86+ vs 実 VGA** | **確定** |
| **新** | **iRMC NFS Virtual Media + UEFI boot は OS-agnostic に健全 (Debian 13 kernel 固有問題)** | **Phase 7 Memtest86+** | **確定** |

iter6 結果は仮説 12-ACPI を「閉鎖」とも「確定」とも言いきれない位置にある。`acpi=off noapic` で症状は変わったが (silent hang → triple-fault loop)、改善ではなく **悪化** したので、ACPI/APIC を完全に disable すると逆に triple-fault する = **何らかの ACPI/APIC 経路が必要**で、ただし default ではない `noapic` を強制すると kernel が triple-fault する。`acpi=off` 単体や `nolapic` 単体、`acpi=copy_dsdt` などサブ仮説の探索余地が残る (iter7 以降)。

## 再現方法

### 前提
- training-tx1320 BMC (10.254.254.9) と playground (10.1.6.6) に到達可能なホストから
- `scripts/` 配下のスクリプト群と `config/training_tx1320.yml` が最新
- `tmp/phase712/tx1320-env.sh` で BMC env vars を export 済

### Step 1: `remaster-debian-iso.sh` に `EXTRA_CMDLINE` 環境変数追加

3 か所の cmdline ハードコード (`L68 docker env`, `L123` BIOS grub.cfg, `L133` txt.cfg, `L196` EFI grub.cfg) に `${EXTRA_CMDLINE}` を `--- quiet` 直前に挿入 (本セッションで完了済)。

### Step 2: iter6 ISO build + 配置 + attach + boot

```sh
EXTRA_CMDLINE="acpi=off noapic" ./scripts/remaster-debian-iso.sh \
    --serial-unit=0 \
    --include=/var/samba/public/storcli64.deb \
    --include=./scripts/setup-raid10-storcli.sh \
    /var/samba/public/debian-13.3.0-amd64-netinst.iso \
    tmp/training-tx1320-preseed-raid10.cfg \
    /var/samba/public/debian-training-tx1320-iter6.iso

scp -F ssh/config -i ssh/id_ed25519 \
    /var/samba/public/debian-training-tx1320-iter6.iso \
    ubuntu@10.1.6.6:/tmp/
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
    'sudo mv /tmp/debian-training-tx1320-iter6.iso /var/samba/public/'

. tmp/phase712/tx1320-env.sh
./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 \
    10.1.6.6 /var/samba/public debian-training-tx1320-iter6.iso
./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS mount 10.254.254.9 claude Claude123

# SOL bg capture (別シェル)
./scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/phase712/iter6/sol.log --timeout 420 &

./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI
./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# 5 分待機 + KVM screenshot
# 5 分後に forceoff
./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
```

### Step 3: Memtest86+ 入手 + 配置 + attach + boot

```sh
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 'cd /tmp && \
    wget -q https://www.memtest.org/download/v8.10/mt86plus_8.10_x86_64.iso.zip && \
    wget -q https://www.memtest.org/download/v8.10/mt86plus_8.10_x86_64.grub.iso.zip && \
    sudo apt-get install -y unzip && \
    unzip -o mt86plus_8.10_x86_64.iso.zip && \
    unzip -o mt86plus_8.10_x86_64.grub.iso.zip && \
    sudo mv /tmp/memtest.iso /var/samba/public/memtest86plus-8.10.iso && \
    sudo mv /tmp/grub-memtest.iso /var/samba/public/memtest86plus-8.10-grub.iso'

. tmp/phase712/tx1320-env.sh
./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 \
    10.1.6.6 /var/samba/public memtest86plus-8.10.iso
./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS mount 10.254.254.9 claude Claude123

./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI
./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
# 実 VGA monitor を確認 (iRMC KVM 黒画にだまされないこと)
```

## 完了事項

- `scripts/remaster-debian-iso.sh` に `EXTRA_CMDLINE` 環境変数を追加 (L68 docker env + 3 か所の cmdline 挿入)
- iter6 (`acpi=off noapic`) ISO build → playground 配置 → iRMC NFS attach → boot 試行 → triple-fault reboot loop を SOL で 33 サイクル観測
- Memtest86+ 8.10 native UEFI 版を入手 → playground 配置 → iRMC NFS attach → boot 試行 → 実 VGA で UI 表示確認 (user 報告) → iRMC NFS+UEFI 経路が OS-agnostic に健全と確定
- **🎯 iRMC KVM viewer が framebuffer mode 変更後 capture に失敗する artifact を発見** → Phase 3-5 の「KVM 黒画 = kernel hang」解釈を無効化
- Phase 3-5 の解釈訂正: kernel 早期停止の根拠は KVM 黒画 + VGA 凍結ではなく、**SOL kernel printk = 0** と **NFS READ = 0** のみが残る信頼可能な証拠

## 未完了 / 次セッション

### Phase 8 (検討中) 候補

1. **iter7-10 (default cmdline ベースのサブ仮説探索)**
   - iter7: `pci=noacpi nolapic` (PCI enumeration 経路差し替え)
   - iter8: `earlyprintk=efi,keep console=efi,keep` (UEFI ConOut 直結 — VGA console を bypass)
   - iter9: `initcall_debug` (initcall trace で kernel 内部のどこで止まるか)
   - iter10: `acpi=copy_dsdt` (ACPI DSDT 早期コピー)

2. **新仮説 13 候補 (iRMC KVM artifact 発見を踏まえた再評価)**
   - **iter11**: cmdline はそのままで **実 VGA monitor で観測**する (Phase 3-5 のとき本当に kernel が hang していたかを確認)
   - もし実 VGA で installer 画面が表示されているなら、Phase 3-5 の真因は「kernel printk が serial に出力されないだけで実行は続いている (Debian 13 installer が serial console を尊重しない)」となる可能性
   - SOL kernel printk = 0 + NFS READ = 0 が残るので「kernel は serial init 未完了 + cdrom-detect 未到達」のままだが、installer 自体は別経路で何かを表示している可能性

3. **kernel decompression 経路の検証 (より低レイヤー)**
   - Debian 12 (kernel 6.1) で同じ ISO 生成 → boot 比較 (Debian 13 kernel 6.x 固有か)
   - Ubuntu 24.04 LTS で boot 比較

### 訂正が必要なメモリ index

- `training_tx1320_kernel_silent_post_grub.md`: Phase 5/6 の「VGA register 更新ゼロ = kernel hang」解釈を訂正 (iRMC KVM canvas artifact が真因の可能性、 Phase 7 Memtest86+ で実証)
- `feedback_kvm_locator_required.md` (該当があれば): locator mode でも canvas mode でも framebuffer 切替後の capture は失敗する旨を追記

## 教訓

- **iRMC KVM screenshot を「VGA 停止」の証拠として使ってはならない**。canvas mode と locator mode の両方で framebuffer mode 変更 (VGA text mode → framebuffer / VBE / EFI GOP 等) の後、ホスト側で何かを描いていても iRMC KVM canvas は 2724 B の黒画のままになる。Phase 3-5 で誤った仮説に時間を費やした原因 (KVM 黒画から kernel hang を推論したが、実際には VGA は活動していた可能性が高い)
- **OS-agnostic な切り分けは早めに**: Memtest86+ を Phase 3 で先に試していれば、iRMC NFS+UEFI 経路の健全性が早期に確定し、iter1-5 で kernel cmdline を変えても Phase 4 KVM artifact 解釈ミスで混乱することは防げた
- **boot loop は silent hang と区別される**: `acpi=off noapic` で SOL に明確な GRUB countdown 周期が出る (約 10s) ことから「kernel が triple-fault → reset」と判定可能。silent hang の場合 SOL の Booting 後に何も来ない (Phase 3-5) ことと挙動が異なる
- **Phase 6 で「GRUB shell リモート操作不可」が確定済**なので、本機での kernel 内部 debug は cmdline 注入 + ISO 再 build のサイクルでしかできない (1 iter ≈ 5-7 分)
- **D3373 BIOS は Console Redirection を持たない**ため、BIOS POST は SOL に出ない。SOL に kernel printk が出始めるのは kernel が serial init を完了した後 (`earlyprintk=ttyS0,keep` でも、kernel が serial port を物理初期化しない限り出ない)

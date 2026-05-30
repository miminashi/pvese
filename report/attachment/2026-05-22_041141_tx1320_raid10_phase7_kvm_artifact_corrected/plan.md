# Phase 7: 仮説 12 (kernel startup 内部 hang) 切り分け + 別 OS 経路検証

## Context

Phase 3-6 で Debian 13 installer kernel が GRUB から jump した直後に完全沈黙する現象を調査した結果、以下が確定:

- GRUB は kernel + initrd を完走 load (Phase 6 で確認、SOL に "Booting Automated Install" 表示まで到達)
- kernel printk = 0 / VGA register 更新 = 0 / NFS READ = 0 / kernel jump 後 KVM canvas は 2724 B 完全黒画
- iter1-5 (`quiet` 除去 / `earlyprintk=ttyS0` / `console=tty0` 除去 / `nousb` 追加) すべて kernel printk 0 で反証
- SOL stdin 片方向 (D3373 BIOS が Console Redirection 未搭載) + iRMC KVM Virtual Keyboard も非listening → GRUB shell リモート操作不可
- iRMC NFS Virtual Media は健全 (mount/boot 可能、GRUB load まで OK)
- HDImage 経路は MaxDev=0 で永続閉鎖 (license 制限)

**Phase 7 の目的**: 仮説 12 (kernel startup 内部 hang) を切り分ける。同時に、問題が Debian 13 kernel 固有か iRMC NFS Virtual Media 経路 (HW/firmware) 固有かを **OS-agnostic な検証** (Memtest86+) で確定させる。

仮説 12 の中で **iter6 (`acpi=off noapic`) を最初に試す** = D3373 ACPI quirk が真因かを最短で確認。Memtest86+ は kernel を起動しない (自前 microkernel) ため、起動成功なら「iRMC NFS Virtual Media + GRUB load 経路は OS-agnostic に健全」が確定し、Debian 13 kernel 固有問題に絞り込める。

## Plan

### Step 1 (Stream A): `remaster-debian-iso.sh` に `EXTRA_CMDLINE` 環境変数を追加

**変更対象**: `scripts/remaster-debian-iso.sh`

3 か所の kernel cmdline ハードコードに `${EXTRA_CMDLINE}` を `--- quiet` の直前へ挿入し、docker run の env でパススルー:

- L68 周辺 `docker run` の `-e` フラグに `-e "EXTRA_CMDLINE=${EXTRA_CMDLINE:-}"` を追加
- L123 (BIOS grub.cfg menuentry の `linux` 行)
- L133 (`txt.cfg` の `append` 行)
- L196 (EFI embed grub.cfg menuentry の `linux` 行)

挿入位置はすべて `console=ttyS${SERIAL_UNIT},115200n8 ${EXTRA_CMDLINE} --- quiet` の形。シェル変数展開のため heredoc は quote なし (現状維持) で OK。

呼び出し側に修正不要 (`EXTRA_CMDLINE="acpi=off noapic" ./scripts/remaster-debian-iso.sh ...` で渡せる)。

### Step 2 (Stream A): iter6 ISO を build + NFS 配置 + attach + boot

ISO ファイル名は iter ごとに別名化して切替を容易にする:
- iter6 → `debian-training-tx1320-iter6.iso`
- (今後の iter7-10 も同じ規約)

手順:

1. `EXTRA_CMDLINE="acpi=off noapic" ./scripts/remaster-debian-iso.sh --serial-unit=0 --include=... /var/samba/public/debian-13.3.0-amd64-netinst.iso tmp/<sid>/training-tx1320-preseed-raid10.cfg /var/samba/public/debian-training-tx1320-iter6.iso`
   - preseed と include 一覧は Phase 6 で確立した orchestrator の `build` 関数を参照。再利用するため orchestrator は経由せず `remaster-debian-iso.sh` を直接呼ぶ
2. `scp` で ISO を `10.1.6.6:/var/samba/public/` に転送
3. `./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd` で既存 attach を切断
4. `... config 10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public debian-training-tx1320-iter6.iso` で ImageName 切替
5. `... connect-cd` → `... mount` で attach
6. SOL bg capture 開始 (`sol-monitor.py --bmc-ip 10.254.254.9 --log-file tmp/<sid>/phase7-iter6-sol.log`)
7. NFS server (10.1.6.6) で tcpdump 開始 (`host 10.254.254.9 and port 2049`)
8. `bmc-power.sh boot-override Cd UEFI` → `bmc-power.sh on` (`./oplog.sh` + `./pve-lock.sh run` で包む)
9. T0+60, +120, +180, +240, +300s で `irmc-kvm-interact.py --capture-mode=locator` (canvas mode 禁止、Phase 4 教訓)
10. T0+360s で `bmc-power.sh forceoff`
11. SOL ログ + KVM screenshot を `tmp/<sid>/phase7-iter6/` に集約

### Step 3 (Stream B): Memtest86+ を NFS 経由で起動 (並行検証)

**入手**: playground (10.1.6.6) は internet 到達可能なため、playground 上で:

```sh
ssh -F ssh/config ubuntu@10.1.6.6
sudo wget -O /var/samba/public/memtest86plus.iso.zip https://www.memtest.org/download/<latest>/mt86plus_<ver>_64.iso.zip
sudo unzip -d /tmp/ /var/samba/public/memtest86plus.iso.zip
sudo mv /tmp/mt86plus_*.iso /var/samba/public/memtest86plus.iso
```

(URL とバージョンは memtest.org でその時点の最新を確認)

**attach 切替**: iter6 と同じ手順だが ISO 再ビルド不要、ImageName だけ `memtest86plus.iso` に変える:

```sh
./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public memtest86plus.iso
./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS mount 10.254.254.9 claude Claude123
```

**観測**: power on 後 T0+90, +150, +240s で `irmc-kvm-interact.py --capture-mode=locator` 撮影。Memtest86+ は青背景 + ロゴ + メモリテスト進捗を VGA に描く。

### Step 4: 判定とレポート作成

| 観測 | 結論 |
|------|------|
| iter6 で kernel printk > 0 | 仮説 12-ACPI 確定 → printk 内容を観察 (panic / Call Trace / RIP / ACPI: prefix) して次の絞り込み |
| iter6 で完全沈黙 (kernel printk 0、KVM 2724 B 黒画) | ACPI 仮説反証 → iter7-10 の準備 (`pci=noacpi nolapic` 等) |
| Memtest86+ が起動成功 (青背景 UI 表示) | iRMC NFS Virtual Media + GRUB load 経路は OS-agnostic に健全 → Debian 13 kernel 固有問題 |
| Memtest86+ も沈黙 | iRMC / HW / firmware 層の問題 → Debian 13 とは独立した障害 (kernel 経路全部 NG) |

Phase 7 終了後、`/home/ubuntu/projects/pvese/report/2026-05-22_<HHMMSS>_tx1320_raid10_phase7_<結果>.md` をフォーマット REPORT.md 準拠で作成。仮説マトリクスを更新 (仮説 12 サブ仮説の確定/反証、メモリ index `training_tx1320_kernel_silent_post_grub.md` を Phase 7 結果で追記)。

iter7-10 / Debian 12 経路への拡張は **Phase 7 結果次第** で別 Phase に切る (本 Phase のスコープには含めない)。

## Critical Files

- `scripts/remaster-debian-iso.sh` (cmdline 注入の改修対象、L68 docker env / L123 / L133 / L196)
- `scripts/irmc-virtualmedia.sh` (NFS attach/detach のドライバ、変更なし、再利用のみ)
- `scripts/sol-monitor.py` (SOL bg capture、Phase 6 で動作確立済、再利用のみ)
- `scripts/irmc-kvm-interact.py` (KVM screenshot 必須 — `--capture-mode=locator` 指定、canvas mode 禁止)
- `scripts/bmc-power.sh` (boot-override + power on/off)
- `config/training_tx1320.yml` (nfs_host=10.1.6.6, nfs_export_path=/var/samba/public — 参照のみ)

## Verification

1. `remaster-debian-iso.sh` を `EXTRA_CMDLINE="acpi=off noapic"` で実行し、ISO が完成すること (output ISO size + xorriso 完了メッセージ)
2. xorriso で出力 ISO 内の `/boot/grub/grub.cfg` を確認し、`acpi=off noapic` が cmdline 内に含まれていること (`xorriso -indev <iso> -extract /boot/grub/grub.cfg -` で標準出力 dump)
3. iter6 起動後、SOL ログ (`tmp/<sid>/phase7-iter6-sol.log`) に "Booting Automated Install" がまず出ること = GRUB jump まで Phase 6 と同じ進行
4. iter6 起動後 5 分、kernel printk が出現するか / 完全沈黙かを SOL ログから判定 (`grep -aE '\[ +[0-9]+\.[0-9]+\]'`)
5. Memtest86+ 起動後 4 分、KVM screenshot に Memtest UI が映るか / 沈黙かを判定
6. NFS tcpdump (10.1.6.6 側) の packet count を tshark で集計し、各経路の NFS READ 発生有無を定量化

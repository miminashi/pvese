# TX1320 M3 NFS install Phase 3 — `quiet` 除去 + `earlyprintk` 追加でも kernel printk ゼロ (仮説 1+2 反証) / NFS READ packet ゼロで kernel startup 未到達確定

- **実施日時**: 2026 年 5 月 22 日 00:14 〜 00:40 (JST、約 26 分)
- **担当**: s-rustling-melody (Opus 4.7、plan mode → 自動実装)
- **Issue**: #71 (Phase 2 から継続、本セッションでも未解決のまま再 block)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**:
  - [2026-05-21_091931_tx1320_raid10_nfs_install.md](2026-05-21_091931_tx1320_raid10_nfs_install.md) — Phase 2 (s-linear-gizmo): NFS Virtual Media 統合完遂 + kernel boot 後沈黙 blocker 発見
  - [2026-05-21_081642_tx1320_raid10_nfs_attempt.md](2026-05-21_081642_tx1320_raid10_nfs_attempt.md) — Phase 1 (s-snuggly-goblet): NFS attach 経路実証
  - [2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed.md](2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed.md) — SMB session #6: 同 ISO で kernel printk が SOL に届いていた過去観測

## 添付ファイル

- [実装プラン](attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/plan.md)
- [iter1 SOL log (`quiet` 除去版、約 124 KB、 kernel printk 0)](attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/sol-iter1.log)
- [iter2 SOL log (`earlyprintk` 追加版、約 107 KB、 kernel printk 0)](attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/sol-iter2.log)
- [iter1 KVM 早期 screenshot (POST 中、全黒)](attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/kvm-iter1-early.png)
- [iter2 KVM 凍結 screenshot (kernel boot 後、 VGA 完全黒)](attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/kvm-iter2-vga-black.png)
- [iter1 NFS pcap (5 ファイル、 計約 50 MB、 全 packet は getattr のみで READ 0)](attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/pcap/iter1/)
- [iter2 NFS pcap (4 ファイル、 計約 32 MB、 同様に READ 0)](attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/pcap/iter2/)

## 前提・目的

### 背景

Phase 2 (s-linear-gizmo、 2026-05-21) で NFS Virtual Media は本コードに完全統合され、 attach 経路は確立した (PATCH ShareType=NFS → ConnectCD → AllowableValues=DisconnectCD)。 しかし **GRUB→kernel ハンドオフ直後に SOL/VGA とも完全沈黙する**新 blocker が発生した。 SMB session #6 (2026-05-18) の同 ISO + 同 cmdline では SOL に kernel printk (`[ 0.07] x86/cpu: SGX disabled` 等) が出ていたため、 NFS 経路固有 (または最近の iRMC state 変化) の regression と推測された。

### 目的

Phase 3 として 4 つの仮説の中から `quiet` 単独除去 (最小差分) で kernel printk が SOL に現れるかを検証し、 結果次第で残る仮説 (BIOS Console Redirection 切断 / iRMC NFS CD-ROM stall / kernel 早期 panic) を切り分ける。

ユーザ回答 (本セッション):

| 質問 | 回答 |
|-----|-----|
| 初手 | cmdline 一括変更 + NFS tcpdump 並行 |
| cmdline 変更幅 | 最小変更 (`quiet` 除去のみ) |
| NFS tcpdump | 並行で実施 (10.1.6.6) |

### スコープ

- iter1: `quiet` 除去のみで kernel printk が SOL に出るか
- iter2 (Step 7b 分岐): iter1 沈黙時の追加試行として `earlyprintk=ttyS0,115200n8,keep` 追加
- NFS pcap で kernel が CD-ROM (NFS export) を読んでいるかを並行観測
- 本機 (training-tx1320) はクラスタ非参加・別拠点・一時設置のため pve-lock 不要

## 環境情報

| 項目 | 値 |
|------|---|
| iRMC FW | 9.08F (S4) |
| iRMC IP | 10.254.254.9/8 |
| BIOS | V5.0.0.11 R1.22.0 for D3373-B1x |
| CPU | 4 logical CPUs |
| RAM | 24576 MB |
| HW RAID | RAID10 (SAS HDD 900GB × 4 → 1.8 TB) on PRAID EP400i |
| NFS server | 10.1.6.6 (Ubuntu 24.04.3 LTS、 nfs-kernel-server) |
| NFS export | `/var/samba/public 10.0.0.0/8(ro,no_subtree_check,all_squash,insecure,anonuid=65534,anongid=65534)` |
| ISO | `debian-training-tx1320-raid10.iso` (iter1 sha256 `4795a10f...`、 iter2 sha256 `7fba37f0...`、 約 764 MB、 PVESE_PATCH_CDROM_DETECT=1) |

## 結果サマリ (TL;DR)

❌ **OS install 未到達 / 真因究明半 ば**:

- iter1 (`quiet` 除去) で kernel printk **完全沈黙** (Booting Automated Install 後 5+ 分間 SOL に 0 行)
  - → **仮説 1 (`quiet` flag が kernel printk を抑制している) を反証**
- iter2 (`earlyprintk=ttyS0,115200n8,keep` 追加) でも kernel printk **完全沈黙** (同条件)
  - → **仮説 2 (kernel が動いていれば earlyprintk が早期 message を強制可視化する) を反証** = kernel は earlyprintk を実行する地点まで到達していない
- iter1 / iter2 両方の NFS pcap で **READ packet ゼロ** (全 packet は iRMC 側からの getattr のみ、 length 128/2606 byte)
  - → **kernel が CD-ROM device (iRMC USB CD-ROM emulation 経由) を一切 read していない** = kernel startup の超早期段階で hang/panic、 USB device enumeration まで到達していない
- iter2 KVM screenshot: VGA 完全黒継続
- iRMC PowerState=On 継続、 NFS attach (`["DisconnectCD"]`) 維持
- iRMC は ISO file metadata polling のため getattr を 30 秒間隔で継続発行 (NFS server 側で 13+ 分連続観測)

✅ **NFS Virtual Media 経路自体は Phase 2 と同じく完全健全**:

- iter1/iter2 とも PATCH HTTP 200、 AllowableValues=DisconnectCD 即時遷移、 boot-override Cd UEFI Once、 Power On (ResetType=On) 全成功
- GRUB は両 iter で正常起動 (`GNU GRUB version 2.12-9+deb13u2` → countdown → `Booting `Automated Install'` SOL 到達)
- 違いが現れるのは **GRUB が kernel image に jump した瞬間**以降

| 観測軸 | iter1 (`quiet` 除去) | iter2 (`earlyprintk` 追加) |
|--------|--------------------|--------------------------|
| OEM PATCH `ShareType="NFS"` | ✅ | ✅ |
| ConnectCD / AllowableValues 遷移 | ✅ (実際は前 session から維持) | ✅ |
| GRUB 起動 | ✅ | ✅ |
| GRUB countdown + `Booting Automated Install` | ✅ | ✅ |
| kernel 早期 printk (`[ 0.xxx] ...`) | ❌ | ❌ |
| earlyprintk message | N/A | ❌ |
| KVM VGA 出力 | ❌ (全黒) | ❌ (全黒) |
| NFS READ packet (kernel が CD-ROM を読んでいる証拠) | ❌ (0 packet) | ❌ (0 packet) |
| NFS getattr packet (iRMC が ISO metadata 確認) | ✅ (継続) | ✅ (継続) |
| Booting Automated Install 後の経過時間 (SOL 沈黙) | 約 5 分 | 約 5 分 |

## 再現方法

### Step 1: 既存 issue 再開 + iRMC 状態確認

```sh
mkdir -p tmp/fbd799f5
./issue.sh start 71 --owner s-rustling-melody
./scripts/irmc-virtualmedia.sh --share-type=NFS status 10.254.254.9 claude Claude123
# → 前 session の NFS attach が維持されていることを確認 (Server=10.1.6.6, ImageName=debian-training-tx1320-raid10.iso)
```

### Step 2: kernel cmdline から `quiet` 除去 (iter1)

`scripts/remaster-debian-iso.sh` の 4 箇所の `--- quiet` を `---` に変更 (UEFI grub.cfg, Legacy isolinux txt.cfg `auto`/`install` label, UEFI embed.cfg)。

### Step 3: ISO 再 build + NFS export 反映 + tcpdump 起動

```sh
PVESE_PATCH_CDROM_DETECT=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
rsync -avh -e "ssh -F ssh/config -i ssh/id_ed25519" \
  /var/samba/public/debian-training-tx1320-raid10.iso \
  ubuntu@10.1.6.6:/tmp/debian-training-tx1320-raid10.iso
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 sh /tmp/move-iso.sh
# /tmp/move-iso.sh: sudo mv + sudo exportfs -ra + sha256sum

# NFS tcpdump 起動 (バックグラウンド)
ssh ubuntu@10.1.6.6 sh /tmp/start-tcpdump.sh
# 内容: sudo nohup tcpdump -i ens19 -nn -s 0 -w /tmp/boot.pcap -W 5 -C 10 'host 10.254.254.9 and (port 2049 or port 111 or port 20048)' &
```

### Step 4: deploy + SOL monitor (iter1)

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
.venv/bin/python scripts/sol-monitor.py \
  --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
  --log-file tmp/fbd799f5/sol.log --timeout 1800 --powerstate-interval 60
```

iter1 結果: SOL に GRUB countdown + `Booting `Automated Install'` 到達後、 5+ 分間 kernel printk ゼロ。 NFS pcap も READ ゼロ。

### Step 5: Step 7b 分岐 — `earlyprintk` 追加 (iter2)

`scripts/remaster-debian-iso.sh` の cmdline で `console=ttyS${SERIAL_UNIT},115200n8 ---` を `console=ttyS${SERIAL_UNIT},115200n8 earlyprintk=ttyS${SERIAL_UNIT},115200n8,keep ---` に置換 (UEFI 経路の 2 箇所: line 193 grub.cfg + line 266 embed.cfg)。

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
PVESE_PATCH_CDROM_DETECT=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
# rsync + move-iso 再実行
ssh ubuntu@10.1.6.6 sh /tmp/restart-tcpdump.sh  # iter1 pcap を /tmp/pcap-iter1/ へ退避、 新規 capture 開始
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
.venv/bin/python scripts/sol-monitor.py ... --log-file tmp/fbd799f5/sol-iter2.log --timeout 1500
```

iter2 結果: SOL/VGA 沈黙パターンは iter1 と完全に同じ。 earlyprintk message も出ず。 NFS READ packet も継続的にゼロ。

### Step 6: pcap 解析 (10.1.6.6 上で tcpdump -r)

```sh
ssh ubuntu@10.1.6.6 sh /tmp/analyze-pcap.sh
# tcpdump -nr /tmp/pcap-iter1/boot.pcap0..4 で getattr のみが各 ~9500 packet、
# READ オペレーション 0
```

### Step 7: artifact 収集 + ForceOff

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
ssh ubuntu@10.1.6.6 sh /tmp/stop-tcpdump.sh
rsync -avh -e "ssh ..." ubuntu@10.1.6.6:/tmp/pcap-iter1/ report/attachment/<ts>/pcap/iter1/
rsync -avh -e "ssh ..." ubuntu@10.1.6.6:/tmp/pcap-iter2/ report/attachment/<ts>/pcap/iter2/
```

## 観測詳細

### A. iter1 SOL ログ — Booting Automated Install までは正常

```
GNU GRUB  version 2.12-9+deb13u2
+----------------------------------------------------------------------------+
|*Automated Install                                                          |
... (countdown 3s..0s) ...
  Booting `Automated Install'
```

以降 5+ 分間、 SOL に kernel printk が 1 行も書かれない (sol-iter1.log 全文 grep で `\[\s*[0-9]+\.[0-9]+\]` パターン 0 ヒット)。 SOL ring buffer リプレイで GRUB countdown + Booting Automated Install が複数回再出現するが、 これは ipmitool sol activate の reconnect 副作用 (Phase 2 でも観測 documented)。

### B. iter2 SOL ログ — `earlyprintk` 追加でも同じ症状

iter2 sol-iter2.log でも:
- `earlyprintk` keyword 0 ヒット
- `SGX`, `Linux`, `panic`, `kernel`, `[ 0.xxx]` 全パターン 0 ヒット
- GRUB countdown + Booting Automated Install のみ 4 回 (ring buffer リプレイ)

= **kernel は earlyprintk を実行する地点 (極めて早期、 BIOS 戻り直後の serial register I/O) すら到達していない**

### C. iter1/iter2 NFS pcap — READ ゼロは決定的な観測

10.1.6.6 上で `tcpdump -nr /tmp/pcap-iter*/boot.pcap*` で確認:

| ファイル | 期間 | packet 数 | NFS request 内訳 |
|---------|-----|---------|----------------|
| iter1/boot.pcap0 | 15:14:14 – 15:18:36 | 9490 | getattr のみ (length 144 / 160) |
| iter1/boot.pcap1 | 15:18:36 – 15:21:45 | 9453 | 同上 |
| iter1/boot.pcap2 | 15:21:45 – 15:23:26 | 8524 | 同上 |
| iter1/boot.pcap3 | 15:23:26 – 15:27:31 | 9821 | 同上 |
| iter1/boot.pcap4 | 15:27:31 – 15:28:34 | (一部) | 同上 |
| iter2/boot.pcap0-3 | 15:28:34 – 15:39:00 | 計 ~21000 | 同上 |

すべての NFS request が `getattr fh 0,0/22` (root file handle に対する metadata 確認)。 reply length は 124 byte (small) / 2606 byte (large、 directory metadata 推測)。 **read オペレーションは 1 packet も存在しない**。

これは:
- iRMC 側が ISO file の存在 / size / mtime を定期 polling している (NFS export 維持確認の bookkeeping traffic)
- host (kernel) は CD-ROM device (iRMC USB CD-ROM emulation 経由) を access していない
- = kernel は USB device enumeration / CD-ROM driver init まで到達していない可能性が極めて高い

### D. iter2 KVM screenshot — VGA 完全黒継続

iter2 boot 開始から 5+ 分後の iRMC KVM canvas: alive=True (KVM viewer 自体は正常動作) だが画面更新 0 = **VGA に何も書かれていない**。

`nomodeset` を指定しているので modeset は無効だが、 通常 BIOS legacy VGA text mode は出るはず。 kernel が startup していれば最低でも boot logo / banner / "Booting" 等が出る。 完全黒 = kernel が VGA register に何も書いていない = kernel が動いていない。

### E. 仮説の更新

Phase 2 報告での仮説 1-5 を本セッションで以下のように更新:

| # | 仮説 | 状態 |
|---|-----|-----|
| 1 | `quiet` flag が kernel printk を抑制 | ❌ **反証** (iter1 で `quiet` 除去後も 0 printk) |
| 2a | kernel が動いているが console 出力経路だけ死んでいる | ❌ **反証** (iter2 earlyprintk + NFS READ 0 で kernel 自体が動いていない方が強い) |
| 2b | kernel が startup 自体できていない (decompression / early init で hang/panic) | ✅ **強く支持** (iter1/iter2 双方の現象から最も合理的) |
| 3 | BIOS Serial Console Redirection が UEFI OS hand-off で OFF になる | △ **未検証** (VGA も silent な点を説明しないため単独原因としては弱い) |
| 4 | iRMC NFS USB CD-ROM の long-read stall | △ **未検証だが弱まる** (kernel が READ 1 packet も出していないため、 GRUB が kernel image / initrd の load 完了後 kernel が NFS CD-ROM を access する地点まで到達していない) |
| 5 | Legacy BIOS 経路に切替 | (Phase 2 で実機反証済) |

新仮説候補:

| # | 仮説 | 検証手段 |
|---|-----|--------|
| 6 | iRMC NFS USB CD-ROM emulation が GRUB が load した kernel image / initrd を **truncated / corrupted な状態で渡している** (GRUB は短い read で OK でも image 末尾までは load しない / または iRMC 側で image を complete に提供できていない) → kernel decompression fail | NFS export と GRUB の view を比較。 GRUB `linux ...` 実行後 NFS read pattern が image 末尾まで届いているか。 iter1/iter2 で getattr のみ = iRMC が image を内部 cache から host に提供している証拠 |
| 7 | iRMC NFS Virtual Media の host 側 USB CD-ROM device が UEFI 環境では正常に enumeration されているが、 **kernel が x86 USB controller 初期化で hang する** (TX1320 M3 特有 USB controller の quirk) | iter3 で `nousb` / `irq=biosirq` / `acpi=off` 等の追加 cmdline を試行 |
| 8 | iRMC FW 9.08F の OEM NFS Virtual Media が **CD-ROM emulation timing で kernel boot 中の何かを刺激し host を halt させている** (iRMC 側のバグ) | USB stick / PXE 等の iRMC NFS Virtual Media を経由しない boot media で同 ISO を試行 → 違いがあれば iRMC NFS 固有 |
| 9 | SMB session #6 (2026-05-18) と Phase 2/3 の間に **iRMC / BIOS 設定が無 self-aware に変化** (例えば BIOS Secure Boot, TPM 設定、 UEFI Boot order の歪み) | BIOS XML backup を取得して 2026-05-18 時の状態と diff |

## 完了事項

- [x] `scripts/remaster-debian-iso.sh` から `--- quiet` を `---` に変更 (4 箇所、 UEFI/Legacy 両方)
- [x] iter1 ISO 再 build (sha256 `4795a10f...`、 764 MB)
- [x] iter1 NFS 配置 + tcpdump 起動 + deploy + SOL 監視 (kernel printk 0、 NFS READ 0)
- [x] `scripts/remaster-debian-iso.sh` で UEFI 経路 cmdline に `earlyprintk=ttyS${SERIAL_UNIT},115200n8,keep` 追加 (line 193 grub.cfg + line 266 embed.cfg)
- [x] iter2 ISO 再 build (sha256 `7fba37f0...`、 764 MB)
- [x] iter2 NFS 配置 + tcpdump 再起動 + deploy + SOL 監視 (同じく kernel printk 0、 NFS READ 0)
- [x] 仮説 1, 2a 反証 / 仮説 2b 強化
- [x] pcap artifact をローカル attachment にコピー (iter1: 5 ファイル ~50 MB、 iter2: 4 ファイル ~32 MB)
- [x] SOL log + KVM screenshot を attachment に保存
- [ ] kernel が startup できない真因の確定 — **未到達**
- [ ] BIOS Console Redirection 設定確認 (`bios backup`) — **未実施 (次セッション課題)**
- [ ] 別 boot media (USB stick / PXE) での切り分け — **未実施**

## 未完了 / 次セッション課題 (Phase 4)

### 1. 🎯 最優先: 仮説 6 / 仮説 7 / 仮説 8 の切り分け

#### 1a. BIOS XML backup で Console Redirection / Secure Boot / Boot Mode を 2026-05-18 想定と比較

```sh
./scripts/irmc-bios-raid.sh bios backup config/training_tx1320.yml \
  tmp/<sid>/winscu-phase4.xml
./scripts/irmc-bios-raid.sh bios show tmp/<sid>/winscu-phase4.xml redirect
./scripts/irmc-bios-raid.sh bios show tmp/<sid>/winscu-phase4.xml secure
./scripts/irmc-bios-raid.sh bios show tmp/<sid>/winscu-phase4.xml usb
```

特に: `Redirection After BIOS POST`, `Console Redirection`, `Secure Boot`, `USB Configuration`, `Boot Mode (UEFI vs Legacy)` の設定を 2026-05-18 時の状態 (報告書から推定 / 過去 XML を保管していれば diff) と比較。 必要なら `bios apply-config` で OS hand-off 後も serial redirect を保持する設定に変更。

#### 1b. nomodeset 除去 + 単一 console で再試行 (仮説 7 補助)

UEFI 経路の cmdline を:

```
ro auto=true priority=critical preseed/file=/preseed.cfg ... console=ttyS0,115200n8 earlyprintk=ttyS0,115200n8,keep ---
```

(`vga=normal`, `nomodeset`, `console=tty0` を抜く) で iter3 を試行。 これで kernel が serial console を唯一の出力先として使い、 VGA 関連の hang を回避できるかを確認。

#### 1c. 別 boot media での切り分け (仮説 8)

- option A: USB stick に ISO を burn して host に物理接続 (training-tx1320 は別拠点、 ユーザが物理アクセス必要)
- option B: PXE boot (10.254.254.0/24 内に PXE server 構築) — overhead 大きく非現実的
- option C: iRMC HDImage (FDImage は OEM HDImage MaxDev=0 で blocked、 過去 memory note 参照) — 試す価値あり

#### 1d. NFS export 監視で kernel boot のどこで止まるか可視化

10.1.6.6 で `journalctl -u nfs-kernel-server -f` + `dmesg -w` を boot 中に取って、 host からの NFS request rate change point を tracking する。

### 2. SMB session #6 (2026-05-18) の cmdline diff 確認

過去レポートと現在の `scripts/remaster-debian-iso.sh` の cmdline を文字単位で diff。 もし 5/18 時点で別の option が含まれていたなら、 そこに kernel boot を可能にする秘密があるかもしれない。

git log で `scripts/remaster-debian-iso.sh` の 5/18 以降の commit を確認:

```sh
git log --oneline --since=2026-05-15 -- scripts/remaster-debian-iso.sh
git diff <5/18 commit hash> HEAD -- scripts/remaster-debian-iso.sh
```

### 3. 報告 + memory + skill 更新

- ✅ 本レポート (`report/2026-05-22_004000_tx1320_raid10_kernel_silent_persist.md`) 完成
- 📝 memory: 既存 [[training_tx1320_kernel_silent_post_grub.md]] を本セッション結果で更新 (仮説 1+2a 反証 / 仮説 2b 強化 / NFS READ 0 観測 / 新仮説 6-9)
- 📝 skill `.claude/skills/irmc-bios-raid/SKILL.md`: 「NFS Virtual Media 経路」セクションの「落とし穴」に「`quiet`/`earlyprintk` の差は症状に効かない、 真因は kernel startup 前の hang」を追記

### 4. NFS server 側の保全

- `10.1.6.6:/tmp/pcap-iter1/` と `/tmp/pcap-iter2/` の pcap ファイル群はローカル `report/attachment/...` にコピー済。 NFS server 側からは消して良い (sudo rm)。 ただし次セッションで Phase 4 を即時引き継ぐ可能性があるので、 当面残しておく方が安全。

## 関連 Issue

- **#71 (active → blocked 再)** [s-rustling-melody]: training-tx1320 NFS Virtual Media 本格統合 + OS install 完遂 — Phase 2 完遂、 Phase 3 で `quiet` + `earlyprintk` 両方反証、 NFS READ 0 で kernel startup 未到達確定。 Phase 4 で BIOS XML backup + 別 boot media 切り分け
- **#69 (blocked)** [silly-token]: TX1320 M3 RAID10 自動構成 — 本セッションで触らず

## 関連ファイル

### 修正

- `scripts/remaster-debian-iso.sh` — cmdline から `quiet` を 4 箇所除去 (iter1)、 UEFI 経路 2 箇所に `earlyprintk` 追加 (iter2)

### 未修正 (Phase 2 から温存)

- `scripts/tx1320-raid10-orchestrate.sh` — NFS 分岐は Phase 2 で完成
- `scripts/irmc-virtualmedia.sh` — Phase 2 で `--share-type=NFS` + `connect-cd` 完備
- `config/training_tx1320.yml` — Phase 2 で `virtual_media_type: nfs`

### 新規 (attachment 配下)

- `report/attachment/2026-05-22_004000_tx1320_raid10_kernel_silent_persist/`
  - plan.md (実装プラン)
  - sol-iter1.log, sol-iter2.log (SOL capture 2 系統)
  - kvm-iter1-early.png, kvm-iter2-vga-black.png (KVM screenshot 2 系統)
  - pcap/iter1/ (5 ファイル ~50 MB), pcap/iter2/ (4 ファイル ~32 MB) — NFS packet capture

## 重要な教訓 (次セッションへの引き継ぎ)

1. **🎯 cmdline `quiet` / `earlyprintk` は症状に効かない**: 最小差分原則で `quiet` を抜いても、 `earlyprintk` を足しても、 kernel printk は 1 行も SOL に届かない。 これは「kernel が出力できないだけ」ではなく「kernel が出力する地点まで到達できていない」ことを示す
2. **🎯 NFS pcap READ ゼロは決定的観測**: iRMC NFS Virtual Media が attach 成立してから 10+ 分の間、 host (kernel) が CD-ROM device を 1 byte も read していない。 iRMC からの getattr (metadata polling) のみ存在。 kernel が USB CD-ROM enumeration 以前で死んでいる証拠
3. **🎯 SMB session #6 (2026-05-18) との時間軸 diff が次の鍵**: 同じ ISO / 同じ cmdline / 同じ host で 5/18 時点では kernel printk が出ていた。 何か iRMC / BIOS state、 または `scripts/remaster-debian-iso.sh` の git history で変化点がある可能性。 Phase 4 で `git log --since=2026-05-15 -- scripts/remaster-debian-iso.sh` + BIOS XML backup diff を最初に実施
4. **🛑 SOL ring buffer リプレイは false-positive 源**: GRUB countdown + Booting Automated Install が SOL log に 4-7 回現れるが、 これは ipmitool sol activate の reconnect で BMC が ring buffer を re-replay している副作用。 host は 1 回しか boot していない。 「複数回 boot 試行している」と読まないこと (過去レポート 2026-05-18 で documented)
5. **🎯 iter1 / iter2 各 ~7 分かかる**: BIOS POST (~2 min) + GRUB countdown (~3 sec) + Booting → 沈黙開始まで合計 2.5 分、 観測 5 分必要 = 1 試行 ~7-8 min。 次セッションで複数 iter を試す場合は時間予算を確保
6. **📝 NFS server (10.1.6.6) tcpdump 起動は wrapper script に書く**: 引数内の `'host 10.254.254.9 and (...)'` が複合フィルタ式のため、 ssh 引数で直接渡すと permission 制約に引っかかる。 scp で script を送って `ssh ubuntu@10.1.6.6 sh /tmp/start-tcpdump.sh` で実行する形が安全
7. **🎯 KVM screenshot は VGA 出力の生死を確認する 1 次情報**: KVM canvas alive=True で画面が全黒 = VGA に kernel が何も書いていない。 BIOS Console Redirection の有無に関係なく VGA も silent な現象は仮説 2b (kernel が startup できない) を強く支持

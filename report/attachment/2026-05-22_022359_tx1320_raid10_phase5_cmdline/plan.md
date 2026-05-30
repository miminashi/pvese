# TX1320 M3 NFS install Phase 5 — cmdline iter4/iter5 + GRUB sanity + memory/skill 更新

## Context

Phase 4 (`report/2026-05-22_012828_tx1320_raid10_phase4_kvm_locator.md`) で以下が確定した:

- VGA は健全 (BIOS POST + `Booting Automated Install` まで描画)
- kernel が GRUB から jump した直後で完全停止 (kernel printk 0、 画面更新ゼロ、 NFS READ も 0)
- BIOS XML に `Console Redirection` エントリ無し (D-1 仮説は本機では検証不可)

Phase 5 として **kernel 早期 hang の真因を切り分ける**ため、 cmdline 細工 2 通り (iter4 + iter5) と GRUB image sanity 検証を実施する。 ユーザ指示により範囲を絞った:

- cmdline iter: **iter4 + iter5 のみ** (iter6-iter8 は次セッション)
- **GRUB image sanity 検証は並行実施**
- **memory + skill 更新は今回スコープ**、 orchestrate.sh 統合は次セッション

判定基準は明確: iter4 / iter5 のいずれかで SOL に kernel printk 1 行でも出れば該当仮説が確定、 両方で 0 printk なら仮説 7/9 棄却で次セッションは仮説 6/8/10 (image 完全性 / iRMC NFS USB-CD 経路 / 別 boot media) に絞る。

## スコープ

### 実施する
1. iter4: cmdline から `console=tty0` を除去 → ttyS 単独 (仮説 9: multi-console hand-off race)
2. iter5: Phase 4 と同じ cmdline + `nousb` 追加 (仮説 7: USB controller quirk)
3. 各 iter の build 直後 + NFS publish 直後で GRUB image sanity 検証 (vmlinuz sha256 一致 + ISO 内 vmlinuz size 抽出比較)
4. memory 更新: `training_tx1320_kernel_silent_post_grub.md` に Phase 5 結果追記、 「KVM screenshot は locator 必須」 注意の確認
5. skill 更新: `.claude/skills/irmc-bios-raid/SKILL.md` + `.claude/skills/os-setup/SKILL.md` に KVM screenshot locator 必須を明示
6. 報告書 `report/<新ts>_tx1320_raid10_phase5_*.md`

### 実施しない (次セッション課題)
- iter6 (`acpi=off noapic`) / iter7 (`pci=noacpi nolapic`) / iter8 (`earlyprintk=efi,keep`)
- orchestrate.sh への locator screenshot 統合 hook
- iRMC HDImage / 物理 USB stick / PXE による別 boot media 検証
- SMB session #6 再現 (iRMC FW reflash 必要)

## 実装計画

### Step 0: セッション準備

- `mkdir -p tmp/<sid>`
- `./issue.sh start 71 --owner <sid>` (Phase 4 で blocked 化、 Phase 5 で再 active)
- iRMC NFS 状態確認: `./scripts/irmc-virtualmedia.sh --share-type=NFS status 10.254.254.9 claude Claude123` (RemoteMountEnabled=true 維持確認)
- 期待 ImageName: `debian-training-tx1320-raid10.iso` (固定名で iter4/iter5 共通)

### Step 1: iter4 — cmdline から `console=tty0` を除去

#### 1a. cmdline 修正 (sed in-place、 build 後に git checkout で戻す)

修正対象 (`scripts/remaster-debian-iso.sh`):
- L193 (BIOS GRUB `menuentry`)
- L203 (SYSLINUX `append`)
- L266 (EFI embed.cfg `menuentry`)

3 箇所すべて `console=tty0 console=ttyS${SERIAL_UNIT},115200n8` → `console=ttyS${SERIAL_UNIT},115200n8` に置換する sed コマンドを `tmp/<sid>/iter4-patch.sh` に書く。

#### 1b. ISO build + GRUB sanity (検証)

```sh
./oplog.sh ./scripts/remaster-debian-iso.sh \
  --input /var/samba/public/debian-13.3.0-amd64-netinst.iso \
  --output iso/debian-training-tx1320-raid10.iso \
  --preseed tmp/<sid>/preseed-iter4.cfg \
  --serial-unit 0
```

build 直後に以下を `tmp/<sid>/iter4-sanity.txt` に記録:

- local ISO sha256
- local ISO 内の `/install.amd/vmlinuz` 抽出 → sha256 + size
- local ISO 内の `/boot/grub/grub.cfg` 内 `linux ` 行 grep (cmdline 実装確認)

#### 1c. NFS export に publish + sanity 検証

- `scp iso/debian-training-tx1320-raid10.iso ubuntu@10.1.6.6:/var/samba/public/` (sudo 不要、 既存 path で上書き)
- ssh 10.1.6.6 で remote ISO sha256 計算 → local と一致確認 (truncation 検証)
- ssh 10.1.6.6 で remote ISO 内 `/install.amd/vmlinuz` の size 確認 (任意、 1c の依拠強化)

#### 1d. iRMC ConnectCD 再 attach

ImageName は変わらないため CDImage state は維持されるが、 iRMC USB CD-ROM emulation の cache が古い ISO を保持している可能性。 一度 `DisconnectCD` → `ConnectCD` で reload:

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS unmount 10.254.254.9 claude Claude123
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS mount 10.254.254.9 claude Claude123
```

mount 完了 (AllowableValues に "DisconnectCD" 出現) を待機。

#### 1e. boot-override Cd UEFI + SOL bg + Power On

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' BMC_PATCH_REQUIRES_ETAG=1 \
  ./oplog.sh ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI

sh tmp/<sid>/sol-bg.sh &  # run_in_background=true
sleep 3
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' POWER_ON_RESET_TYPE=On \
  ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
```

#### 1f. KVM locator screenshot 時系列

Phase 4 と同じ timing で `irmc-kvm-interact.py shell` を `tmp/<sid>/kvm-iter4-shell.sh` に書いて実行:

- t030, t060, t120 (BIOS POST 確認)
- t180 (Booting Automated Install / kernel jump 後)
- t300 (5 分後 — 凍結 vs 進行判定)

#### 1g. 判定 + power off

判定 grep:
- SOL log: `grep -cE '^\[\s*[0-9]+\.[0-9]+\]'` → **1 以上なら kernel boot 成功** = 仮説 9 確定 + Phase 5 早期終了で報告へ
- SOL log: `grep -ci 'kernel\|Linux version'` → 補助
- KVM t300 vs t180 の sha256 比較 → 不一致なら画面更新 = boot 進行
- Power off: `./scripts/bmc-power.sh forceoff`

#### 1h. cmdline 戻し

`git checkout -- scripts/remaster-debian-iso.sh` で iter4 patch を revert (commit せず一時変更)。

### Step 2: iter5 — `nousb` 追加

Step 1 と同じ流れで以下のみ変更:

- 修正対象は L193, L203, L266 の 3 箇所
- L193 / L266 (BIOS GRUB / EFI): `earlyprintk=ttyS${SERIAL_UNIT},115200n8,keep ---` → `earlyprintk=ttyS${SERIAL_UNIT},115200n8,keep nousb ---`
- L203 (SYSLINUX、 earlyprintk なし): `console=ttyS${SERIAL_UNIT},115200n8 initrd=/install.amd/initrd.gz ---` → `console=ttyS${SERIAL_UNIT},115200n8 nousb initrd=/install.amd/initrd.gz ---`

判定:
- iter5 で kernel printk 1 行以上 → 仮説 7 確定 (USB quirk)
- iter4 + iter5 ともに 0 printk → 仮説 7/9 棄却で次セッション (iter6/iter7/iter8 + 仮説 6/8/10) に申し送り

### Step 3: memory 更新

#### 3a. `training_tx1320_kernel_silent_post_grub.md` 更新

セクション追加: "Phase 5 (s-tidy-hummingbird) 結果":
- iter4 結果 (SOL printk count, KVM size 遷移)
- iter5 結果 (同)
- 仮説マトリクスへの impact
- GRUB sanity 検証結果 (local vs remote sha256 一致 / 不一致)

#### 3b. (新規確認) iRMC NFS Virtual Media 確認パターン

既存 memory `training_tx1320_nfs_solved.md` がある場合は ImageName 維持 + DisconnectCD → ConnectCD reload の必要性を追記。

#### 3c. (新規確認) KVM screenshot locator 必須

`MEMORY.md` 既存行 `🎯 KVM screenshot は必ず scripts/irmc-kvm-interact.py --capture-mode=locator を使う` の項目を再確認し、 Phase 5 でも適用したことを示す。 必要なら本文補強。

### Step 4: skill 更新

#### 4a. `.claude/skills/irmc-bios-raid/SKILL.md`

L129-142 付近の `bios screenshot` subcommand 説明 / KVM 操作セクションに、 「KVM screenshot は `irmc-kvm-interact.py --capture-mode=locator` (default) を必ず使う、 legacy `irmc-kvm-screenshot.py` は WebGL 黒画 artifact のため使ってはいけない」 を太字注意で追記。

#### 4b. `.claude/skills/os-setup/SKILL.md`

L48 付近の Supermicro `bmc-kvm-screenshot.py` 言及部分に、 「TX1320 (iRMC S4) は HTML5 KVM のため `scripts/irmc-kvm-interact.py screenshot --capture-mode=locator` を使う、 legacy canvas mode は使わない」 を追記。

### Step 5: 報告書作成

`report/<新ts>_tx1320_raid10_phase5_cmdline.md` を作成:

- Phase 5 判定 (iter4/iter5 結果 + 仮説マトリクス更新)
- 添付: kvm-iter4-t*.png, kvm-iter5-t*.png, sol-iter4.log, sol-iter5.log, iter4-sanity.txt, iter5-sanity.txt, iter4-patch.sh, iter5-patch.sh, plan.md
- 関連 Issue (#71) 更新
- 重要な教訓 + 次セッション課題 (iter6/iter7/iter8 + 仮説 6/8/10)

attachment 配下に artifact copy + plan.md は本 plan を copy。

## 修正対象ファイル

### 一時変更 (build 後に revert、 commit しない)
- `scripts/remaster-debian-iso.sh` L193, L203, L266 — cmdline 修正 (iter4 と iter5 で異なる patch)

### 恒久変更 (commit する)
- `.claude/skills/irmc-bios-raid/SKILL.md` — KVM screenshot locator 必須注意追記
- `.claude/skills/os-setup/SKILL.md` — TX1320 HTML5 KVM の locator 必須追記
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320_kernel_silent_post_grub.md` — Phase 5 結果追記 (commit 対象外、 memory)
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/MEMORY.md` — index 行調整 (commit 対象外)

### 新規 (commit する)
- `report/<新ts>_tx1320_raid10_phase5_cmdline.md` — 報告書
- `report/attachment/<新ts>_*/` — artifact

## 参照する既存ツール (再利用)

- `scripts/remaster-debian-iso.sh` — ISO build (cmdline 変更後に再 build)
- `scripts/irmc-virtualmedia.sh --share-type=NFS mount/unmount/status` — NFS Virtual Media 操作 (`scripts/irmc-virtualmedia.sh:53-57, 233-256`)
- `scripts/bmc-power.sh boot-override / on / forceoff` — 電源操作
- `scripts/irmc-kvm-interact.py shell --capture-mode=locator` — KVM screenshot 時系列 (`scripts/irmc-kvm-interact.py:184, 411-430, 539-590`)
- `scripts/sol-monitor.py` — SOL bg capture
- `./oplog.sh` — 状態変更操作のログ記録
- `./issue.sh start/done` — Issue 状態管理

新規 utility script は作成しない (Phase 5 は実験段階、 恒久化は次セッション orchestrate.sh 統合で対応)。

## 検証方法

### iter4 / iter5 判定
1. SOL log の kernel printk grep (`grep -cE '^\[\s*[0-9]+\.[0-9]+\]'`) — **1 以上 = 仮説確定**
2. KVM screenshot t180 vs t300 の sha256 比較 — 不一致なら kernel が画面に書いた = boot 進行
3. NFS pcap (optional、 ユーザ希望時のみ playground 10.1.6.6 上で tcpdump) — READ packet 数

### GRUB sanity
- local build ISO の sha256 == NFS export ISO の sha256 (truncation 検証)
- local ISO 内 vmlinuz の size と独立に build した時の expected size 比較 (任意)

### memory / skill 更新
- skill 更新後に `grep -l 'irmc-kvm-screenshot' .claude/skills/` で legacy 言及が残っていないか確認
- memory 更新後に `grep -l 'Phase 5' /home/ubuntu/.claude/projects/.../memory/` で参照可能か確認

### 全体報告書
- `report/<ts>_tx1320_raid10_phase5_*.md` 作成、 添付 artifact copy 完了確認

## リスク・注意

1. **iRMC USB CD-ROM emulation の cache**: 同名 ISO 上書きで内容が反映されない可能性。 各 iter 前に `unmount` → `mount` で reload する必要あり。 上の Step 1d で対応済
2. **cmdline 修正の commit 防止**: Step 1h / iter5 後で `git checkout -- scripts/remaster-debian-iso.sh` を必ず実行 (実験段階の cmdline 変更は commit しない)
3. **iRMC FW 9.08F SMB worker 障害は再発リスク**: 本セッションは NFS のみ使用、 SMB 経路は触らない。 万一 iRMC が応答しなくなったら Phase 4 ✓ 教訓に従い対応保留
4. **boot-override の副作用**: `irmc-bios.py backup` は本セッションでは使用しない (Phase 4 でリセット観測済み、 確実な手順のため backup 経路回避)
5. **timing**: 1 iter ~20 分 × 2 + GRUB sanity ~5 分 + memory/skill ~15 分 + 報告書 ~15 分 = 約 75 分
6. **SOL ring buffer リプレイ**: Phase 4 で 48 回 `Booting Automated Install` が出た false-positive と同様、 grep 結果を「複数回 boot」と誤読しないこと

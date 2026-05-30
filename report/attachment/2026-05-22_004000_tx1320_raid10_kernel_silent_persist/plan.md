# TX1320 M3 RAID10 + Debian 13 NFS install (Phase 3) — kernel boot 沈黙の真因究明

## Context

前セッション `s-linear-gizmo` (2026-05-21、`report/2026-05-21_091931_tx1320_raid10_nfs_install.md`) で iRMC S4 FW 9.08F の NFS Virtual Media 統合は完遂したが、 **GRUB→kernel ハンドオフ直後に SOL/VGA とも完全沈黙する**という新 blocker が判明した:

- NFS attach (`PATCH ShareType=NFS` → `ConnectCD` → `AllowableValues=["DisconnectCD"]`) は成立
- GRUB は正常起動して "Booting `Automated Install'" まで出力
- 直後 KVM が "Booting `Automated Install'" 1 行で凍結、SOL ログは 0 行 (9+ 分経過)
- UEFI / Legacy 両モードで同症状 (UEFI EFI stub 固有でない)
- SMB session #6 (2026-05-18) の同 ISO + 同 cmdline では SOL に `[ 0.07] x86/cpu: SGX disabled` から kernel printk が出ていた → 本セッションは新規 regression

現在の kernel cmdline (`scripts/remaster-debian-iso.sh:193`):

```
vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS${SERIAL_UNIT},115200n8 --- quiet
```

仮説候補:
1. `--- quiet` の `quiet` flag で kernel printk が抑制され、何かしらの早期 hang を観測できていない (kernel は動いているが見えないだけ)
2. kernel が早期に panic / hang して output 自体が無い
3. BIOS Serial Console Redirection が UEFI hand-off 後に切断
4. iRMC NFS USB CD-ROM が GRUB の short read には応答するが kernel の長尺 access で stall

**最小差分原則**で `quiet` 除去のみを実施し、kernel printk が SOL に出れば仮説 1、出なければ NFS tcpdump で 2 / 3 / 4 を切り分ける。

## 方針

ユーザ回答 (本セッション):

| 質問 | 回答 |
|-----|-----|
| 初手 | cmdline 一括変更 + NFS tcpdump 並行 |
| cmdline 変更幅 | **最小変更: `quiet` 除去のみ** |
| NFS tcpdump | **並行で実施 (10.1.6.6)** |

→ `quiet` 除去だけの minimal patch + NFS tcpdump 並行取得で kernel printk / NFS packet 両方を観測。

## 実装手順

### Step 0: セッション準備

- session-id: tmp/<sid>/ を作成
- 既存 issue #71 (blocked) を再開: `./issue.sh start 71 --owner <session名>`
- iRMC 疎通確認: `./scripts/irmc-virtualmedia.sh --share-type=NFS status 10.254.254.9 claude Claude123` で前 session の NFS attach 状態を確認
- 必要なら ForceOff で電源 OFF (前 session 終了時 PowerState=On のまま放置されている可能性)

### Step 1: `scripts/remaster-debian-iso.sh` の cmdline から `quiet` 除去

修正対象は 2 箇所:

1. **UEFI GRUB menu entry** (`scripts/remaster-debian-iso.sh:193`):
   - 現状: `... console=ttyS${SERIAL_UNIT},115200n8 --- quiet`
   - 変更後: `... console=ttyS${SERIAL_UNIT},115200n8 ---`
2. **Legacy ISOLINUX `txt.cfg`** (`scripts/remaster-debian-iso.sh:203`):
   - 同様に末尾 `--- quiet` → `---`

`---` は kernel と installer の境界 separator なので残す。`quiet` のみ削除。

### Step 2: ISO 再 build (RAID10 + cdrom-detect patch + quiet 除去)

```sh
PVESE_PATCH_CDROM_DETECT=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
# → /var/samba/public/debian-training-tx1320-raid10.iso (新版)
# sha256 を記録、ローカル size 確認
```

build script 末尾の sanity check (TRAILER 2 + preseed.cfg 1 + cdrom-detect.postinst 1 + marker 2 + /dev/sr1 8) が pass することを確認。

### Step 3: ISO を 10.1.6.6 NFS server へ配置 + cache 無効化

```sh
rsync -avh --progress -e "ssh -F ssh/config -i ssh/id_ed25519" \
  /var/samba/public/debian-training-tx1320-raid10.iso \
  ubuntu@10.1.6.6:/tmp/debian-training-tx1320-raid10.iso
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
  "sudo mv /tmp/debian-training-tx1320-raid10.iso /var/samba/public/debian-training-tx1320-raid10.iso && sudo exportfs -ra"
# sha256 比較で整合確認
```

### Step 4: NFS tcpdump 起動 (バックグラウンド・並行観測)

10.1.6.6 上で boot 中の NFS packet を 5 分以上 capture:

```sh
# tmp/<sid>/start-tcpdump.sh をローカルに書く →  scp で送る → ssh で nohup 起動
scp -F ssh/config -i ssh/id_ed25519 tmp/<sid>/start-tcpdump.sh ubuntu@10.1.6.6:/tmp/start-tcpdump.sh
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 sh /tmp/start-tcpdump.sh
# /tmp/boot.pcap (回転 10 MB × 5、`-W 5 -C 10`) で書き出し
# 内容: sudo tcpdump -i ens19 -nn -s 0 -w /tmp/boot.pcap -W 5 -C 10 'host 10.254.254.9 and (port 2049 or port 111 or port 20048)'
```

検証: `nfsstat -s` の op count を boot 前後で比較。

### Step 5: deploy (NFS attach 維持なら PATCH skip 可だが orchestrate を素直に通す)

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
# → Phase 5a: NFS PATCH (HTTP 200) → ConnectCD (HTTP 204) → AllowableValues=DisconnectCD
# → Phase 5b: boot-override Cd UEFI (Continuous)
# → Phase 5c: ForceOff → sleep 8 → On (ResetType=On)
```

### Step 6: SOL monitor (10 分前後でまず観測)

```sh
.venv/bin/python scripts/sol-monitor.py \
  --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
  --log-file tmp/<sid>/sol.log --timeout 1800 --powerstate-interval 60
```

期待される観測パターン:

| パターン | 判定 | 次のアクション |
|---------|-----|--------------|
| SOL に `[ 0.0xxxxx]` から始まる kernel printk が出る | 仮説 1 確定 (quiet が原因) → 既存進行 | cdrom-detect / installer の従来知見で対処 |
| 依然完全沈黙 + tcpdump も静か (パケット無し) | kernel 早期 panic or BIOS Console Redirection 切断 | Step 7a (BIOS XML 確認) へ |
| 依然沈黙 + tcpdump に NFS read が継続している | kernel は動いているが console 出力経路が死んでいる | Step 7b (Console Redirection / earlyprintk) へ |
| tcpdump に NFS read が突然停止 | iRMC NFS CD-ROM stall | Step 7c (NFS export チューニング / SMB fallback 検討) へ |

### Step 7: 分岐対応 (Step 6 結果で選択)

#### Step 7a: BIOS Console Redirection 確認

```sh
./scripts/irmc-bios-raid.sh bios backup config/training_tx1320.yml
# → tmp/<sid>/winscu.xml に保存
grep -i 'redirect\|serial\|console' tmp/<sid>/winscu.xml
```

`Redirection After BIOS POST` 相当の設定が `Disabled` なら `bios apply-config` で Enabled 化。

#### Step 7b: `earlyprintk` 追加で再試行

`scripts/remaster-debian-iso.sh` で `console=ttyS${SERIAL_UNIT},115200n8` の直後に `earlyprintk=ttyS${SERIAL_UNIT},115200n8,keep` を追加 → Step 2 から再実行。

#### Step 7c: iRMC NFS access pattern 解析

pcap を Wireshark / `tshark -r /tmp/boot.pcap` で解析、kernel boot で発生する NFS COMPOUND OPS / file handle 一覧を確認。Hang 直前の last successful read offset を特定。

### Step 8: install 完遂 (Step 6 で kernel が動いたケース)

従来計画通り SOL log で順に観測:

1. GRUB → `Automated Install` 自動選択
2. Linux/initrd load → kernel printk → SGX, ACPI, CPU init
3. `Detecting hardware to find CD-ROM drives` → cdrom-detect 成功 (commit f96d47b 効果)
4. `Loading installer components from CD-ROM`
5. `Running /cdrom/setup-raid10-storcli.sh` (preseed partman/early_command)
6. `Partitioning` → `Installing the base system` → `Installing GRUB`
7. `Installation complete` → `Rebooting`

### Step 9: install 後検証

- SOL log で `login:` prompt
- DHCP IP 抽出 (`Configuring DHCP networking` 行)
- `ssh -F ssh/config -i ssh/id_ed25519 debian@<dhcp_ip>` 疎通
- `sudo /opt/MegaRAID/storcli/storcli64 /c0 show` で VD0 (RAID10, 4 drives, ~1.8 TB) Optimal
- `lsblk`, `df -h /`, `cat /etc/os-release` (Debian 13.3)

### Step 10: 後処理 + report

- tcpdump 停止: `ssh ubuntu@10.1.6.6 sudo pkill tcpdump`
- pcap を `tmp/<sid>/` に取り寄せ (`scp ubuntu@10.1.6.6:/tmp/boot.pcap*` → ローカル attachment へ)
- 成功時: `./issue.sh resolve 71 --report report/2026-05-21_xxx_tx1320_raid10_nfs_phase3.md`
- 失敗時: `./issue.sh block 71 --reason "Phase 3 で <真因> 判明、 Phase 4 で対処"`
- `.claude/skills/irmc-bios-raid/SKILL.md` の落とし穴セクションに `quiet` flag (or 判明した真因) を追記
- memory に `training_tx1320_kernel_boot_silent.md` 新規 (Phase 3 で真因確定したら) or 既存 [[training_tx1320_kernel_silent_post_grub.md]] を更新

## Critical Files

### 修正

- `scripts/remaster-debian-iso.sh:193` — UEFI GRUB menuentry の `--- quiet` → `---` (1 文字削除)
- `scripts/remaster-debian-iso.sh:203` — Legacy ISOLINUX txt.cfg の `--- quiet` → `---` (同上)

### 参照のみ

- `config/training_tx1320.yml` — `serial_unit: 0`, `virtual_media_type: nfs`, `iso_filename: debian-training-tx1320-raid10.iso`
- `scripts/tx1320-raid10-orchestrate.sh` — build / deploy / monitor の orchestration (変更不要)
- `scripts/irmc-virtualmedia.sh` — Phase 2 で統合済の NFS support
- `scripts/sol-monitor.py` — INSTALLER_STAGES のキーワードリスト
- `preseed/preseed.cfg.template` — early_command (syslogd → 10.1.6.1:5514) / partman/early_command (RAID10 storcli) は変更不要
- `report/2026-05-21_091931_tx1320_raid10_nfs_install.md` — Phase 2 結果
- `.claude/skills/irmc-bios-raid/SKILL.md` — NFS 経路 + BIOS backup の手順

## 失敗時のフォールバック

| 失敗症状 | 対処 |
|---------|-----|
| ISO build sanity check fail | TRAILER / preseed.cfg / cdrom-detect.postinst の各検証行を確認 → patch 競合の可能性 |
| NFS PATCH HTTP 412 | `irmc_get_etag` retry (既存 quirk) |
| ConnectCD 後 AllowableValues 未遷移 | tcpdump で 10.254.254.9 → 10.1.6.6 packet を確認、 nfs export 権限 (`10.0.0.0/8`) 再確認 |
| kernel 依然沈黙 | Step 7a/7b/7c の分岐へ。 大規模変更が必要なら本セッションは観測のみで終え、次セッションで対処策を計画 |
| install 完遂後 storcli 未動作 | partman/early_command の syslogd 経路で 10.1.6.1:5514 にログ送信されているか確認 |

## 検証方法 (end-to-end)

1. **build sanity**: `xorriso -indev <iso> -find / -name preseed.cfg` で 1 hit、cdrom-detect.postinst パッチ確認は build script 末尾 verifier に依存
2. **NFS attach**: `curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 https://10.254.254.9/redfish/v1/Systems/0` で `Actions.#FTSComputerSystem.VirtualMedia.VirtualMediaAction@Redfish.AllowableValues=["DisconnectCD"]`
3. **GRUB cfg in ISO**: `xorriso -indev <iso> -osirrox on -extract /boot/grub/grub.cfg tmp/<sid>/grub.cfg && grep -- '--- quiet\|---$' tmp/<sid>/grub.cfg` で `---` のみ残り、`quiet` 無いことを確認
4. **kernel printk in SOL**: `grep -E '^\[\s*[0-9]+\.' tmp/<sid>/sol.log` で 1 行以上ヒット (Step 6 成功条件)
5. **NFS packet flow**: `ssh ubuntu@10.1.6.6 sudo tcpdump -nr /tmp/boot.pcap | wc -l` で 100 行以上 (kernel が NFS にアクセスしている証拠)
6. **install 完遂**: `ssh debian@<dhcp_ip> sudo storcli64 /c0 show` で VD0 (RAID10, Optimal, ~1.8 TB), `cat /etc/os-release` Debian 13.3

## 実行制御

- 状態変更操作は `./oplog.sh` でラップ
- iRMC 操作は単機 (training-tx1320, クラスタ非参加) のため `pve-lock.sh` 不要
- セッション tmp は `tmp/<sid>/` (sid は `Glob pattern: "*.jsonl", path: "/home/ubuntu/.claude/transcripts"` で取得した UUID 先頭 8 文字)
- `./issue.sh start 71 --owner <session名>` で blocked → active へ

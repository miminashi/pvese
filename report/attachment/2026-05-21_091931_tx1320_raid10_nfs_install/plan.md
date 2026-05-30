# TX1320 M3 NFS Virtual Media 統合 + OS install 完遂 (Phase 2)

## Context

前セッション (`s-snuggly-goblet`, 2026-05-21 17:00-17:16) で **iRMC S4 FW 9.08F が OEM Virtual Media で NFS をサポート**することを実証済 (`report/2026-05-21_081642_tx1320_raid10_nfs_attempt.md`)。SMB worker は死亡継続中 (silly-token で復活手段なし確認) だが、NFS worker は別 process で生存しており、PATCH(ShareType="NFS") + ConnectCD で attach 成立 (AllowableValues `["ConnectCD"]` → `["DisconnectCD"]` 遷移、 NFSv4 で proc4 54 ops 処理)。

本セッション (Phase 2) では Phase 1 の手順を本コードに統合し、最終的に TX1320 M3 への RAID10 + Debian 13.3 + preseed install を NFS 経由で完遂する。

ユーザ要望:
1. `config/training_tx1320.yml` で **NFS をデフォルト化** (SMB key は rollback 用に温存)
2. ISO は **build から再生成** (最新の cdrom-detect 対策 commit `f96d47b` 込みで rebuild)
3. **OS install 完了まで実施** (build → NFS deploy → host boot → cdrom-detect → preseed → reboot → SSH 疎通確認)

## 方針

`scripts/irmc-virtualmedia.sh` に `--share-type=SMB|NFS` flag と `connect-cd` / `disconnect-cd` subcommand を**追加** (既存 SMB path は完全温存して server4-15 への影響ゼロ)。 orchestrator は `virtual_media_type` を yq で読み、 NFS なら PATCH(NFS) + ConnectCD の 2 step に分岐。

## 実装手順

### Step 1: `scripts/irmc-virtualmedia.sh` 拡張

- argument parser に `--share-type=SMB|NFS` flag 追加 (default `SMB`)
- `cmd_config` の payload 生成を SHARE_TYPE で分岐。NFS は `ShareType="NFS"` + `UserName=""` + `Password=""` を強制
- 新規 helper `irmc_oem_action` (POST `/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia`)
- 新規 subcommand `connect-cd` / `disconnect-cd` (body `{"VirtualMediaAction":"ConnectCD"}` / `"DisconnectCD"`)
- 新規 helper `cmd_wait_attached` (AllowableValues に `DisconnectCD` 出現を 12回 × 5s で polling)
- `cmd_mount` を SHARE_TYPE 別にディスパッチ: SMB は従来通り Server 非空、 NFS は `cmd_wait_attached`

### Step 2: `config/training_tx1320.yml` 追記

末尾に追加 (既存 `smb_*` は rollback 用に温存):

```yaml
virtual_media_type: nfs
nfs_host: 10.1.6.6
nfs_export_path: /var/samba/public
iso_filename: debian-training-tx1320-raid10.iso  # 旧 dummy 名から修正
```

### Step 3: `scripts/tx1320-raid10-orchestrate.sh` Phase 5a 分岐

yq 読み込み block に追加:

```sh
VM_TYPE_CFG=$("$YQ" '.virtual_media_type // "smb"' "$CONFIG")
NFS_HOST=$("$YQ" '.nfs_host // ""' "$CONFIG")
NFS_EXPORT=$("$YQ" '.nfs_export_path // ""' "$CONFIG")
```

Phase 5a を if/else 分岐:
- `nfs` 分岐: `irmc-virtualmedia.sh --share-type=NFS config ... NFS_HOST NFS_EXPORT OUTPUT_BASENAME` → `connect-cd` → `--share-type=NFS mount`
- `smb` 分岐: 既存 path 完全温存

### Step 4: build (RAID10 ISO 再生成)

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
# → /var/samba/public/debian-training-tx1320-raid10.iso (latest cdrom-detect patch 込み)
```

### Step 5: ISO を 10.1.6.6 NFS server へ配置

```sh
rsync -avh --progress -e "ssh -F ssh/config -i ssh/id_ed25519" \
  /var/samba/public/debian-training-tx1320-raid10.iso \
  ubuntu@10.1.6.6:/var/samba/public/
# size + sha256 で整合確認
```

### Step 6: deploy (NFS PATCH + ConnectCD + boot)

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
# Phase 5a: NFS PATCH (HTTP 200) → connect-cd (HTTP 204) → AllowableValues=DisconnectCD 確認
# Phase 5b: boot-override Cd UEFI
# Phase 5c: ForceOff + sleep 8 + On
```

### Step 7: monitor (SOL log で install 完遂確認)

```sh
./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml --timeout 2700
```

SOL log で順に観測:
1. GRUB → `Install` 自動選択 (5s)
2. `Loading Linux ... initrd.gz ...`
3. `Detecting hardware to find CD-ROM drives` → cdrom-detect 成功 (commit f96d47b の cmdline 効果)
4. `Loading installer components from CD-ROM`
5. `Configuring DHCP networking` (DHCP IP 取得 → SOL log に出現)
6. `Running /cdrom/setup-raid10-storcli.sh` (preseed early_command)
7. `Partitioning` → `Installing the base system` → `Installing GRUB`
8. `Rebooting`

### Step 8: install 後検証

- SOL log で `login:` prompt 出現確認
- SOL `Configuring DHCP networking` 行から DHCP IP を抽出
- `ssh -F ssh/config -i ssh/id_ed25519 debian@<dhcp_ip>` で疎通
- `sudo /opt/MegaRAID/storcli/storcli64 /c0 show` で VD0 (RAID10, 4 drives, ~1.8TB)
- `lsblk` で `/dev/sda` 存在、`df -h /` で root mount 確認
- `cat /etc/os-release` (Debian 13.3)

### Step 9: SMB baseline rollback は不要

`virtual_media_type: nfs` がデフォルト化されたため、 NFS attach 状態のまま終了して可。 次回 deploy も NFS 経由で動作する。 SMB 経路の rollback スクリプト (`disconnect-cd` + `--share-type=SMB config`) は failure handler 用のみ。

### Step 10: skill / memory / report

- `.claude/skills/irmc-bios-raid/SKILL.md` に「NFS 経路」セクション追加 (SMB との PATCH/Action body 比較、 ConnectCD 必須、 落とし穴)
- `report/2026-05-21_*_tx1320_raid10_nfs_install.md` (フォーマット: `report/REPORT.md` 準拠) 作成
- memory に必要なら NFS bypass パターン追記 (training_tx1320_nfs_solved.md 既存だが Phase 2 結果も反映)

## 失敗時のフォールバック

| 失敗症状 | 対処 |
|---------|------|
| NFS PATCH HTTP 412 | `irmc_get_etag` retry (既存 quirk) |
| ConnectCD 後 AllowableValues 未遷移 | 10.1.6.6 で `sudo tcpdump -i ens19 -nn 'host 10.254.254.9 and port 2049' -c 50` で packet 到達確認、 export 権限再確認 |
| cdrom-detect 失敗 (`No common CD-ROM`) | ALT+F2 busybox で `cat /proc/cmdline` + `lsblk` 確認、 GUI で USB device list、 DisconnectCD→ConnectCD で再 attach |
| preseed 動作せず | initrd 内 `/preseed.cfg` を `lsinitramfs` で確認、 build 再実行 |
| 全面 rollback | `disconnect-cd` → `--share-type=SMB config 10.1.6.1 public debian-training-tx1320-raid10.iso guest guest` → `virtual_media_type: smb` |

## 検証方法 (end-to-end)

1. **PATCH 後**: `curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 https://10.254.254.9/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia` で `CDImage.ShareType="NFS"` / `Server="10.1.6.6"` / `ShareName="/var/samba/public"` / `ImageName="debian-training-tx1320-raid10.iso"`
2. **ConnectCD 後**: 同 endpoint で `Actions.#FTSComputerSystem.VirtualMedia.VirtualMediaAction@Redfish.AllowableValues=["DisconnectCD"]`
3. **NFS server**: `ssh ubuntu@10.1.6.6 'sudo nfsstat -s | grep proc4'` で op count 増分
4. **install 中**: SOL log の各 phase キーワード (cdrom-detect, base system, grub)
5. **install 後**: SSH で `storcli64 /c0 show all` (RAID10 VD0 Optimal) + `lsblk` (`/dev/sda` + part)

## Critical Files

- `scripts/irmc-virtualmedia.sh` (NFS flag + connect-cd subcommand 追加)
- `scripts/tx1320-raid10-orchestrate.sh` (Phase 5a 分岐)
- `config/training_tx1320.yml` (NFS keys + iso_filename 修正)
- `.claude/skills/irmc-bios-raid/SKILL.md` (NFS 経路セクション追記)
- 参照のみ: `preseed/preseed.cfg.template` (commit f96d47b の cdrom-detect 対策確認)
- 参照のみ: `report/2026-05-21_081642_tx1320_raid10_nfs_attempt.md` (Phase 1 結果)

## 実行制御

- 状態変更操作は `./oplog.sh` でラップ
- iRMC 操作は単機 (training-tx1320) のため `pve-lock.sh` は不要 (クラスタ非参加)
- `./issue.sh start` で本セッション issue 取得
- セッション tmp は `tmp/<session-id>/`

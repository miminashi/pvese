# training-tx1320 iRMC Virtual Media: SMB → NFS 切替 experiment (Phase 1)

## Context

training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F) の OS インストール用 Virtual Media を SMB 経由で attach しようとしていたが、 5 日連続で iRMC SMB worker が完全死亡から復活せず、 物理電源切離・OEM Action ConnectCD・RemoteMountEnabled toggle・Manager.Reset すべて無効と判明済 (前レポート [2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again.md](../../projects/pvese/report/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again.md))。

そこで SMB を諦め、 同じ OEM Virtual Media endpoint の **NFS モード** に切替えて attach 経路を確保することを目指す。 根拠:

- Fujitsu iRMCtools (公式) の `isomount` スクリプトが `nfs://server/export/file.iso` URI を受理 (`ShareType` = `NFS`)
- OpenStack Ironic `irmc-virtualmedia-deploy-driver` が `remote_image_share_type = NFS` を実装
- iRMC S2/S3/S4 共通 Web UI に Remote Storage の source type として CIFS/NFS/HTTP/HTTPS の選択肢 (manual 記述)
- NFS worker と SMB worker は通常別実装 → SMB worker 死亡から独立して NFS 経路は生存している可能性が高い (実機検証で確定する)

本セッションは **Phase 1: NFS experiment** のみ。 iRMC が NFS を受理するか、 attach が成立するか、 packet が NFS server に到達するかを検証する。 本格 deploy 統合 (Phase 2: `irmc-virtualmedia.sh` 拡張・config・orchestrate 切替) は本セッションでは扱わず、 結果次第で次セッションに残す。

実験環境: ユーザ提供の **10.1.6.6** (claude-playground, Ubuntu 24.04, passwordless sudo) を NFS server として使う。 ただし iRMC → 10.1.6.6 への TCP は前回 SMB 検証で 0 packet (proxy-ARP responder の制約疑い)。 NFS でも届かない可能性があり、 この到達性確認自体が重要な結果になる。

## 既知のリスクと前提

- 既存 SMB ファイル (`/var/samba/public/debian-preseed-tx1320.iso`、 700 MB ダミー) は touch 不要 (NFS export として同ディレクトリを再利用)。
- iRMC OEM VirtualMedia の PATCH は **既存 SMB 設定を上書きする** ため、 試行終了後に必ず SMB 設定へ rollback する (Step 4)。
- iRMC InternalEventLog は 4 日間更新停止 → デバッグ性低い。 観測の主軸は同期 tcpdump + GET レスポンスの ShareType/AllowableValues。
- 10.1.6.6 が iRMC から L2 不達なら deploy 先候補は 10.1.6.1 (sudo パスワード制、 NFS 立ち上げにユーザ協力必須)。 本セッションでは 10.1.6.6 までしか試さない。
- session UUID は Step 0 で Glob 経由取得し `<SID>` と表記。 全 tmp 操作は `tmp/<SID>/` 配下。

## Critical Files (参照のみ、 本セッションでは編集しない)

- `/home/ubuntu/projects/pvese/scripts/irmc-virtualmedia.sh` — 既存 SMB PATCH 実装 (228 行、 endpoint と ETag handling を模写)
- `/home/ubuntu/projects/pvese/config/training_tx1320.yml` — SMB 設定 (rollback 用 baseline)
- `/home/ubuntu/projects/pvese/tmp/efc9ff28/oem-vm.json` — OEM PATCH body baseline (CDImage の field 一覧)
- `/home/ubuntu/projects/pvese/.claude/skills/irmc-bios-raid/SKILL.md` — iRMC OEM 操作の落とし穴一覧 (PATCH の If-Match quotes なし等)
- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh` — `BMC_SCHEME` / `BMC_CURL_OPTS` の参考実装

## 共通変数

```
BMC_IP=10.254.254.9
BMC_USER=claude
BMC_PASS=Claude123
NFS_HOST=10.1.6.6
NFS_EXPORT=/var/samba/public
ISO=debian-preseed-tx1320.iso
BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0'
```

curl 雛形 (全 curl はこのオプションが必須):
```
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 ...
```

## Step 0: session セットアップ

1. Glob (pattern `*.jsonl`, path `/home/ubuntu/.claude/transcripts`) で最新セッションの UUID を取得し、 先頭 8 文字を `<SID>` とする
2. `mkdir -p tmp/<SID>` で作業 dir 作成
3. `./issue.sh start <id> --owner s-snuggly-goblet` で課題取得 (#69 継続なら start し直す)
4. 全試行スクリプトは `tmp/<SID>/<step>.sh` に Write して `sh tmp/<SID>/<step>.sh` で実行 (CLAUDE.md のパイプ・`2>&1`・マルチライン禁止ルール遵守)

## Step 1: 10.1.6.6 に NFS server を立てる

**目的**: iRMC が読み取れる NFS export を local に用意 (既存 700 MB ダミー ISO を再利用)。

**操作** (`tmp/<SID>/nfs-setup.sh` を Write → `scp` で 10.1.6.6 に転送 → `ssh` 実行):

スクリプト内容の要点:
- `sudo apt-get install -y nfs-kernel-server rpcbind`
- `/etc/exports.d/tx1320.exports` を `printf | sudo tee` で書き込み: `/var/samba/public 10.0.0.0/8(ro,no_subtree_check,all_squash,insecure,anonuid=65534,anongid=65534)`
- `sudo exportfs -ra`
- `sudo systemctl enable --now nfs-server rpcbind`
- `sudo systemctl is-active nfs-server rpcbind` の結果を `/tmp/nfs-status.txt` に保存
- `sudo showmount -e localhost` を `/tmp/nfs-export.txt` に保存
- ローカルマウント検証: `sudo mkdir -p /mnt/nfstest`, `sudo mount -t nfs -o nfsvers=3 localhost:/var/samba/public /mnt/nfstest`, `ls /mnt/nfstest > /tmp/nfs-localmount.txt`, `sudo umount /mnt/nfstest`
- `sudo ufw status` を `/tmp/ufw-status.txt` に書く (inactive 期待)

転送・実行:
- `scp -F ssh/config -i ssh/id_ed25519 tmp/<SID>/nfs-setup.sh ubuntu@10.1.6.6:/tmp/nfs-setup.sh`
- `ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 sh /tmp/nfs-setup.sh`
- 結果回収: 上記 5 ファイルを `scp` でローカル `tmp/<SID>/` に取得

**成功判定**: `nfs-server` と `rpcbind` が active、 `showmount -e localhost` に export 行が出る、 localhost からの NFS v3 mount で `debian-preseed-tx1320.iso` が見える。

**失敗時**:
- 起動失敗 → `journalctl -u nfs-server --no-pager -n 50` を `/tmp/nfs-journal.log` に取得して原因確認 (rpcbind port 衝突等)
- export 反映失敗 → `/etc/exports.d/tx1320.exports` の構文 (TAB か space、 パーミッション括弧の閉じ) を再確認
- ufw active なら `sudo ufw allow from 10.0.0.0/8 to any port nfs` 追加

## Step 2: iRMC に NFS PATCH を投げる (経路 A 優先)

**経路 A 推奨** — 既存 PATCH endpoint で `ShareType="NFS"` に書き換え:

`tmp/<SID>/nfs-patch-a.sh` を Write:
1. GET `/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia` でレスポンス取得、 ETag を `@odata.etag` から抽出 (irmc-virtualmedia.sh:61-77 の json_get/header 抽出ロジックを模写、 `If-Match` は quotes なし)
2. PATCH `/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia` に以下を送る:
   ```json
   {
     "CDImage": {
       "Server": "10.1.6.6",
       "UserName": "",
       "Password": "",
       "UserDomain": "",
       "ShareType": "NFS",
       "ShareName": "/var/samba/public",
       "ImageName": "debian-preseed-tx1320.iso"
     },
     "RemoteMountEnabled": true
   }
   ```
3. HTTP status と Location/レスポンス body を `tmp/<SID>/nfs-patch-a.log` に保存
4. 5 秒待って同 endpoint を GET → `tmp/<SID>/oem-after-a.json`

**経路 B (fallback)** — POST OEM Action に NFS fields inline:
- `POST /redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia` body `{"FTSVirtualMediaAction":"ConnectCD","ShareType":"NFS","Server":"10.1.6.6","ShareName":"/var/samba/public","ImageName":"debian-preseed-tx1320.iso"}`
- 既存実績は `{"VirtualMediaAction":"ConnectCD"}` 単体のみ。 inline fields は ignored される確度高だが、 経路 A reject 時の薄い fallback

**経路 C (fallback)** — 経路 A 成功後に明示 ConnectCD POST:
- 経路 A で PATCH 永続化 + RemoteMountEnabled=true でも AutoAttach が起動しなかった場合、 ConnectCD POST を明示的に蹴る

**試行順**: A → 5 分待 → Step 3 で結果分類 → 失敗なら C → さらに失敗なら B

## Step 3: 検証 (経路 A と並行)

### 3-1. 同期 tcpdump on 10.1.6.6 (PATCH 投入の 10 秒前から開始、 ~ 4 分)

`tmp/<SID>/tcpdump-remote.sh` を Write → `scp` + `ssh` で 10.1.6.6 上で **同期 (foreground)** 実行:
```
sudo timeout 240 tcpdump -i ens19 -n -w /tmp/nfs.pcap 'host 10.254.254.9 and (tcp port 2049 or udp port 2049 or port 111)'
```

完了後 `scp ubuntu@10.1.6.6:/tmp/nfs.pcap tmp/<SID>/nfs.pcap`、 ローカルで `tcpdump -r tmp/<SID>/nfs.pcap -n > tmp/<SID>/nfs-pkts.log` (Bash 単発呼び出し、 リダイレクト 1 つはローカルなら許可)。

**判定**:
- packet 数 > 0 = iRMC → 10.1.6.6 到達 OK = NFS endpoint 動作可能性
- 0 packet = SMB と同じ proxy-ARP/L2 問題 = deploy 先を 10.1.6.1 に変更必要

**重要**: background `tcpdump &` は SIGHUP で死ぬ。 必ず foreground 同期 timeout で。

### 3-2. iRMC OEM VirtualMedia GET

`tmp/<SID>/get-oem.sh` → `tmp/<SID>/oem-after-nfs.json`

**判定**: `"ShareType":"NFS"` が永続化、 `"Server":"10.1.6.6"`, `"ShareName":"/var/samba/public"`, `"ImageName":"debian-preseed-tx1320.iso"`、 `"RemoteMountEnabled":true`

### 3-3. AllowableValues 遷移確認

`tmp/<SID>/get-action.sh` で `/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia` GET → `VirtualMediaAction@Redfish.AllowableValues` 抽出

**判定**: `["ConnectCD"]` のまま = 未接続、 `["DisconnectCD"]` を含む = attach 成立

### 3-4. NFS server 側 journal

`tmp/<SID>/get-nfs-journal.sh` を Write → ssh で `sudo journalctl -u nfs-server --no-pager --since '-10min'` → 結果を ssh 経由で `/tmp/nfs-journal.log` に出力 → scp 回収

**判定**: `mount request from 10.254.254.9` 等の entry あり = NFS 成立、 空 = ネットワーク不達 or iRMC NFS worker 不発

### 3-5. iRMC OEM VirtualMedia の Members 確認 (補助)

GET `/redfish/v1/Managers/iRMC/VirtualMedia/` で `Members@odata.count` が >0 か確認 (SMB と同じ判定軸)。

### 3-6. iRMC InternalEventLog (壊れている可能性高、 念のため)

`tmp/<SID>/get-eventlog.sh` で `/redfish/v1/Managers/iRMC/LogServices/InternalEventLog/Entries?$top=20&$skip=380` の最新 entries に NFS/Mount 関連 keyword があるか確認。

### 3-7. SOL host boot 検証 (上記すべて肯定的な場合のみ、 オプション)

attach 成立確定後、 host を `Cd UEFI` で boot して installer が CD device を認識するか SOL で観察 (`./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI` → forceoff → on → SOL monitor)。 本セッション完結スコープ内では時間制約により optional。

## Step 4: 結果分類 と **必須ロールバック**

| 結果 | 観測 | 次の判断 |
|------|-----|---------|
| **成功** | tcpdump > 0 + ShareType=NFS 永続化 + AllowableValues=DisconnectCD + nfs journal に mount request | NFS 経路確立 → 次セッションで Phase 2 (本格統合) |
| **半成功 (PATCH 受理、 mount 起動せず)** | ShareType=NFS 永続化 + tcpdump 0 packet + AllowableValues=ConnectCD のまま | SMB 同様の silent failure。 経路 C (明示 ConnectCD) 試行、 それも失敗なら経路 B (inline POST)、 それも失敗なら **NFS worker も死亡** と結論 |
| **PATCH reject** | HTTP 400/412 + ShareType 関連エラー | iRMC S4 FW 9.08F は OEM PATCH で NFS 非対応の結論 |
| **iRMC → 10.1.6.6 不達** | tcpdump 0 packet、 だが PATCH/GET 200 OK | ネットワーク問題で deploy 不可、 10.1.6.1 NFS server 立て直しが必要 (ユーザ協力依頼で次セッション) |
| **NFS server 起動失敗** | Step 1 で停止 | 本試行不能 |

**必須ロールバック** (どの結果でも実行):
1. `tmp/<SID>/restore-smb.sh` を Write: `./scripts/irmc-virtualmedia.sh config 10.254.254.9 claude Claude123 10.1.6.1 public debian-preseed-tx1320.iso guest guest`
2. `sh tmp/<SID>/restore-smb.sh`
3. `./scripts/irmc-virtualmedia.sh status 10.254.254.9 claude Claude123` で SMB 設定復活確認 (SMB worker が死亡したままでも config baseline は元に戻る)

## 検証エンドツーエンド (本セッションでの完了確認)

1. `tmp/<SID>/oem-after-a.json` に `"ShareType":"NFS"` が記録されている (PATCH 試行の事実証拠)
2. `tmp/<SID>/nfs-pkts.log` に iRMC からの packet 有無が記録されている (tcpdump 結果)
3. `tmp/<SID>/nfs-journal.log` に nfs-server が受信したか/しないかが記録されている
4. iRMC config が SMB baseline に rollback されている (`./scripts/irmc-virtualmedia.sh status` の Server=10.1.6.1, ShareType=SMB)
5. report `report/<timestamp>_tx1320_raid10_nfs_attempt.md` 作成 (CLAUDE.md REPORT.md ルール準拠)、 結果分類 + 次セッション課題 + ロールバック実施を記載
6. attachment dir `report/attachment/<timestamp>_tx1320_raid10_nfs_attempt/` に PATCH/GET/tcpdump/journal の全 log と plan.md コピー

## Out of Scope (次セッション以降)

- `scripts/irmc-virtualmedia.sh` の NFS 対応拡張 (`config-nfs` サブコマンド or `ShareType` 引数化)
- `config/training_tx1320.yml` への `nfs_host`/`nfs_export_path`/`virtual_media_type` keys 追加
- `scripts/tx1320-raid10-orchestrate.sh` Phase 5a の NFS 分岐
- `.claude/skills/irmc-bios-raid/SKILL.md` への NFS セクション追記
- OS install の通しテスト

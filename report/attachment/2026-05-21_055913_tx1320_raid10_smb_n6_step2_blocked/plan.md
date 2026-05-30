# N6 step 2: patched Samba 4.19.5 を 10.1.6.6 にデプロイして iRMC SMB attach を検証

セッション: `silly-token` (sid=`efc9ff28`)
日時: 2026-05-21

## Context

前セッション (`s-quizzical-wozniak`, sid=`3577cabb`) で training-tx1320 iRMC の SMB silent failure の真因が **Samba 4.19.5 の typo bug** (`source3/smbd/smb2_trans2.c:2026` の `#if defined(SMB1SERVER)` が `WITH_SMB1SERVER` の打ち間違い) と確定した。 `fsinfo_unix_valid_level()` が SMB1 の `SMB_QUERY_POSIX_FS_INFO` (level=513) を永久に弾き続けることで、 iRMC は VirtualMedia attach 前の QFS_INFO 取得段階で abort → 60s 毎の retry loop に陥っている。

修正は 1 文字追加 (`WITH_` 付与) のみで、 [proposed-patch.diff](/home/ubuntu/projects/pvese/report/attachment/2026-05-20_231624_tx1320_raid10_smb_n6_step1/proposed-patch.diff) として作成済。

本セッションの目的は **N6 step 2 = patched Samba を build / deploy / attach 検証**。

ユーザが root を自由に行使できる別サーバ **10.1.6.6** (Ubuntu 24.04.3 LTS, Samba 2:4.19.5+dfsg-4ubuntu9.4 既導入、 smb.conf 未設定の clean state) を用意してくれた。 10.1.6.6 は同じ 10.0.0.0/8 上にあり、 training-tx1320 (10.254.254.9) からも到達可能 (10.1.6.6 → 10.254.254.9 ping 170-530ms 成功確認済)。

このため **10.1.6.1 (本番 Samba) には一切触れず**、 全作業を 10.1.6.6 上で完結させる。 失敗時は smb_host を 10.1.6.1 に戻すだけで rollback できる。

## 戦略

| 軸 | 採用 | 理由 |
|----|------|------|
| build host | **10.1.6.6** | sudo 自由、 10.1.6.1 を汚さない |
| SMB server (検証) | **10.1.6.6** | 同上 |
| Samba 入れ替え方式 | **`/usr/sbin/smbd` の binary 単独差し替え** (build dir からの直 cp) | `make install` は libs / sbin/* 多数を差し替えるため副作用大。 binary 単独なら rollback 容易 (元 binary を `.orig` でバックアップ) |
| ISO ファイル | **Phase F = 空 ISO で attach 検証** → 成功後に **Phase G で 10.1.6.1 から rsync (sudo 必要、 ユーザ承認求める)** または regenerate | attach の検証は qfsinfo 段階で成否確定するため ISO 中身は不要 |
| 設定変更 | `config/training_tx1320.yml` の `smb_host: 10.1.6.1` → `10.1.6.6` への一時変更 (rollback 用に値を覚えておく) | スクリプト群はこの値を直接参照する (`tx1320-raid10-orchestrate.sh:68-69` 等) |

## 重要ファイル

### 既存 (read / 引数として使う)
- `report/attachment/2026-05-20_231624_tx1320_raid10_smb_n6_step1/proposed-patch.diff` — patch 本体 (1 文字)
- `report/attachment/2026-05-20_231624_tx1320_raid10_smb_n6_step1/grep-results.txt` — typo 確定の根拠
- `tmp/3577cabb/samba-4.19.5.tar.gz` (sha256=`0e2405b4cec29d0459621f4340a1a74af771ec7cffedff43250cad7f1f87605e`) — 再 download 不要、 10.1.6.6 に scp する
- `config/training_tx1320.yml` (lines 97-105: smb_host / smb_share_path / smb_user / smb_pass / iso_filename / iso_download_dir)
- `scripts/irmc-virtualmedia.sh` — iRMC ConnectCD / disconnect の helper (line 133, 144-183: cmd_verify は CDImage.Server を見る)
- `scripts/tx1320-raid10-orchestrate.sh` — `deploy` (lines 119-140) が iRMC ConnectCD + power cycle を実行 (smb_host を yq で読む)
- `scripts/sol-monitor.py` — installer 監視 (line 237 `monitor_loop`)

### 修正
- `config/training_tx1320.yml`: `smb_host: 10.1.6.1` → `10.1.6.6` に一時変更 (Phase B 開始時)。 失敗時は元に戻す
- 10.1.6.6 上の `/etc/samba/smb.conf` (新規)、 `/usr/sbin/smbd` (差し替え)

### 新規 (本セッションの記録)
- `tmp/efc9ff28/` — セッション作業ディレクトリ (build ログ、 verification curl 結果、 polling output 等)
- `report/2026-05-21_<HHMMSS>_tx1320_raid10_smb_n6_step2.md` (本セッション末)
- `report/attachment/2026-05-21_<HHMMSS>_tx1320_raid10_smb_n6_step2/` (build log / samba log / curl response 等)

## 実施手順

### Phase 0: 準備 (sid=efc9ff28、 10.1.6.6 への基本セットアップ)
1. `mkdir -p tmp/efc9ff28`
2. 10.1.6.6 に既存の Samba 4.19.5 tarball を scp (`tmp/3577cabb/samba-4.19.5.tar.gz` → `ubuntu@10.1.6.6:~/samba-build/`)
3. 10.1.6.6 で展開 + sha256 一致確認
4. patch ファイル (`proposed-patch.diff`) を scp し、 `patch -p1` で適用
5. patch 適用結果を grep で確認: `grep -n 'WITH_SMB1SERVER' source3/smbd/smb2_trans2.c | head` — line ~2026 周辺で `WITH_SMB1SERVER` が増えていること
6. `./issue.sh start <issue-id> --owner silly-token` で issue #69 を active 化

### Phase 1: 10.1.6.6 に SMB share を最小構成で立ち上げる
1. `sudo mkdir -p /var/samba/public && sudo chmod 755 /var/samba/public`
2. attach 検証用の空 ISO を生成: `sudo truncate -s 700M /var/samba/public/debian-preseed-tx1320.iso && sudo chmod 644 ...`
3. `/etc/samba/smb.conf` を新規作成 (10.1.6.1 の構成は確認不可だが、 iRMC の attach 要件から推定):
   ```ini
   [global]
       workgroup = WORKGROUP
       server string = claude-playground
       log file = /var/log/samba/log.%m
       log level = 10
       max log size = 0
       map to guest = Bad User
       guest account = nobody
       server min protocol = NT1
       client min protocol = NT1
       smb1 unix extensions = yes
       smb ports = 445 139
   [public]
       path = /var/samba/public
       browseable = yes
       read only = yes
       guest ok = yes
       force user = nobody
   ```
   **重要**: `server min protocol = NT1` と `smb1 unix extensions = yes` を明示。 patch のためには SMB1 が enable されている必要がある (デフォルトでは SMB2+ が最小、 iRMC は SMB1 を使用)
4. `sudo systemctl enable --now smbd nmbd` → 起動確認
5. `smbclient -L //10.1.6.6/ -U guest%guest` でローカルから接続テスト

### Phase 2: 既存 (unpatched) Samba で bug 再現 (baseline)
**目的**: 10.1.6.6 でも同じ INVALID_LEVEL が出ることを確認、 patch 後の比較対照を得る。

1. `config/training_tx1320.yml` の `smb_host: 10.1.6.1` を `10.1.6.6` に変更 (Edit tool)
2. iRMC 上で既存の VirtualMedia disconnect:
   ```sh
   export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1
   ./scripts/irmc-virtualmedia.sh --type=CD disconnect 10.254.254.9 claude Claude123
   ```
3. iRMC に新 SMB host を設定し attach:
   ```sh
   ./scripts/irmc-virtualmedia.sh config 10.254.254.9 claude Claude123 10.1.6.6 "\\public" debian-preseed-tx1320.iso guest guest
   ./scripts/irmc-virtualmedia.sh --type=CD connect 10.254.254.9 claude Claude123
   ```
4. 10.1.6.6 で `sudo truncate -s 0 /var/log/samba/log.*` 後 60s 待機
5. `Members@odata.count` polling (24×5s):
   ```sh
   ./oplog.sh curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
       https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia
   ```
6. 10.1.6.6 の `/var/log/samba/log.*` から **`level = 513` + `NT_STATUS_INVALID_LEVEL`** を grep で確認 → baseline 確定

### Phase 3: patched smbd を build
**準備時間**: 5-15 min (build-dep install) / **build 時間**: 30-50 min (4 cores / 4 GB RAM、 `-j2` 推奨)

1. 10.1.6.6 で deb-src 確認、 必要なら追加:
   ```sh
   sudo apt build-dep -y samba   # 失敗時は次の個別 install
   sudo apt install -y libldb-dev libtalloc-dev libtdb-dev libtevent-dev \
       libjansson-dev libbsd-dev libldap2-dev libpopt-dev libcap-dev libacl1-dev \
       pkg-config python3-dev python3-dnspython python3-cryptography flex bison \
       libgnutls28-dev libreadline-dev libpam0g-dev liblmdb-dev \
       libcephfs-dev libcups2-dev libdbus-1-dev libsystemd-dev libtirpc-dev libgpgme-dev
   ```
2. configure (Ubuntu 配置に揃える):
   ```sh
   cd ~/samba-build/samba-4.19.5
   ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu \
       --sysconfdir=/etc --localstatedir=/var --enable-fhs \
       --with-piddir=/run/samba --with-pammodulesdir=/lib/x86_64-linux-gnu/security
   ```
3. build (RAM 4GB なので `-j2` で開始、 OOM kill 観察したら `-j1`):
   ```sh
   make -j2
   ```
   build log は `tmp/efc9ff28/build.log` に転送 (10.1.6.6 → local)。 ビルドは background 実行で Monitor 経由で完了通知。
4. build 完了後、 patched binary を確認:
   ```sh
   ls -la bin/default/source3/smbd/smbd
   ./bin/default/source3/smbd/smbd --version
   ```

### Phase 4: patched smbd を deploy
1. `sudo systemctl stop smbd nmbd`
2. `sudo cp /usr/sbin/smbd /usr/sbin/smbd.orig.$(date +%s)` (バックアップ)
3. `sudo cp ~/samba-build/samba-4.19.5/bin/default/source3/smbd/smbd /usr/sbin/smbd`
4. `sudo /usr/sbin/smbd --version` で起動可能性 / ABI 一致を確認 (ここで shared lib エラーが出たら **ABI 不整合 — rollback** → 代替案へ)
5. `sudo systemctl start smbd nmbd && sudo systemctl status smbd`
6. ローカル接続テスト: `smbclient -L //10.1.6.6/ -U guest%guest` (依然動くこと)

### Phase 5: 修正検証 (iRMC SMB attach)
**目的**: patched smbd が level=513 に正常な response を返し、 iRMC が USB device 生成まで進むことを実証。

1. `sudo truncate -s 0 /var/log/samba/log.*` (clean slate)
2. iRMC DisconnectCD → 10s 待 → ConnectCD:
   ```sh
   ./scripts/irmc-virtualmedia.sh --type=CD disconnect 10.254.254.9 claude Claude123
   sleep 10
   ./scripts/irmc-virtualmedia.sh --type=CD connect 10.254.254.9 claude Claude123
   ```
3. 120 秒 polling (`tmp/efc9ff28/poll-after-patch.sh`):
   ```sh
   for i in $(seq 1 24); do
       ./oplog.sh curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
           https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia > tmp/efc9ff28/vm-$i.json
       count=$(grep -oE '"Members@odata.count"[[:space:]]*:[[:space:]]*[0-9]+' tmp/efc9ff28/vm-$i.json | grep -oE '[0-9]+$')
       echo "[$(date +%H:%M:%S)] iter=$i Members=$count"
       [ "$count" -ge 1 ] 2>/dev/null && { echo "ATTACH OK"; break; }
       sleep 5
   done
   ```
4. Samba log の評価軸:
   - **成功**: `level = 513` が出現するが `NT_STATUS_INVALID_LEVEL` が消失。 `Members@odata.count >= 1`。 iRMC SMB attach 成功
   - **失敗 A (patch 効かず)**: 依然 INVALID_LEVEL → patch 適用ミス / `lp_smb1_unix_extensions()` が false / 別の場所で弾かれている → grep + 再 patch
   - **失敗 B (別の NT_STATUS)**: level=513 に対する別エラー (例: NT_STATUS_ACCESS_DENIED) → response 内容を tcpdump で確認、 SMB_QUERY_CIFS_UNIX_INFO (0x200) も要求されるか確認 (N6-alt-1)
   - **失敗 C (Member 1 だが boot しない)**: attach は成立、 ISO 不在 or 形式違いで iRMC が再 abort → 実 ISO に切替えて再試行 (Phase 6 へ)

### Phase 6: 成功時 — 本番 ISO で OS install 実走 (60-90 min)
1. 10.1.6.6 上の `/var/samba/public/debian-preseed-tx1320.iso` を実 ISO に差し替える:
   - 方法 A: 10.1.6.1 から rsync (sudo + 承認必要) — `sudo rsync -av /var/samba/public/debian-preseed-tx1320.iso ubuntu@10.1.6.6:/tmp/iso.iso` 後 `sudo mv` で配置
   - 方法 B: `scripts/remaster-debian-iso.sh` を 10.1.6.6 上で動かして regenerate (Docker 必要、 時間かかる)
   - 方法 C: 10.1.6.6 で `wget` で Debian netinst を取得し `remaster-debian-iso.sh` を呼ぶ
   - **第一選択は A** (最速、 既知 / 検証済の ISO を流用)
2. `./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml` で iRMC ConnectCD + boot-override Cd + power cycle
3. `./scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 ...` で installer 監視 (45 min timeout)
4. install 成功なら post-install (sshd 接続テスト、 lsblk 確認)

### Phase 7: 失敗時 — rollback + N6-alt 検討
1. `config/training_tx1320.yml` の `smb_host` を `10.1.6.1` に戻す
2. 10.1.6.6 の smbd を元に戻す: `sudo systemctl stop smbd && sudo cp /usr/sbin/smbd.orig.* /usr/sbin/smbd && sudo systemctl start smbd`
3. 失敗パターンに応じて分岐:
   - patch 効かず → 再 grep / `lp_smb1_unix_extensions()` 設定確認 / 別 #if defined を見直し
   - 別 NT_STATUS → tcpdump で response 内容解析 → N6-alt-1 (capability negotiation)
   - level=513 が依然出る → ksmbd 検討 (N6-alt-2) / Windows SMB (N6-alt-3)

### Phase 8: report + memory + issue update
- `report/2026-05-21_<HHMMSS>_tx1320_raid10_smb_n6_step2.md` を作成 ([REPORT.md](/home/ubuntu/projects/pvese/REPORT.md) 準拠)
- attachment: build.log / patched-smbd-version.txt / poll-after-patch-results.txt / samba-log-after-patch.log / proposed upstream patch (PR 用)
- メモリ更新 (`training_tx1320_smb_n6_step2.md` 新規 + MEMORY.md index)
- Issue #69 update: 成功なら `done`、 失敗なら次の N6-alt 案を `blocked_by` に記録

## 検証方法

| 検証項目 | 方法 | 期待結果 |
|---------|------|---------|
| patch 適用済 | `grep -n 'WITH_SMB1SERVER' source3/smbd/smb2_trans2.c | head` | line 2026 周辺で `WITH_SMB1SERVER` が増 |
| build 成功 | `ls bin/default/source3/smbd/smbd && ./bin/default/source3/smbd/smbd --version` | 4.19.5 表示、 binary 存在 |
| smbd 起動 | `sudo systemctl status smbd && smbclient -L //10.1.6.6/ -U guest%guest` | active (running) + share list 表示 |
| baseline bug 再現 | Phase 2 の Samba log 内 `NT_STATUS_INVALID_LEVEL` count > 0 | 5+ 件 |
| **patch 後の修正** | Phase 5 の Samba log で `level = 513` あり / `INVALID_LEVEL` 0 件 + Members >= 1 | 両方満たす |
| (任意) install 完走 | sol-monitor が `Power down` 段階を確認後 PowerState Off で exit | timeout 内 (45 min) |

## リスクと対策

| リスク | 対策 |
|--------|------|
| build 中 OOM (4 GB RAM) | `make -j2` で開始、 必要なら `-j1`。 swap (3 GB) は存在 |
| build dep が apt にない | deb-src 追加 → `apt build-dep`、 代替で個別 install (Phase 3 step 1) |
| ABI 不一致で smbd 起動失敗 | Phase 4 step 4 で `/usr/sbin/smbd --version` 単独実行で先に検出。 失敗時は元 binary 復元 + `--prefix=/usr/local` で別配置に再 build |
| 10.1.6.6 から iRMC への高 latency (170-530ms) | 既知 ([training_tx1320_network_latency.md](/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320_network_latency.md))、 SMB silent failure の真因ではない (前セッションで反証済)。 polling timeout を 120s 確保で十分 |
| 10.1.6.1 を汚す | 一切触らない。 yml の smb_host 変更のみ。 完了後 / 失敗時に戻す |
| training_tx1320.yml 変更を忘れて next session で混乱 | 成功時は `10.1.6.6` で確定 (新 SMB host)、 失敗時は `10.1.6.1` に戻し、 失敗履歴を memory に保存 |
| iRMC が give-up state にあって patched smbd でも反応しない | 前セッション既知の 256s 復帰観測あり。 必要なら `Manager.Reset` |
| sudo apt build-dep がパスワード待ちで止まる | 10.1.6.6 は passwordless sudo (確認済)、 問題なし |

## 想定総所要時間

| Phase | 時間 |
|-------|------|
| 0 (準備) | 5 min |
| 1 (smb.conf + share) | 10 min |
| 2 (baseline 再現) | 10 min |
| 3 (build) | **30-50 min** (background) |
| 4 (deploy) | 5 min |
| 5 (検証) | 10 min |
| 6 (install、 成功時) | 60-90 min |
| 7 (rollback、 失敗時) | 5-10 min |
| 8 (report) | 15-20 min |
| **合計** | **1.5-3 時間** (build と install が大半) |

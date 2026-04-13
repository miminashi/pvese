# リージョン A+B 全体操作トレーニング (117 イテレーション)

## Context

6台のサーバ (Region A: 4-6号機 Supermicro X11DPU, Region B: 7-9号機 Dell R320) で構成される LINSTOR/DRBD マルチリージョン Proxmox VE クラスタの網羅的操作トレーニング。個別ノードの BIOS/OS セットアップからリージョン全体のマイグレーション・障害復旧まで、全操作カテゴリを3回ずつ実施して再現性を確認する。

**既知の課題**:
- Issue #41: 6号機 DIMM エラー (os-setup は 2026-04-04 完了済み、SEL にはエラーなし)
- `linstor-node-ops` スキル rejoin 手順が LVM ベースのまま (ZFS 未対応)
- 6号機 SSH 鍵未配置、LINSTOR 未登録
- Region B (7-9号機) 電源 Off

---

## Phase 1: 監視・診断 (9 iterations)

非破壊的な読み取り操作で全環境のベースラインを確立する。

### 1-3: 全環境ヘルスチェック

各イテレーションで全6ノードの以下を確認:
- 電源状態: `./scripts/bmc-power.sh status <bmc_ip> claude Claude123` x6
- SSH 接続: `ssh -F ssh/config pveN hostname` x6
- PVE クラスタ: `ssh -F ssh/config pve4 pvecm status`
- LINSTOR ノード: `ssh -F ssh/config pve4 linstor node list`
- LINSTOR リソース: `ssh -F ssh/config pve4 linstor resource list`
- DRBD 状態: `ssh -F ssh/config pve4 drbdsetup status`

**検証**: 全ノード On/Online、全リソース UpToDate
**反映先**: ベースライン記録、問題があればスキルに追記

### 4-6: LINSTOR マルチリージョンステータス詳細

- `./scripts/linstor-multiregion-status.sh config/linstor.yml`
- 各ノードの Aux/site プロパティ確認
- リージョン内 Protocol C / リージョン間 Protocol A の確認
- cross-region パスの存在確認
- IPoIB 経由の DRBD 接続状態確認

**検証**: Protocol 設定が `config/linstor.yml` と一致
**反映先**: `linstor-multiregion-status.sh` の出力フォーマット改善

### 7-9: BMC/iDRAC センサー・SEL 監視

Region A (Supermicro):
- `ipmitool -I lanplus -H <bmc_ip> -U claude -P Claude123 sensor list`
- `ipmitool -I lanplus -H <bmc_ip> -U claude -P Claude123 sel list`
- 6号機 DIMM エラーの現状確認

Region B (iDRAC):
- `ssh -F ssh/config idracN racadm getsysinfo`
- `ipmitool -I lanplus -H <bmc_ip> -U claude -P Claude123 sensor list`

**検証**: 致命的エラーなし (6号機 DIMM は例外として記録)
**反映先**: センサー閾値・アラート基準をドキュメント化

---

## Phase 2: 電源管理 (12 iterations)

BMC/iDRAC 経由の電源操作と POST 監視。各イテレーションで異なるノードを対象にする。

### 10-12: Supermicro 電源サイクル + POST 監視

対象: 10→5号機, 11→6号機, 12→4号機 (順番を変えて検証)

1. `./scripts/bmc-power.sh status <bmc_ip> claude Claude123`
2. `./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh forceoff <bmc_ip> claude Claude123`
3. 20秒待機
4. `./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh on <bmc_ip> claude Claude123`
5. POST code 監視: `./scripts/bmc-power.sh postcode <bmc_ip> claude Claude123` (30秒間隔)
6. SSH 復帰待機

**検証**: POST 完了 → SSH 復帰、所要時間記録
**反映先**: ノード別ブート時間の実測値、POST 92 スタック傾向の確認

### 13-15: iDRAC 電源サイクル + ブート監視

対象: 13→8号機, 14→9号機, 15→7号機

1. `./scripts/bmc-power.sh status <bmc_ip> claude Claude123`
2. `./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh forceoff <bmc_ip> claude Claude123`
3. 20秒待機
4. `./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh on <bmc_ip> claude Claude123`
5. SSH 復帰待機 (30秒間隔ポーリング)

**検証**: SSH 復帰、Supermicro との時間比較
**反映先**: Dell R320 ブート時間の実測値

### 16-18: Supermicro KVM スクリーンショット ブート確認

対象: 16→4号機, 17→5号機, 18→6号機

1. KVM スクリーンショット取得 (`bios-setup screenshot`)
2. POST 画面の状態を視覚的に確認
3. ブート完了後のログイン画面確認

**検証**: KVM 画像が正しく取得でき、POST 状態が判読可能
**反映先**: `bios-setup` スキルのスクリーンショット手順改善

### 19-21: iDRAC VNC スクリーンショット ブート確認

対象: 19→7号機, 20→8号機, 21→9号機

1. VNC スクリーンショット取得 (`idrac7` スキル VNC)
2. ブート画面の状態確認
3. PERC BIOS 初期化画面の確認

**検証**: VNC 画像取得成功、SYSTEM IDLE 制約の確認
**反映先**: `idrac7` スキルの VNC 手順改善

---

## Phase 3: BIOS/ファームウェア設定 (9 iterations)

BIOS メニュー操作と設定確認。設定変更は行わず読み取りのみ。

### 22-24: Supermicro BIOS 設定確認

対象: 22→4号機, 23→5号機, 24→6号機

1. `bios-setup enter <server>` で BIOS に入る
2. `bios-setup navigate <server> "Boot"` でブートタブ確認
3. Boot Option #1 の現在値を確認
4. `bios-setup navigate <server> "Advanced > Serial Port Console Redirection"` でシリアル設定確認
5. `bios-setup save-exit <server>` (変更なしで Exit)

**検証**: BIOS に入れる/出られる、設定値が読める
**反映先**: BIOS 設定の期待値リスト作成、6号機固有設定の記録

### 25-27: iDRAC 設定・システム情報確認

対象: 25→7号機, 26→8号機, 27→9号機

1. `ssh -F ssh/config idracN racadm getsysinfo`
2. `ssh -F ssh/config idracN racadm getconfig -g cfgIpmiLan`
3. `ssh -F ssh/config idracN racadm raid get vdisks`
4. `ssh -F ssh/config idracN racadm raid get pdisks`
5. `ssh -F ssh/config idracN racadm get BIOS.BiosBootSettings`

**検証**: 全設定値が読めること、RAID 状態が正常
**反映先**: iDRAC 設定の期待値リスト作成

### 28-30: PERC RAID ステータス確認

対象: 28→7号機, 29→8号機, 30→9号機

1. `ssh -F ssh/config idracN racadm raid get vdisks` — VD 一覧
2. `ssh -F ssh/config idracN racadm raid get pdisks` — PD 一覧
3. `ssh -F ssh/config idracN racadm raid get controllers` — コントローラ情報
4. VD 状態 (Online/Degraded) と PD 状態 (Ready/Online/Blocked) を記録

**検証**: VD0 が Online、全 PD が正常 (Bay 3 Blocked は既知)
**反映先**: PERC RAID 健全性チェックの自動化検討

---

## Phase 4: OS セットアップ (18 iterations)

`os-setup` スキルの各フェーズを個別にトレーニングする。Supermicro (4-6号機) と iDRAC (7-9号機) のプラットフォーム差を検証。

### 31-33: Preseed 生成 (Supermicro)

対象: 31→4号機, 32→5号機, 33→6号機

1. `./scripts/generate-preseed.sh` で preseed ファイルを生成
2. 生成された preseed の内容を確認 (diff で期待値と比較)
3. サーバ固有設定 (ホスト名, ディスク, シリアルユニット, NIC名) の正確性を検証

**検証**: preseed が正しく生成され、サーバ固有値が正確
**反映先**: `generate-preseed.sh` の改善、テンプレートの更新

### 34-36: Preseed 生成 (iDRAC)

対象: 34→7号機, 35→8号機, 36→9号機

同上手順。iDRAC 固有の差異 (serial_unit: 0, ディスク: /dev/sda, NIC: eno1) を検証。

**検証**: iDRAC 向け preseed が正しく生成される
**反映先**: iDRAC 向けテンプレート差異の記録

### 37-39: ISO リマスター (Supermicro)

対象: 各イテレーションで異なるサーバ設定の preseed を使用

1. `./scripts/remaster-debian-iso.sh` で preseed 注入済み ISO を作成
2. Supermicro 向け: initrd preseed 注入方式の動作確認
3. ISO サイズ・チェックサムの記録
4. UEFI GRUB embed.cfg の内容確認

**検証**: ISO が正しくリマスターされ、initrd に preseed が注入される
**反映先**: `remaster-debian-iso.sh` の改善

### 40-42: ISO リマスター (iDRAC)

対象: 各イテレーションで異なるサーバ設定

1. iDRAC 向け ISO リマスター (preseed は ISO ルート配置、initrd 注入なし)
2. UEFI + Legacy デュアルブート対応の確認
3. ISO ルートの preseed ファイル配置確認

**検証**: iDRAC 向け ISO が正しくリマスターされる
**反映先**: プラットフォーム別リマスター方式の差異記録

### 43-45: VirtualMedia マウント + ブートインストール (Supermicro)

対象: 43→5号機, 44→6号機, 45→4号機 (depart 済みノード対象)

1. BMC セッションログイン + VirtualMedia マウント (`bmc-virtualmedia.sh`)
2. ブート設定 (Boot Option #1 = UEFI CD/DVD or boot-next)
3. 電源サイクルでインストーラ起動
4. SOL モニタリング (`sol-monitor.py`) でインストール進捗監視
5. SSH ポーリング (`ssh-wait.sh`) でインストール完了検知
6. VirtualMedia アンマウント + ブート設定リセット

**検証**: preseed 自動インストールが完了し、SSH でログイン可能
**反映先**: `os-setup` スキル Supermicro 手順の改善

### 46-48: VirtualMedia マウント + ブートインストール (iDRAC)

対象: 46→8号機, 47→9号機, 48→7号機 (depart 済みノード対象)

1. iDRAC VirtualMedia マウント (`idrac-virtualmedia.sh`)
2. boot-once VCD-DVD 設定
3. 電源サイクルでインストーラ起動
4. SOL モニタリングでインストール進捗監視
5. SSH ポーリングでインストール完了検知
6. boot-reset でブート設定リセット

**検証**: iDRAC preseed 自動インストールが完了し、SSH でログイン可能
**反映先**: `os-setup` スキル iDRAC 手順の改善

---

## Phase 5: PVE セットアップ + クラスタ構築 (9 iterations)

OS インストール後の PVE セットアップとクラスタ参加。

### 49-51: PVE インストール (Supermicro)

対象: Phase 4 でインストールしたノード

1. SSH 鍵配置確認
2. `pve-setup-remote.sh --phase pre-reboot` 実行
3. リブート + SSH 復帰待機
4. `pve-setup-remote.sh --phase post-reboot` 実行
5. `pveversion` で PVE バージョン確認
6. デフォルトゲートウェイ修正 (10.10.10.1 → 192.168.39.1)

**検証**: PVE 正常インストール、Web UI アクセス可能
**反映先**: `pve-setup-remote.sh` の改善

### 52-54: PVE インストール (iDRAC)

対象: Phase 4 でインストールしたノード

1. pre-pve-setup.sh (iDRAC 固有の事前設定)
2. `pve-setup-remote.sh --phase pre-reboot` 実行
3. リブート + SSH 復帰待機
4. `pve-setup-remote.sh --phase post-reboot` 実行
5. PVE バージョン確認

**検証**: Dell R320 での PVE 正常インストール
**反映先**: iDRAC 向け PVE セットアップ手順の改善

### 55-57: PVE クラスタ参加 + ブリッジ設定

対象: 新規インストールしたノード

1. PVE クラスタへの参加 (`pvecm add`)
2. ブリッジ設定 (vmbr0: eno2np1/eno1, vmbr1: eno1np0/eno2)
3. クラスタステータス確認 (`pvecm status`)
4. ストレージ確認 (`pvesm status`)

**検証**: クラスタメンバーとして正常参加、ブリッジ通信可能
**反映先**: クラスタ参加手順の改善

---

## Phase 6: ネットワーク設定 (6 iterations)

IPoIB インターフェースの設定・永続化検証。

### 58-60: Region A IPoIB 設定・永続化

対象: 58→4号機, 59→5号機, 60→6号機

1. 現在の IPoIB 状態確認: `ssh -F ssh/config pveN ip link show type ipoib`
2. IP アドレス確認: `ssh -F ssh/config pveN ip addr show ibp134s0`
3. 永続設定確認: `ssh -F ssh/config pveN cat /etc/network/interfaces.d/ib0`
4. 永続設定がなければ適用:
   - `scp -F ssh/config scripts/ib-setup-remote.sh pveN:/tmp/ib-setup-remote.sh`
   - `ssh -F ssh/config pveN sh /tmp/ib-setup-remote.sh --ip 192.168.100.X/24 --mode connected --mtu 65520 --persist`

**検証**: IPoIB UP, IP 正常, 永続設定ファイル存在
**反映先**: `ib-setup-remote.sh` の改善、永続設定の確認手順追加

### 61-63: Region B IPoIB 設定・永続化

対象: 61→7号機, 62→8号機, 63→9号機

同上手順 (IB インターフェース名: ibp10s0, サブネット: 192.168.101.0/24)

**検証**: IPoIB UP, IP 正常, 永続設定ファイル存在
**反映先**: Region B 固有の差異があれば記録

---

## Phase 7: PVE + VM 操作 (9 iterations)

PVE クラスタ管理と VM ライフサイクル操作。

### 64-66: PVE クラスタステータス + ノード管理

1. Region A: `ssh -F ssh/config pve4 pvecm status`
2. Region B: `ssh -F ssh/config pve7 pvecm status`
3. 各ノードの PVE バージョン: `ssh -F ssh/config pveN pveversion`
4. ストレージ一覧: `ssh -F ssh/config pve4 pvesm status`
5. LINSTOR ストレージ確認: `ssh -F ssh/config pve4 pvesm list linstor-storage`

**検証**: 全ノードがクラスタメンバー、ストレージ available
**反映先**: PVE バージョン・構成の記録

### 67-69: VM 作成 (LINSTOR ストレージ, cloud-init)

VMID 100 (bench-vm) が存在しない場合に作成。存在する場合は設定確認のみ。

1. VM 存在確認: `ssh -F ssh/config pve4 qm status 100`
2. 存在しなければ作成 (cloud-init ベース):
   - `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve4 qm create 100 ...`
   - LINSTOR ストレージにディスク割り当て
   - cloud-init 設定 (vmbr1, DHCP)
3. VM 起動: `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve4 qm start 100`
4. SSH 接続確認

**検証**: VM running, SSH 接続可能, データ整合性ファイル作成
**反映先**: VM 作成手順のスクリプト化検討

### 70-72: VM 設定変更 + 停止・起動

1. VM 設定確認: `ssh -F ssh/config pve4 qm config 100`
2. CPU タイプ確認 (kvm64 であること)
3. VM 停止: `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve4 qm stop 100`
4. VM 起動: `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve4 qm start 100`
5. SSH 復帰確認

**検証**: 停止・起動サイクル正常、設定値一貫性
**反映先**: VM 管理手順の改善

---

## Phase 8: LINSTOR ストレージ操作 (9 iterations)

LINSTOR ストレージプール・リソースグループの操作と確認。

### 73-75: ストレージプール・ZFS 状態確認

1. SP 一覧: `ssh -F ssh/config pve4 linstor storage-pool list`
2. SP プロパティ: `ssh -F ssh/config pve4 linstor storage-pool list-properties <node> zfs-pool`
3. ZFS プール状態: `ssh -F ssh/config pveN zpool status linstor_zpool`
4. ZFS 使用量: `ssh -F ssh/config pveN zpool list linstor_zpool`

**検証**: 全ノードの SP が正常、ZFS プール ONLINE
**反映先**: ZFS 健全性チェック手順をスキルに追加

### 76-78: リソースグループ + リソース操作

1. RG 一覧: `ssh -F ssh/config pve4 linstor resource-group list`
2. RG プロパティ: `ssh -F ssh/config pve4 linstor resource-group list-properties pve-rg`
3. auto-block-size 確認: `Linstor/Drbd/auto-block-size` = 512
4. リソース一覧 + ボリューム一覧

**検証**: RG 設定が `config/linstor.yml` と一致
**反映先**: RG 設定の期待値チェックリスト作成

### 79-81: DRBD 同期監視 + 接続詳細

1. DRBD 全体状態: `ssh -F ssh/config pve4 drbdsetup status --verbose`
2. 各接続のプロトコル確認
3. 同期速度・レイテンシ確認
4. `./scripts/linstor-drbd-sync-wait.sh` の動作確認 (既に UpToDate なら即完了)

**検証**: 全接続 Connected、全ディスク UpToDate
**反映先**: DRBD 監視手順の改善

---

## Phase 9: ライブマイグレーション (12 iterations)

リージョン内ゼロダウンタイム VM 移行。各方向を検証。

### 82-84: Region A ライブマイグレーション (4↔5)

1. VM が Region A にあることを確認 (なければコールドマイグレーションで移動)
2. 事前: VM uptime, DRBD Primary 位置記録
3. マイグレーション:
   ```
   ./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-live.sh 100 ayase-web-service-5
   ```
4. 事後: uptime 連続確認、Primary 移動確認、全レプリカ UpToDate
5. 逆方向に戻す

**検証**: ダウンタイム測定、uptime 連続、レプリカ UpToDate
**反映先**: 実測値を `linstor-migration` スキルに記録

### 85-87: Region A ライブマイグレーション (4↔6, 5↔6)

85: 4→6→4, 86: 5→6→5, 87: 6→5→6 (6号機を含む全ペアを検証)

**検証**: 6号機を含むマイグレーションが安定するか
**反映先**: 6号機固有の問題があればスキル・Issue に記録

### 88-90: Region B ライブマイグレーション (7↔8)

1. VM を Region B に移動 (コールドマイグレーション)
2. 7→8→7 のライブマイグレーション往復

**検証**: Region B でのライブマイグレーション性能
**反映先**: Region B 固有の実測値記録

### 91-93: Region B ライブマイグレーション (7↔9, 8↔9)

91: 7→9→7, 92: 8→9→8, 93: 9→8→9

**検証**: Region B 全ペアでの安定性
**反映先**: 全ノードペアのマイグレーション性能マトリクス

---

## Phase 10: コールドマイグレーション (6 iterations)

リージョン間 VM 移行 (VM 停止必要)。3 Phase スクリプトの検証。

### 94-96: Region A → Region B コールドマイグレーション

1. 事前状態記録
2. コールドマイグレーション:
   ```
   ./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 100 region-a region-b
   ```
3. Phase 1-3 各所要時間記録
4. VM 起動確認 + データ整合性検証
5. 2+1 トポロジー確認

**検証**: VM 正常起動、2+1 復元、Protocol 設定正常
**反映先**: ZFS 構成でのコールドマイグレーション所要時間

### 97-99: Region B → Region A コールドマイグレーション

往復の逆方向。手順は同上。

**検証**: 往復でデータ損失なし、初期状態と最終状態の一致
**反映先**: 双方向のタイミングデータ、`linstor-migrate-cold.sh` の改善点

---

## Phase 11: ノード障害・回復 (12 iterations)

IPMI 電源断による障害シミュレーションと回復。

### 100-102: Region A 非コントローラノード fail/recover

対象: 100→5号機, 101→6号機, 102→5号機

1. 事前: DRBD/LINSTOR 状態記録、VM 位置確認
2. **fail**: `./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H <bmc_ip> -U claude -P Claude123 chassis power off`
3. Auto-eviction 無効化
4. 30秒待機 → LINSTOR OFFLINE 確認、VM 継続稼働確認
5. **recover**: power on → SSH 復帰 → DRBD bitmap resync → IPoIB 復旧
6. 全レプリカ UpToDate 確認

**検証**: VM 中断なし、回復タイムライン記録
**反映先**: `linstor-node-ops` スキル回復タイムライン更新

### 103-105: Region B ノード fail/recover

対象: 103→8号機, 104→9号機, 105→8号機

同上手順 (iDRAC IPMI)。Supermicro との回復時間差を比較。

**検証**: Dell R320 の回復タイムライン
**反映先**: プラットフォーム別タイムライン比較表

### 106-108: コントローラノード (4号機) fail/recover

1. VM が4号機以外で稼働中であることを確認
2. 4号機 power off → LINSTOR 管理不能確認
3. DRBD データパス継続を確認
4. 4号機 power on → LINSTOR コントローラ復帰

**検証**: コントローラ断でもデータパス継続、復帰後の管理復旧
**反映先**: コントローラ障害対応手順をスキルに追加

### 109-111: 6号機 (DIMM エラーあり) fail/recover

1. 6号機 IPMI SEL で DIMM エラー状態を事前確認
2. fail/recover サイクル実行
3. DIMM エラーが悪化していないか確認

**検証**: DIMM エラー下での安定性
**反映先**: ハードウェア劣化ノードの運用ガイドライン

---

## Phase 12: ノード離脱・再参加 (6 iterations)

LINSTOR クラスタからの正常離脱と ZFS ベースでの再参加。

### 112-114: Region A ノード depart/rejoin

対象: 112→5号機, 113→6号機, 114→5号機

**depart**: place-count 1 → リソース削除 → SP 削除 → ノード削除
**rejoin** (★ ZFS 対応):
1. ノード作成 → IB + PrefNic 設定
2. **ZFS SP 作成**: `linstor storage-pool create zfs <node> zfs-pool linstor_zpool`
3. place-count 復元 → DRBD フル同期 → cross-region パス再作成

**検証**: ZFS ベース rejoin の成功、フル同期時間記録
**反映先**: **`linstor-node-ops` スキル rejoin を LVM→ZFS に修正** (最重要)

### 115-117: Region B ノード depart/rejoin

対象: 115→8号機, 116→9号機, 117→8号機

同上手順。Region B 固有の差異を検証。

**検証**: Region B での ZFS rejoin 成功
**反映先**: Region B 固有の手順差異をスキルに記録

---

## 主要ファイル

| ファイル | 用途 | 更新対象 Phase |
|---------|------|---------------|
| `scripts/generate-preseed.sh` | Preseed 生成 | 4 |
| `scripts/remaster-debian-iso.sh` | ISO リマスター | 4 |
| `scripts/bmc-virtualmedia.sh` | Supermicro VirtualMedia | 4 |
| `scripts/bmc-power.sh` | 電源管理 | 2, 4 |
| `scripts/pve-setup-remote.sh` | PVE セットアップ | 5 |
| `scripts/ib-setup-remote.sh` | IPoIB 設定 | 6 |
| `scripts/linstor-multiregion-status.sh` | ステータス確認 | 1, 8 |
| `scripts/linstor-migrate-live.sh` | ライブマイグレーション | 9 |
| `scripts/linstor-migrate-cold.sh` | コールドマイグレーション | 10 |
| `.claude/skills/os-setup/SKILL.md` | OS セットアップスキル | 4, 5 |
| `.claude/skills/bios-setup/SKILL.md` | BIOS セットアップ | 3 |
| `.claude/skills/idrac7/SKILL.md` | iDRAC 管理 | 3 |
| `.claude/skills/linstor-node-ops/SKILL.md` | ノード操作 (★ZFS修正) | 12 |
| `.claude/skills/linstor-migration/SKILL.md` | マイグレーション | 9-10 |
| `config/linstor.yml` | LINSTOR 構成 | 全 Phase |
| `docs/linstor-multiregion-ops.md` | 運用ドキュメント | 9-12 |
| `preseed/preseed.cfg.template` | Preseed テンプレート | 4 |

## 実行方式

- **サブエージェント (sonnet モデル)** を最大限活用して並列実行する
- 独立したイテレーション (異なるノード対象の読み取り操作等) は並列サブエージェントで同時実行
- 状態変更操作 (`pve-lock.sh` 必須) は排他のため逐次実行
- メインエージェント (opus) は進捗管理・知見統合・スキル反映を担当
- サブエージェントの結果をメインで集約し、スキル/ドキュメントを更新

### 並列化可能な操作

| Phase | 並列可能 | 理由 |
|-------|---------|------|
| 1 (監視) | ◎ 高 | 読み取りのみ、ロック不要 |
| 2 (電源) | △ 低 | pve-lock 必須、1台ずつ |
| 3 (BIOS/iDRAC) | ○ 中 | 読み取りは並列可、KVM は1台ずつ |
| 4 (OS セットアップ) | ○ 中 | preseed/ISO 生成は並列可、インストールは1台ずつ |
| 5 (PVE セットアップ) | △ 低 | クラスタ参加は逐次 |
| 6 (IPoIB) | ○ 中 | 異なるノード対象なら並列可 |
| 7 (PVE/VM) | △ 低 | VM 操作は pve-lock 必須 |
| 8 (LINSTOR) | ○ 中 | 読み取りは並列可 |
| 9-10 (マイグレーション) | × 不可 | pve-lock + VM 排他 |
| 11-12 (障害/離脱) | × 不可 | pve-lock + クラスタ状態変更 |

## イテレーション進行ルール

1. 各イテレーション完了時に知見をまとめ、該当するスキル/ドキュメントに即時反映
2. 同一操作の3回目で安定していれば「再現性確認済み」とマーク
3. 3回中1回でも失敗した場合は根本原因を調査し、修正後に追加イテレーション
4. Phase 完了ごとにレポートを `report/` に作成 (REPORT.md フォーマット準拠)
5. 全 Phase 完了後に総合レポートを作成

## 検証方法

各イテレーション:
- `./scripts/linstor-multiregion-status.sh config/linstor.yml` で全体状態確認
- oplog に全操作が記録されていることを確認

全体完了時:
- 全スキル/ドキュメントの変更差分をレビュー
- 操作時間の統計 (平均・分散) を算出
- 改善前後の比較表を作成

---

## レポート計画

REPORT.md のフォーマットに準拠し、Phase 単位でレポートを作成する。

### レポート一覧 (予定)

| # | Phase | レポートファイル名 (英語部分) | 内容 |
|---|-------|---------------------------|------|
| 1 | 1 | `phase1_monitoring_baseline` | 全環境ヘルスチェック結果、ベースライン記録、センサー/SEL データ |
| 2 | 2 | `phase2_power_management` | 電源サイクル結果、POST 監視データ、KVM/VNC スクリーンショット、ブート時間比較 |
| 3 | 3 | `phase3_bios_firmware_check` | BIOS/iDRAC 設定値一覧、PERC RAID ステータス、期待値との差異 |
| 4 | 4 | `phase4_os_setup` | Preseed 生成、ISO リマスター、VirtualMedia マウント、ブートインストール結果 |
| 5 | 5 | `phase5_pve_setup` | PVE インストール、クラスタ参加、ブリッジ設定結果 |
| 6 | 6 | `phase6_ipoib_setup` | IPoIB 設定結果、永続化状態、リブート後の復旧確認 |
| 7 | 7-8 | `phase7_8_pve_linstor_ops` | PVE クラスタ・VM 操作結果、LINSTOR ストレージ・リソース状態 |
| 8 | 9 | `phase9_live_migration` | ライブマイグレーション全ペア結果、ダウンタイム・転送量・所要時間のマトリクス |
| 9 | 10 | `phase10_cold_migration` | コールドマイグレーション往復結果、Phase 1-3 各所要時間、DRBD 同期レート |
| 10 | 11 | `phase11_node_fail_recover` | 障害・回復タイムライン (Supermicro/Dell/コントローラ/6号機)、IPoIB 復旧状況 |
| 11 | 12 | `phase12_node_depart_rejoin` | 離脱・再参加結果、ZFS SP 作成手順、フル同期時間、cross-region パス再作成 |
| 12 | 全体 | `training_summary` | **総合レポート**: 全 Phase の統計、スキル/ドキュメント変更一覧、改善前後比較 |

### 各レポートの構成

```markdown
# Phase N: <タイトル> トレーニングレポート

- **実施日時**: YYYY年M月D日 HH:MM 〜 HH:MM JST
- **対象**: Phase N (Iteration X-Y)

## 添付ファイル

- [実装プラン](attachment/<filename>/plan.md)

## 前提・目的

- 背景: リージョン A+B 全体操作トレーニングの Phase N
- 目的: <Phase の目的>
- 前提条件: <前 Phase の完了状態>

## 環境情報

| 項目 | Region A | Region B |
|------|----------|----------|
| ノード | 4-6号機 | 7-9号機 |
| OS | Debian 13.3 + PVE 9.x | 同左 |
| ストレージ | LINSTOR/DRBD ZFS raidz1 | 同左 |

## イテレーション結果

### Iteration X: <操作内容>

**手順**: (実行コマンド)
**結果**: (出力・測定値)
**所要時間**: X分Y秒

### Iteration X+1: ...
### Iteration X+2: ...

## 再現性評価

| 指標 | Iter 1 | Iter 2 | Iter 3 | 平均 | 分散 |
|------|--------|--------|--------|------|------|
| 所要時間 | | | | | |
| 成功/失敗 | | | | | |

## 発見した問題と改善

| # | 問題 | 影響 | 対策 | 反映先 |
|---|------|------|------|--------|
| 1 | | | | |

## スキル/ドキュメント変更

- `<ファイルパス>`: <変更内容の要約>

## 参考

- [前 Phase レポート](前レポートへのリンク)
```

### レポート作成タイミング

- Phase 完了時にレポートを作成 (Phase 7+8 は合算)
- スキル/ドキュメントへの反映はイテレーション完了時に即時実行
- レポート作成時にタイムスタンプを `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` で取得
- プランファイルは最初のレポート (Phase 1) に添付し、以降のレポートからリンク

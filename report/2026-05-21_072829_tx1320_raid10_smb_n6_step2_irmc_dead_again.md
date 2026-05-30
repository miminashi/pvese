# TX1320 N6 step 2 ブロック継続: 物理電源切離後も iRMC SMB worker 復活せず (ConnectCD OEM action 含む全リカバリ手段が無効)

- **実施日時**: 2026年5月21日 15:40 〜 16:30 (JST、 約 50 分)
- **担当**: silly-token (Opus 4.7、 継続 — 物理電源切離後の再開セッション)
- **Issue**: #69 (継続、 N6 step 2 が依然 attach 検証段階でブロック)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**:
  - [2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked.md](2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked.md) (silly-token 前半、 build 完了 + SMB worker 停止発見)
  - [2026-05-20_231624_tx1320_raid10_smb_n6_step1.md](2026-05-20_231624_tx1320_raid10_smb_n6_step1.md) (s-quizzical-wozniak、 typo 真因確定)

## 添付ファイル

- [プラン](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/plan.md)
- [phaseB.log (sync tcpdump、 4 min、 iRMC→10.1.6.6 で 0 packet)](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB.log)
- [phaseB-powercycle.log (host power-cycle Cd UEFI + 7 min monitor、 0 packet)](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB-powercycle.log)
- [phaseB-test-1611.log (iRMC→10.1.6.1 + 新規 ImageName、 0 packet)](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB-test-1611.log)
- [toggle-remote-mount.log (RemoteMountEnabled false→true + 新規 ImageName、 0 packet)](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/toggle-remote-mount.log)
- [connectcd-test.log (OEM Action ConnectCD POST + 3 min monitor、 0 packet)](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/connectcd-test.log)

## 前提・目的

前ターン ([_blocked.md](2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked.md)) で iRMC SMB worker の give-up state を発見し、 ユーザに物理電源切離 (AC コード抜き 30s+) を依頼。 本ターンは:

1. iRMC Redfish 復活確認 → ✅ (5s 以内に応答、 Phase A 完了)
2. iRMC SMB worker が物理電源切離で復活したかを検証 → ❌ (Phase B で 5 経路すべて 0 packet)
3. 復活した場合は patched smbd を deploy + attach 検証 → 未到達 (worker 死亡のため)

物理電源切離後も iRMC SMB worker が復活しないことが判明し、 残りの Phase C-F は意味をなさないため本セッションは抜本的調査結果を残して終了する。

## 重要な発見

### 🚨 物理電源切離は iRMC SMB worker を復活させない (本ターン最大の発見)

5 つの異なるリカバリ経路を全て試行、 すべて 0 packet (iRMC → SMB target):

| 経路 | リカバリ手段 | 結果 |
|------|-------------|------|
| **B-1** ([phaseB.log](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB.log)) | iRMC config 10.1.6.6 + 同期 tcpdump 4 min | 0 packets to 10.1.6.6 |
| **B-2** ([phaseB-powercycle.log](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB-powercycle.log)) | + boot-override Cd UEFI + host forceoff + on + 7 min monitor | 0 packets, log 536 bytes (samba 起動時の自己分のみ) |
| **B-3** ([phaseB-test-1611.log](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB-test-1611.log)) | iRMC config 10.1.6.1 (本来の working SMB host) + 新規 ImageName で fresh init + 4 min monitor | local samba (10.1.6.1) も新規接続 0 件 |
| **B-4** ([toggle-remote-mount.log](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/toggle-remote-mount.log)) | RemoteMountEnabled false → 10s 待 → true (worker 再生成期待) + 4 min monitor | 0 packets |
| **B-5** ([connectcd-test.log](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/connectcd-test.log)) | **OEM Action `POST /redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia {"VirtualMediaAction":"ConnectCD"}`** (skill ドキュメントの「USB redirector を fresh attach できる」記述に基づく) + 3 min monitor | HTTP 204 (受理)、 だが Allowable は `['ConnectCD']` のまま (= 接続成立せず)、 0 packets |

つまり、 iRMC FW 9.08F の SMB worker は本セッションで試した **すべての software / OEM Redfish action / 物理電源切離** を以ってしても復活しない、 **永続的死亡状態** にある。

### 🚨 iRMC InternalEventLog は 4 日間更新されていない

物理電源切離前後で iRMC InternalEventLog (387 entries) を確認。 最新 entry は **2026-05-17T13:09:49 EDT** で固定、 本ターンの Manager.Reset / 物理電源切離 / 全 PATCH / ConnectCD いずれの操作も logging されていない。 ログ機能自体が壊れている可能性が高い。

### 🎯 過去の SMB 接続実績は確認 (2026-05-19 〜 2026-05-20 まで)

local 10.1.6.1 の `/var/log/samba/log.smbd` (mode 0644、 ubuntu group adm で読み取り可) を grep:

```
[2026/05/19 08:41:38] Connection allowed from ipv4:10.254.254.9:46618 to ipv4:10.1.6.1:445
[2026/05/20 14:25:10] Connection allowed from ipv4:10.254.254.9:47642 to ipv4:10.1.6.1:445
[2026/05/20 16:45:29] Connection allowed from ipv4:10.254.254.9:56825 to ipv4:10.1.6.1:445
[2026/05/20 17:32:57] Connection allowed from ipv4:10.254.254.9:56829 to ipv4:10.1.6.1:445  ← 最後の接続
```

つまり過去には iRMC SMB worker は健全に動作していたが、 2026-05-20 17:32 以降に一切接続を試みなくなった (= give-up state 突入)。

### 🎯 iRMC 構造的制約: gateway=null + /8 subnet + ARP の asymmetric (副次的)

iRMC EthernetInterfaces 確認:
- IP: 10.254.254.9
- SubnetMask: **255.0.0.0** (i.e., 10.0.0.0/8)
- **Gateway: null**
- AddressOrigin: DHCP

iRMC は **gateway なし** で /8 全体を on-link 扱い → 全 10.x.x.x へ ARP 試行。 過去に 10.1.6.1 が接続成立した = ARP 解決できた = iRMC's L2 path に proxy-ARP responder が存在 (おそらく拠点間 VPN gateway)。 10.1.6.6 への ARP 解決が同じ proxy-ARP responder で実装されているかは不明 (本ターン tcpdump で SYN すら出ない = ARP も解決できていない可能性大)。

つまり SMB worker が仮に復活しても、 **deploy 先は 10.1.6.1 限定** (10.1.6.6 は iRMC から L2 unreachable の可能性高)。

### 6. ConnectCD OEM Action は存在するが効果なし

skill `irmc-bios-raid/SKILL.md:540` に「OEM Action `POST .../FTSComputerSystem.VirtualMedia {"VirtualMediaAction":"ConnectCD"}` で USB redirector を fresh attach できる」と記載されていたため試行:
- POST → HTTP 204 (受理)
- 直後の AllowableValues は **`['ConnectCD']` のまま** (本来は ConnectCD 成功すると `['DisconnectCD']` に遷移するはず)
- 3 min 監視で local samba に 0 接続、 Members も 0
- つまり API は受理するが内部の SMB attach は実行されない (silent no-op)

これは過去のセッションで動いた action が、 SMB worker 死亡時には機能しないことを示す。 API レベルで成功扱いされるためデバッグ性も低い。

## 環境情報

### iRMC / training-tx1320

| 項目 | 値 |
|------|---|
| iRMC FW | 9.08F (S4) |
| Licenses | KVM, MEDIA (Permanent) — どちらも有効 |
| iRMC IP | 10.254.254.9/8 |
| iRMC Gateway | **null** |
| iRMC InternalEventLog | 387 entries、 最新 2026-05-17 (4 日間更新停止) |
| Last SMB conn to 10.1.6.1 | 2026-05-20 17:32:57 (本セッション開始時より約 14 時間前) |
| 物理電源切離 | ✅ 実施済 (ユーザ手動、 本ターン開始前) |

### 10.1.6.6 (build / 検証用 root 自由サーバ、 ユーザ提供) — 使用方法

| 項目 | 値 |
|------|---|
| 役割 | patched Samba 4.19.5 の build host + 検証用 SMB server (検証経路は本ターンで blocked、 build artifact は保全済) |
| OS | Ubuntu 24.04.3 LTS (Noble Numbat) |
| Hostname | claude-playground |
| Spec | 4 vCPU / 4 GB RAM / 31 GB disk (うち 23 GB 空き) |
| Network | ens18 = 192.168.39.163/24 (DHCP、 default gateway = 192.168.39.1、 インターネット可)、 ens19 = 10.1.6.6/8 (local 10.1.6.1 と同一 broadcast domain) |
| SSH 接続 | `ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6` |
| SSH key | プロジェクトローカル `ssh/id_ed25519` (`ssh/id_ed25519.pub` は authorized_keys 配置済) |
| 認証 | **passwordless sudo** (claude-playground のユーザ ubuntu は NOPASSWD: ALL) |
| iRMC 到達性 | ❌ iRMC SMB worker は 10.1.6.6 へ TCP packet を送らない (gateway=null + proxy-ARP responder 未対応の疑い、 反面 ping は 10.1.6.6→iRMC 方向で通る asymmetric) |

#### インストール済 / 設定済

- `samba` パッケージ (`2:4.19.5+dfsg-4ubuntu9.4`) + `smbclient` + `tcpdump` (本セッションで apt install 済)
- `/etc/apt/sources.list.d/ubuntu.sources` を **`Types: deb deb-src`** に拡張済 (apt build-dep samba を可能にするため)
- `apt build-dep samba` 実行済 (Samba ビルド用 dev パッケージ群が揃っている)
- `/etc/samba/smb.conf` を本セッション用に書き換え済 (server min protocol = NT1、 client min protocol = NT1、 smb1 unix extensions = yes、 log level = 10、 netbios name = SMB6、 [public] share guest ok)。 元設定は `/etc/samba/smb.conf.default` にバックアップ
- `smbd` / `nmbd` systemd unit active (running)、 ローカル `smbclient -L //10.1.6.6/ -U guest%guest -m NT1` で接続確認済
- `/var/samba/public/debian-preseed-tx1320.iso` = 700 MB ダミーファイル (attach 検証用、 中身空)

#### Samba ソース・ビルド成果物 (再利用可)

- `~/samba-build/samba-4.19.5.tar.gz` (sha256=`0e2405b4cec29d0459621f4340a1a74af771ec7cffedff43250cad7f1f87605e`、 upstream Samba)
- `~/samba-build/proposed-patch.diff` (1 文字 typo fix)
- `~/samba-build/samba-4.19.5/` 展開済 + patch 適用済 (`source3/smbd/smb2_trans2.c:2026` で `WITH_SMB1SERVER` を確認可)
- `~/samba-build/samba-4.19.5/bin/default/source3/smbd/smbd` = **patched smbd binary** (Version 4.19.5、 RUNPATH は build dir 内 shared/shared/private を指す)
- `~/samba-build/samba-4.19.5/bin/shared/` + `bin/shared/private/` = ビルドで生成された全 shared libs
- `~/samba-patched-bins.tar.gz` (33 KB、 旧 tar、 smbd 単体)
- `~/samba-patched-full.tar.gz` (2 MB、 patched smbd + 全 shared libs、 ローカル `tmp/efc9ff28/` と `report/attachment/2026-05-21_055913_.../` にコピー済)

#### よく使うコマンド (次セッション向け)

```sh
# SSH ログイン
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6

# 既存 build 成果の確認
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
    ~/samba-build/samba-4.19.5/bin/default/source3/smbd/smbd --version

# patched binary をローカルにコピー (sha256 一致確認)
scp -F ssh/config -i ssh/id_ed25519 \
    ubuntu@10.1.6.6:~/samba-build/samba-4.19.5/bin/default/source3/smbd/smbd \
    tmp/<sid>/smbd-patched

# Samba 再ビルド (patch 修正後など)
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
    'cd ~/samba-build/samba-4.19.5 && make -j2'  # 約 11 分

# 10.1.6.6 上の samba 状態確認
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
    'sudo systemctl status smbd && sudo testparm -s'

# 10.1.6.6 で同期 tcpdump (背景 & は信頼できない、 同期 foreground 必須)
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
    'sudo timeout 60 tcpdump -i any -n "host 10.254.254.9"'

# 10.1.6.6 の samba log
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
    'sudo grep -E "level = 513|NT_STATUS_INVALID_LEVEL" /var/log/samba/log.*'
```

#### 落とし穴 (繰り返し回避用)

1. **iRMC → 10.1.6.6 への TCP は 0 パケット** (本ターン同期 tcpdump で実証)。 deploy 先として使えない、 SMB worker 復活後でも 10.1.6.1 のみが iRMC から到達可能
2. **`tcpdump &` (SSH background) はパケット捕捉しない** — SSH 切断時に SIGHUP で死ぬ。 同期 (foreground) tcpdump を使うこと。 `< /dev/null` でも信頼できない。 [phaseB.log](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB.log) と [phaseB-powercycle.log](attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/phaseB-powercycle.log) で実証済
3. **build artifact の RUNPATH は build dir 固定** (`/home/ubuntu/samba-build/samba-4.19.5/bin/shared{,private}`)。 別ホスト (例: 10.1.6.1) へ deploy するときは LD_LIBRARY_PATH 設定か chrpath 書き換えが必要 — 詳細は [install-instructions.md](https://...../2026-05-21_055913_.../install-instructions.md)
4. **patched smbd を 10.1.6.6 の /usr/sbin/smbd に差し替える必要はない**: 同 host 内なら RUNPATH そのままで動く。 ただし systemd unit から起動するなら `--no-process-group` / `--foreground` を渡すなど環境を揃える必要あり (10.1.6.6 上で本 deploy は本ターン未実施、 SMB worker 死亡で価値がないため保留)

## 実施内容

### Phase A: iRMC 復活確認 ✅
- Redfish polling: 5s 以内に応答 (`@odata.id` 確認)
- PowerState: On (host on のまま)
- OEM VirtualMedia: 前ターン rollback 状態 (Server=10.1.6.1) を維持

### Phase B: SMB worker 復活確認 ❌ (5 経路すべて失敗)
- B-1 〜 B-5 を順次実行、 すべて 0 packet (詳細は上記「重要な発見」)

### Phase C-F: 未到達

iRMC SMB worker が復活しないため、 patched smbd deploy + 検証 + install のすべてが意味をなさず未到達。

### Restore
- iRMC config を 10.1.6.1 + `debian-training-tx1320-raid10.iso` + guest/guest に復元
- host を forceoff (PowerState Off)
- 10.1.6.6 上の samba は active のまま (次セッション再利用)

## 完了事項

- [x] iRMC Redfish 復活確認 (5s)
- [x] 5 経路のリカバリ手段検証 — すべて SMB worker 復活せず確認
- [x] iRMC EthernetInterfaces 確認 — gateway=null / /8 subnet を確定 (将来 deploy 先の制約となる)
- [x] iRMC InternalEventLog 確認 — 4 日間更新停止、 logging も壊れている可能性
- [x] local samba log 過去履歴確認 (mode 0644、 ubuntu/adm で読取可) — 2026-05-20 17:32 までは iRMC SMB 接続実績あり
- [x] ConnectCD OEM Action 試行 — HTTP 204 受理だが silent no-op を確認
- [x] iRMC + host を known-good 状態に restore (10.1.6.1 / power off)

## 未完了 / 次セッション課題

### 1. 🚨 最優先: iRMC SMB worker を復活させる別手段の調査

物理電源切離が効かないとなると、 残る選択肢:

| 案 | 内容 | リスク | 推奨度 |
|----|------|-------|---------|
| **(a) iRMC FW 再 reflash (同 version 9.08F)** | Redfish Action `FTSManager.FWUpdate` or `FTSManager.FWTFTPUpdate` で同 version FW を上書き install → SMB worker process bootstrap が fresh state に。 ライセンスは保持 | reflash 中の BMC 障害リスク | **★★★ 推奨** |
| (b) iRMC FW を **別 version** に更新 (9.07/9.09 等) | 既知の SMB worker 復活問題の修正 FW がある可能性 | FW 互換性、 既存設定リセット | ★★ |
| (c) **iRMC factory default reset** (CMOS battery 抜き or `Manager.Reset` の OEM resetType=`FactoryDefault` 等) | 全 worker process が fresh init される最大手 | 全設定・ライセンス・パスワード消失リスク (ユーザ要確認) | ★★ (ユーザ事前確認必須) |
| (d) iRMC への **物理 keyboard アクセス** で local console を確認 | iRMC 内部の panic / dump があれば手掛かりになる | アクセス可能か不明 | ★ |
| (e) iRMC Web UI から手動 ConnectCD クリック (過去成功例あり、 memory `training_tx1320_smb_n6_step2.md`) | Web UI が API と別の経路で attach を triggerしている可能性 | ユーザ手動操作が必要 | ★★ (ユーザ依頼) |

**最初に試すべき手段**: **(e) Web UI 手動 ConnectCD** (ユーザ依頼)、 失敗なら **(a) FW reflash**。

### 2. 並行検討: iRMC ↔ 10.1.6.6 reachability 確認

10.1.6.6 が iRMC から L2 到達可能か (proxy-ARP responder の挙動) を明示的に検証:
- iRMC SMB worker が復活後、 まず 10.1.6.1 配下で attach + 動作確認
- 次に config を 10.1.6.6 に変えて再試行、 同期 tcpdump で SYN 到達確認
- もし 10.1.6.6 で SYN が見えなければ proxy-ARP responder の問題、 deploy 先は 10.1.6.1 確定

### 3. 既存 artifact は再利用可

- patched smbd binary (`report/attachment/2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked/smbd-patched`、 sha256 一致確認済)
- tarball (`samba-patched-full.tar.gz`)
- install-instructions.md (10.1.6.1 deploy 手順 3 方式)

iRMC SMB worker 復活後 + deploy 先確定後に再利用すれば、 検証ステップから直接開始可能。

### 4. CLAUDE.md / SKILL.md / memory への追記

本ターンで判明した「物理電源切離・OEM Action ConnectCD・RemoteMountEnabled toggle・Manager.Reset いずれも SMB worker 復活させず」を SKILL `irmc-bios-raid` に追記、 同様症状の早期発見と FW reflash 推奨判断を未来セッションに引き継ぐ。

## 再現方法 (本ターンで実施した検証経路の再実行用)

```sh
SID_EXIST=efc9ff28  # 既存 sid 再利用 (アーティファクトは tmp/efc9ff28/)
export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1

# B-1: iRMC -> 10.1.6.6 + 同期 tcpdump
sh tmp/$SID_EXIST/phaseB-sync-tcpdump.sh

# B-2: + host power-cycle Cd UEFI
sh tmp/$SID_EXIST/phaseB-powercycle.sh

# B-3: iRMC -> 10.1.6.1 + 新規 ImageName で fresh init
sh tmp/$SID_EXIST/phaseB-test-1611.sh

# B-4: RemoteMountEnabled toggle
sh tmp/$SID_EXIST/toggle-remote-mount.sh

# B-5: ConnectCD OEM Action
sh tmp/$SID_EXIST/connectcd-test.sh

# 各 log: tmp/$SID_EXIST/{phaseB,phaseB-powercycle,phaseB-test-1611,toggle-remote-mount,connectcd-test}.log
# 期待 (現状): 全テストで 0 packet / 0 Members / 0 new SMB connections
```

## 関連 Issue

- **#69 (継続、 blocked → 次セッションで FW reflash 検討)**:
  - #16 (silly-token 前半): build 完了 + iRMC SMB worker 停止発見
  - **#17 (silly-token 本ターン)**: 🚨 物理電源切離 + 5 リカバリ経路で iRMC SMB worker 復活せず確認、 FW reflash が次の手段
  - **次セッション推奨**: **(e) Web UI 手動 ConnectCD** または **(a) iRMC FW 9.08F 再 reflash** で SMB worker fresh init、 続いて Phase C-F (deploy + 検証 + install)

## 関連ファイル

### 修正

- 設定変更なし (training_tx1320.yml は 10.1.6.1 のまま)
- iRMC config を 10.1.6.1 / debian-training-tx1320-raid10.iso / guest にリストア (前セッション末と同状態)
- host power off (PowerState=Off)

### 新規作成

- `report/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again.md` (本レポート)
- `report/attachment/2026-05-21_072829_tx1320_raid10_smb_n6_step2_irmc_dead_again/` (plan.md + 5 経路のログ = 6 ファイル)
- `tmp/efc9ff28/` 内に Phase B 検証スクリプト 5 件追加 (phaseB-sync-tcpdump.sh / phaseB-powercycle.sh / phaseB-test-1611.sh / toggle-remote-mount.sh / connectcd-test.sh)

## 重要な教訓 (次セッションへの引き継ぎ)

1. **🚨 iRMC FW 9.08F の SMB worker は software-only で復活させられない**: Manager.Reset、 VirtualMediaServiceRestart、 PATCH 再投入、 RemoteMountEnabled toggle、 ConnectCD OEM Action、 host power-cycle、 **物理電源切離 (AC コード抜き)** すべて無効。 唯一試していないのは (e) iRMC Web UI 手動 ConnectCD と (a/b/c) FW 関連の介入。 次セッションはこの順で試行
2. **🎯 iRMC InternalEventLog は壊れている**: 4 日間更新停止、 本ターンの操作 (Manager.Reset 含む) も logging されない。 デバッグ情報源として信頼不可
3. **🎯 ConnectCD OEM Action は silent no-op になり得る**: HTTP 204 で受理されるが AllowableValues が変化しない場合 (`['ConnectCD']` のまま) は実際に attach されていない。 デバッグの真の判定軸は **tcpdump 同期 + local samba log の新規接続行**
4. **local samba log は mode 0644 で adm group メンバ (ubuntu) が sudo なしで read 可能**: `/var/log/samba/log.smbd` を直接 cat / tail / grep で確認できる。 sudo パスワード待ちにならない。 次回からはこれを最初の調査経路にする (注: log level がデフォルト = 1 なので、 接続行は出るが SMB query 詳細は debug=10 への切替えが必要)
5. **iRMC EthernetInterfaces で gateway=null + /8 subnet は重要な事実**: iRMC は VPN proxy-ARP responder に依存して 10.x.x.x ↔ iRMC 通信を実現している。 10.1.6.1 だけが proxy-ARP 設定されている可能性大、 10.1.6.6 は L2 unreachable の可能性。 SMB worker 復活後に明示検証必要
6. **iRMC は SMB target を 10.1.6.1 に限定すべき (deploy 先確定)**: build host (10.1.6.6) と deploy 先 (10.1.6.1) は分離。 deploy には sudo パスワード必須、 ユーザ協力依頼
7. **`tcpdump &` (background) は信頼できない、 同期 (foreground) tcpdump を使う**: SSH session 終了で remote tcpdump も SIGHUP で死ぬ。 `< /dev/null` でも信頼できない場合あり。 検証では同期 tcpdump で確実に capture する (本ターンで実証)
8. **物理電源切離は最後の手段ではない**: 当初「物理電源切離で iRMC SMB worker 復活させる」想定だったが、 本ターンで反証された。 同症状再発時は FW reflash や factory default reset の方が高 ROI

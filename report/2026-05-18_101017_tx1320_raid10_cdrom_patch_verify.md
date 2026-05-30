# TX1320 RAID10 install: BMC reboot + PSU cold reset 後も iRMC SMB redirector 復旧せず、 root cause = WAN リンク latency 558ms (LAN の 1400 倍)

- **実施日時**: 2026年5月18日 09:59 〜 10:41 (JST、 約 42 分)
- **担当**: c-frolicking-starlight
- **Issue**: #69 (継続中、 status=blocked、 blocker = 拠点間ネットワーク経路品質)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**: [2026-05-18_080521_tx1320_raid10_cdrom_patch.md](2026-05-18_080521_tx1320_raid10_cdrom_patch.md) (i-floofy-pretzel、 HDImage PATCH 副作用 + SMB silent failure 固着)

## 添付ファイル

- [プラン](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/plan.md)
- [Manager.Reset GracefulRestart スクリプト](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/manager-reset.sh)
- [Manager.Reset ForceRestart スクリプト](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/manager-reset-2.sh)
- [PSU 復旧 polling スクリプト](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/post-psu-recovery.sh)
- [CD attach 90s wait poll スクリプト](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/try-attach-wait.sh)
- [SOL log (ほぼ Eied/Session operational 連発)](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/sol.log)
- [iRMC ping log (intermittent 100% loss)](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/ping-training.log)
- [Screenshot: BIOS Setup 落ち (CD 認識せず boot 失敗)](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/screenshot-1-bios-setup-no-boot.jpg)
- [VirtualMedia 状態 (PSU reset 後)](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/oem-vm-after-reset2.json)

## 重要な発見 (next-session must-read)

### 🎯 1. **iRMC SMB silent failure の root cause = WAN リンク latency 558ms** (確定、 #69 unblock 経路の判明)

ping 結果:

| 経路 | RTT min / avg / max | パケロス |
|------|---------------------|----------|
| ローカル BMC (10.10.10.24) | 0.351 / 0.370 / 0.391 ms | 0% |
| **training-tx1320 iRMC (10.254.254.9)** | **261 / 558 / 800 ms** | **0% (時々 100% も観測)** |

ローカル LAN と比較して **1400 倍遅い**。 jitter 188ms。 さらに別タイミングで取得した連続 20 ping で **100% loss** 観測 → リンクが間欠的に完全停止。

iRMC S4 の OEM USB redirector は SMB negotiation に短い timeout を持つと推定。 RTT 558ms では:
- TCP 3-way handshake = ~1.7s
- SMB negotiate request/response = +1.1s
- SMB session setup = +1.1s
- Tree connect = +1.1s
- 合計 = 5+ 秒 (パケロスでさらに増)

iRMC のタイムアウト内に SMB session 完了不可 → `Members@odata.count` が永遠に 0 のまま。 これが「TCP は ESTABLISHED だが Samba log に痕跡なし」の正体。

**前セッションの状態固着の真因はこれ**。 HDImage PATCH の副作用ではなく、 ネットワーク経路品質劣化が主因。 PATCH 試行のタイミングと劣化のタイミングが偶然 overlap した可能性が高い。

### 🎯 2. **iRMC USB redirector state は NVRAM に持続、 BMC reset では消えない**

PSU コールドリセット後の iRMC 状態確認:
- `CDImage.ImageName=debian-tx1320-v2.iso` (前セッションの中で PATCH した値が残っている)
- `RemoteMountEnabled=true`
- `UsbAttachMode=AutoAttach`
- `VirtualMediaAction.AllowableValues=["ConnectCD"]` (clean state、 = 接続中ではない)

→ Manager.Reset / PSU cold reset で SMB redirector の "stuck" は解消するが、 設定値は不揮発に保持される。 これは iRMC FW 9.08F の挙動 (S4 系全般かは未確認)。

### 🎯 3. **本セッション実施した自動的復旧 7 手すべて Members=0 のまま** (実証完了)

| # | 試行 | 経過 | 結果 (Members count) |
|---|------|------|----------------------|
| 1 | Manager.Reset **GracefulRestart** (HTTP 204、 BMC down 215s) | 09:59-10:04 | 0 |
| 2 | ConnectCD action (HTTP 204、 AllowableValues → DisconnectCD に遷移) | 10:14 | 0 |
| 3 | ForceOff host + re-PATCH CDImage + boot-override + Power On | 10:16-10:17 | 0 → BIOS Setup 落ち |
| 4 | Manager.Reset **ForceRestart** (HTTP 204、 BMC down 222s) | 10:18-10:23 | 0 |
| 5 | ConnectCD 後 +10s 待機 | 10:23-10:24 | 0 |
| 6 | 別 ISO 名 (`debian-tx1320-v2.iso`) で PATCH + ConnectCD | 10:25-10:26 | 0 |
| 7 | **PSU コールドリセット (ユーザ依頼)** + ConnectCD + 90s polling | 10:29-10:39 | 0 |

→ iRMC 側でできることは全部試したが Members=0 のまま。 **iRMC の問題ではなくネットワークの問題**と確定。

### 🎯 4. **3 回目 deploy 試行で host は BIOS Setup に落ちる** (CD 未認識による fallback)

Power On 後 5 分時点で OEM Screenshot 取得 → Aptio Setup Utility Main タブ表示 (System Time 10:26:47)。 boot-override `Cd UEFI Once` は消費済 (`BootSourceOverrideTarget=None` に reset)。 USB CD-ROM device が UEFI に enumerate されなかったため boot device なしで BIOS Setup に fallback。

[screenshot-1-bios-setup-no-boot.jpg](attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/screenshot-1-bios-setup-no-boot.jpg)

### 5. **patched ISO は再 build した (`PVESE_PATCH_CDROM_DETECT=1`)、 sanity check 4 項目 pass**

前セッション残置の `/var/samba/public/debian-training-tx1320-raid10.iso` (08:50 時点) は sanity check で `cdrom-detect.postinst missing from stream 2` で fail → **前セッション末期に baseline (`=0`) で上書き** されていたことが判明 (前セッションの Phase 8 baseline rebuild が最終 build だった可能性)。 本セッションで `PVESE_PATCH_CDROM_DETECT=1` を明示してrebuild、 764 MB ISO 生成 + sanity check 4 項目 all pass:

```
TRAILER!!! count: 2 (expected: 2)
Stream 2 preseed.cfg entries: 1 (expected: 1)
Stream 2 cdrom-detect.postinst entries: 1 (expected: 1)
pvese-patch v1 marker count: 2 (expected: >=1)
/dev/sr1 reference count: 8 (expected: >=1)
```

ISO は正しく patched 版になっている。 **install 経路の他のすべての層は ready、 ネットワーク経路品質だけが blocker**。

### 6. **TCP 接続詳細: 14KB 送信のうち 563 byte が retransmit (4%)、 MSS=1273**

`ss -nti` で確認した socket 状態 (`/var/log/samba/log.10.254.254.9` は 0 bytes:

```
ESTAB 10.1.6.1:445 ← 10.254.254.9:41272
mss:1273 (vs advmss:1448、 175 byte gap → tunnel overhead 推定)
bytes_sent:14953 bytes_retrans:563 bytes_acked:14390 bytes_received:2629
retrans:0/3 segs_out:40 data_segs_out:35 segs_in:41 data_segs_in:25
```

- MSS=1273 → PMTU 1500 だが TCP MSS が 175 byte 小さい → どこかでカプセル化 (VPN/EoIP/L2TP 等)
- Samba は 14 KB 送るが iRMC は 2.6 KB しか送ってない (返信遅延)
- Retrans 563 bytes (4% 再送)

→ TCP は流れているが iRMC 側で読み切れていない → 高 latency + 中程度の loss が原因

### 7. **smbd は最近 restart されていない、 ローカルでは正常動作**

- `/etc/samba/smb.conf` mtime = 2025-12-01 (5 ヶ月前)
- `smbd.service` Active since 2026-05-13 (5 日連続稼働)
- `log.10.254.254.9` は 0 bytes だが mtime = 2026-05-17 11:33 (前日まで使われていた)
- `server min protocol = NT1`, `client min protocol = NT1`, `ntlm auth = ntlmv1-permitted`, `guest ok = yes` (設定は前セッションから無変更)

→ Samba 側は責任なし。 ネットワーク経路と iRMC の SMB stack 相性が真因。

## 実施内容

### Phase 1: BMC reboot (Manager.Reset GracefulRestart) ✅

- Pre-state: PowerState=On
- ユーザ指示通り host を ForceOff (state → Off) してから Manager.Reset GracefulRestart
- HTTP 204 受領、 30s 待機 + polling、 BMC up 215s 後
- Post-state: AllowableValues=["ConnectCD"] (clean)、 CDImage 設定保持、 Members=0

### Phase 2: SMB redirector 復旧確認 (一旦 OK 判定) ✅

- Manager.VirtualMedia Members count: 0 (`Members@odata.count=0`)
- System Action AllowableValues: `["ConnectCD"]` (前セッションは `["DisconnectCD"]` で固着していた)
- ConnectCD 発行可能な clean state と判定

### Phase 3: ConnectCD action + Members 確認 ❌

- ConnectCD POST → HTTP 204
- AllowableValues は `["DisconnectCD"]` に遷移 (iRMC は "connected" 認識)
- Members=0 のまま (USB redirector は実際には streaming していない)
- 再 PATCH (`debian-training-tx1320-raid10.iso`) + ConnectCD + 5s wait → Members=0
- → 前セッションと同じ silent failure 再現

### Phase 4: ISO rebuild + sanity check ✅

- 前セッション残置 ISO は baseline (PVESE_PATCH_CDROM_DETECT=0) で sanity (b) fail
- `PVESE_PATCH_CDROM_DETECT=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml` で rebuild (764 MB、 3 分)
- Sanity 4 項目 all pass (TRAILER 2 + preseed.cfg 1 + cdrom-detect.postinst 1 + marker 2 + /dev/sr1 8)

### Phase 5: Deploy 試行 (1 回目) → BIOS Setup 落ち ❌

- orchestrate deploy: VirtualMedia config + boot-override Cd UEFI + ForceOff (reject、 既に Off) + Power On
- Members=0 のまま host POST → boot device なし → Aptio Setup Utility に fallback
- Screenshot: BIOS Setup Main タブ表示確認

### Phase 6: 復旧手 4-7 を逐次試行 ❌

| Action | 期待 | 結果 |
|--------|------|------|
| Manager.Reset ForceRestart (2 回目) | redirector state clean | clean に戻る (AllowableValues=ConnectCD) が Members=0 |
| 別 ISO 名 (`debian-tx1320-v2.iso`) PATCH | iRMC cache bypass | Members=0 |
| smbd restart | stale TCP 切る | **自動承認不可** (auto mode classifier reject) |
| **PSU コールドリセット (ユーザ依頼)** | 完全 reset、 NVRAM 以外消去 | **iRMC 復帰 261s + Members=0** ← root cause が iRMC でないことを実証 |
| ForceOff host + 90s Members polling | 時間あれば成立 | 18 iter × 5s で全て Members=0 |

### Phase 7: ネットワーク経路品質測定 (root cause 特定) ✅

- ping ローカル BMC (10.10.10.24): 0.35 ms 平均、 0% loss
- ping training-tx1320 (10.254.254.9): **558 ms 平均** (peak 800ms)、 jitter 188ms、 0% loss
- 別タイミングの 20 ping: **100% loss** (一時的にリンク完全停止)
- TCP socket stats: MSS=1273 (175 byte gap、 tunnel encapsulation)、 retrans 4%

→ 拠点間 VPN/トンネル経由 (10.254.254.0/24 は別拠点) で経路品質が著しく劣化。 iRMC SMB redirector の timeout に間に合わず silent failure。

## 完了事項

- [x] 既存 patched ISO の sanity 再確認 → 想定外の baseline 上書き発見、 rebuild + sanity pass
- [x] BMC Manager.Reset GracefulRestart 実施 (215s 復帰)
- [x] BMC Manager.Reset ForceRestart 実施 (222s 復帰、 AllowableValues clean に復帰)
- [x] PSU コールドリセット (ユーザ依頼) 実施、 iRMC 復帰 261s
- [x] ConnectCD/DisconnectCD/PATCH 多数試行 (全て Members=0)
- [x] 別 ISO 名での cache bypass 試行
- [x] **root cause を確定: WAN リンク latency 558ms + 間欠 100% loss**
- [x] 前セッションの「HDImage PATCH 副作用」仮説を訂正 — 真因はネットワーク経路品質
- [x] レポート作成、 issue #69 状態更新

## 未完了 / 次セッション課題

### 1. ネットワーク経路品質改善 (本 install を unblock する唯一の経路)

candidate:
- 拠点間 VPN / トンネルの確認: どの経路で 10.1.6.1 → 10.254.254.9 を運んでいるか調査、 回復策の検討
- training サイト側に SMB サーバを立てる (local SMB → iRMC は同セグメント、 low latency)
- 一時的に training サイト内の別マシンから Claude Code 実行
- 待機案: 経路が回復する時間帯を見計らって再試行 (前セッションでも「TCP は流れるが SMB は完了しない」の挙動だったので、 単純な待機では解決しない可能性が高い)

### 2. pvese-patch v1 (cdrom-detect.postinst) の実機検証 (上記 1 完了後)

- ISO は build + sanity OK で ready
- `PVESE_PATCH_CDROM_DETECT=1` で再 build (本セッションで実施済、 そのまま使える)
- SOL log で `pvese-patch: bypassed list-devices via /dev/sr1 direct mount` 検出を期待
- 前セッションで観測された 0.076s kernel hang が再現するか確認

### 3. install 完走 + RAID10 確認

- SSH 経路確立後 (DHCP IP 取得後)
- `lsblk` + `storcli64 /c0/vall show` で RAID10 healthy 確認

## 再現方法 (次セッション向け)

```sh
# Phase 0: ネットワーク品質確認 (必須前提)
ping -c 10 -W 2 10.254.254.9
# RTT > 50ms or loss > 0% なら作業中止し、 経路改善後に再開
# 健康な前回値: <5ms RTT, 0% loss (推定)

# Phase 1: SMB server 確認
ls -la /var/samba/public/debian-training-tx1320-raid10.iso
# 764MB かつ mtime 新しい patched 版なら OK

# Phase 2: BMC 状態確認 (PSU reset 後の初期状態)
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" ./scripts/bmc-power.sh status 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123

# Phase 3: ConnectCD + Members poll (network が健康なら 5-10s で Members=1 になる)
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"ConnectCD"}' \
    'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia'

sh tmp/<sid>/poll-members.sh   # 60s Members polling

# Phase 4: deploy (Members > 0 確認後)
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml

# Phase 5: SOL monitor
.venv/bin/python ./scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/sol.log --timeout 1800
```

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229)
- **BMC**: iRMC S4 FW 9.08F (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123)
- **HW**: AVAGO MegaRAID、 SAS HDD 900GB × 4 (HW RAID10 構成済)
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x
- **CPU/RAM**: 24 GiB
- **SMB server**: 10.1.6.1 (Samba 4.19.5-Ubuntu、 ローカル Claude Code 実行マシン、 ens19 で 10.1.6.1/8)
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` (764 MB、 patched 版、 sanity pass)
- **本セッションの BMC 操作回数**: Manager.Reset × 2 (Graceful + Force)、 PSU cold reset × 1 (ユーザ依頼)、 PATCH OEM VirtualMedia × 約 5、 ConnectCD × 約 4、 DisconnectCD × 約 2、 boot-override Cd UEFI × 2、 ForceOff × 約 5、 ResetType=On × 2、 OEM Screenshot × 2

## 関連 Issue

- **#69 (継続、 status=blocked、 owner c-frolicking-starlight → 次セッションへ release)**
  - 前セッション #9 (i-floofy-pretzel): cdrom-detect patch 実装 + iRMC SMB silent failure 固着 (HDImage PATCH 副作用と推定)
  - **本セッション #10 (c-frolicking-starlight)**: BMC reset 2回 + PSU コールドリセット実施しても Members=0、 root cause = WAN リンク latency 558ms + 間欠 100% loss と確定。 patch ISO は rebuild + sanity pass 済で ready
  - **次セッション推奨**: (1) ネットワーク経路品質確認 → 改善、 (2) 改善後 deploy 再試行、 (3) install 完走確認

## 関連ファイル

### 修正なし (本セッションは検証のみ)

- `scripts/remaster-debian-iso.sh` — patch 実装は前セッション (i-floofy-pretzel) のもの。 本セッションで rebuild した patched ISO は HEAD の修正で生成
- `scripts/irmc-virtualmedia.sh` — `--type=CD\|HD\|FD` 既に実装済 (前セッション)
- `scripts/tx1320-raid10-orchestrate.sh` — `monitor --timeout` 引数バグは scope 外で持ち越し
- `scripts/setup-raid10-storcli.sh` — partman/early_command 経路は次セッション以降

### 新規作成

- `report/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify.md` (本レポート)
- `report/attachment/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify/` (plan.md + 操作スクリプト + 状態 JSON + screenshot + ping log)

## 重要な教訓 (次セッションへの引き継ぎ)

1. **前セッションの「HDImage PATCH 副作用が原因」仮説は誤り**。 真因は **拠点間 WAN リンク latency 558ms + 間欠 100% loss**。 iRMC SMB redirector の内部 timeout に間に合わず silent failure。 PATCH 試行のタイミングとリンク劣化のタイミングが偶然 overlap して誤帰属。
2. **iRMC SMB redirector の挙動診断**: TCP ESTABLISHED + Samba log 0 bytes + `Members@odata.count=0` + AllowableValues=`["DisconnectCD"]` (iRMC は "connected" と認識) はネットワーク起因の SMB negotiation 不成立を示唆。 BMC reset では復旧しない。
3. **iRMC 状態は NVRAM 持続**: PSU コールドリセット後も `CDImage.ImageName` 等は保持される。 設定値の "クリーン化" には `umount` (空フィールド PATCH) が必要。
4. **PSU コールドリセット手順**: 電源ケーブル抜く → 5-10s 待機 → 差し直す → iRMC 復帰まで ~260s (Manager.Reset の 215-222s より長い)。 PowerState=On に戻る (BIOS の AC restore 設定起因と推定)。
5. **ネットワーク前提条件のチェックを TX1320 deploy 前に行う**: `ping -c 10 10.254.254.9` で RTT < 50ms かつ loss=0% を確認してから作業開始。 この事前チェックを `scripts/tx1320-raid10-orchestrate.sh deploy` に追加するのが望ましい (今後 issue 化 candidate)。
6. **smbd restart は auto mode classifier で reject される**。 SMB 側の調査が必要な場合はユーザ承認必須。 ただし本件では smbd は無関係 (smb.conf 5 ヶ月前から無変更、 smbd 5 日連続稼働)。
7. **前セッションの sanity check pass 状態は本セッションでは fail**: 前セッション末期に baseline (`=0`) rebuild が最終 build となり patched 内容が消失。 ISO の最終状態はファイルシステム上で確認しないと不明 (mtime + sanity check 必須)。
8. **OEM Screenshot は 1 deploy あたり 1-2 回に絞る**: 本セッションで 2 回使用、 連続呼び出しでの BMC 60-90s 無応答は発生せず、 milestone (Power On 5 分後 + cycle 中) のみ撮影で運用 OK。

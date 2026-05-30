# TX1320 RAID10 install: cdrom-detect patch 実機検証 + install 完走 (deploy 再開)

## Context

前セッション (`report/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify.md`、 c-frolicking-starlight) で root cause = 拠点間 WAN リンク latency 558ms + 間欠 100% loss と確定し作業 blocked。 patched ISO は build + sanity pass 済、 BMC は clean state、 deploy 経路の他のすべての層は ready。

本セッション開始時の事前調査結果:
- **ネットワーク**: ping RTT avg 208ms (前回 558ms から改善、 loss 0%、 jitter 70ms)。 ユーザ承認 = 「deploy 試行する」
- **BMC**: PowerState=Off、 AllowableValues=`["On"]`、 RemoteMountEnabled=true、 CDImage.ImageName=`debian-training-tx1320-raid10.iso` (clean state)
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` 800MB / mtime 10:07 (前報告 764MB / 09:59 と異なる) → patched 版か baseline 版か再確認必須。 ユーザ承認 = 「sanity check 4 項目を deploy 前に実行」
- **Samba**: 正常稼働、 最新 client log 10:59 (training-tx1320 接続履歴あり)

**目標**: pvese-patch v1 (cdrom-detect 直接マウント) を実機検証し、 SOL log で `pvese-patch: bypassed list-devices via /dev/sr1 direct mount` を観測。 install 完走 + RAID10 healthy 確認 + Issue #69 close。

## Phase A: Pre-flight checks (~5 min)

1. **セッション tmp 確保**: Glob で `/home/ubuntu/.claude/transcripts/*.jsonl` から UUID 取得、 先頭 8 文字を `<sid>` として `mkdir -p tmp/<sid>`
2. **A1 ネットワーク安定性**: `ping -c 30 -i 1 -W 2 10.254.254.9 > tmp/<sid>/ping-precheck.log` 実行。 判定基準 (どちらも満たすこと):
   - loss <= 0% (jitter は不問、 完全 loss=0% を要求)
   - RTT avg < 300ms (現状 208ms の悪化余地許容)
3. **A2 ISO sanity check (4 項目)**: 前セッションと同じ sanity check 4 項目を実行
   - TRAILER!!! count == 2
   - Stream 2 preseed.cfg entries == 1
   - Stream 2 cdrom-detect.postinst entries == 1
   - pvese-patch v1 marker count >= 1
   - /dev/sr1 reference count >= 1
   - 実装: `scripts/remaster-debian-iso.sh` 内の sanity ロジックを再利用するか、 `tmp/<sid>/sanity-iso.sh` を書く
4. **A2.5 (conditional rebuild)**: A2 fail なら `PVESE_PATCH_CDROM_DETECT=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml` で rebuild (~3 min)、 sanity 再実行 → pass しなければ Phase F (中止) へ
5. **A3 BMC clean state 確認**: `./scripts/bmc-power.sh status` + `./scripts/irmc-virtualmedia.sh --type=CD status` 再実行 (Phase B 直前に状態が変化していないか確認)

### A 段階の中止条件
- A1: 30 回 ping のうち loss > 0% → Phase F (中止 + レポート)
- A2/A2.5: sanity check fail + rebuild も fail → Phase F

## Phase B: SMB redirector 接続確認 (~3 min)

orchestrator は ConnectCD action を発行せず RemoteMountEnabled=true PATCH の自動 attach に依存するが、 前セッションで silent failure が再発した経緯から、 deploy 前に Members polling で SMB 接続が成立しているか実証する。

1. **B1 現状確認**: `./scripts/irmc-virtualmedia.sh --type=CD status` で Members count + AllowableValues を読む
   - Members >= 1 → 既に attached、 Phase C へ進む
   - Members = 0 + AllowableValues=`["ConnectCD"]` → B2 へ
   - Members = 0 + AllowableValues=`["DisconnectCD"]` → 一度 DisconnectCD → ConnectCD の clean サイクル必要 (B3 へ)
2. **B2 ConnectCD action + Members polling (60s)**: 5s 間隔 × 12 回 polling、 Members count 観測。 Members >= 1 検出時点で Phase C へ。
3. **B3 (conditional)**: B2 60s で Members=0 維持 → DisconnectCD → 10s 待機 → re-PATCH (`irmc-virtualmedia.sh --type=CD config`) → ConnectCD → さらに 60s polling
4. **B4**: B3 でも Members=0 → SMB silent failure 再発、 **Phase F (中止) へ** (前セッションと同じ blocker)

### B 段階の中止条件
- B4 到達 → 中止、 issue #69 を `blocked` のまま継続、 レポート作成

## Phase C: Deploy 実行 (~2 min)
(本セッションでは Phase B blocker で未到達)

## Phase D: SOL monitor + install 完走監視 (~25 min)
(本セッションでは Phase B blocker で未到達)

## Phase E: install 完走確認 (~5 min)
(本セッションでは Phase B blocker で未到達)

## Phase F: レポート作成 + Issue 更新 (~10 min、 成功・失敗どちらでも実施)

1. **F1**: レポート `report/2026-05-19_023431_tx1320_raid10_smb_blocked_persist.md` 作成
2. **F2 Issue #69 状態更新**: blocked のまま継続、 owner release
3. **F3 attachment 整理**

## 結果

Phase B B4 到達 (中止)。 ネットワーク 226ms RTT (前回 558ms から改善) でも iRMC SMB redirector の silent failure 再発。 Manager.Reset で fresh state にしても Members=0 維持。 patched ISO + BMC clean state + Samba server 全部 ready だが、 SMB negotiation が iRMC の内部 timeout 内に完了しないという根本問題が解消されていない。

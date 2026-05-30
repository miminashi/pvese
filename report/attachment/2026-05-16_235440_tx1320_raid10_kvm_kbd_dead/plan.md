# TX1320 M3 RAID10 自動構成 (KVM 経路続行 — AVAGO HII 進入完遂)

## Context

`report/2026-05-16_141200_tx1320_raid10_kvm.md` の続き。 training-tx1320 (Fujitsu PRIMERGY TX1320 M3、 iRMC S4) で進めた BIOS UEFI 化は完了済み、 RAID10 構成は AVAGO MegaRAID HII の **直前 (BIOS Setup → Advanced タブ → ArrowDown x14 で AVAGO 行をハイライト)** まで到達して中断していた。

前セッションで残った原因:

- AVAGO HII への `Enter` 押下と、 その先の Configuration Management → Create Virtual Drive → RAID10 のキーシーケンスが BMC overload と OEM Screenshot 3/3 retry 問題で時間切れ未達
- BIOS Setup HII の VGA frame buffer 問題は BMC Manager.Reset でも改善せず、 OEM Screenshot 経路 (`scripts/irmc-oem-screenshot.sh` 4-attempt retry) でしか画面取得できない確認済み

本セッション方針 (ユーザ確定):

- アプローチ: **KVM 経路継続 (Live ISO + storcli ではない)**
- 終着点: **RAID10 VD0 作成完了まで** (OS install は別セッション)
- セッション冒頭で **必ず Manager.Reset を走らせる** (BMC overload 残留をクリア)
- AVAGO HII 内のキーシーケンス探索は **milestone ごとの OEM Screenshot** (BMC overload 回避)

## 実装方針

`scripts/irmc-bios-raid-setup.sh setup-raid10` の S1-S10 dispatcher は既に skeleton として完成しており、 S6-S8 は `config/training_tx1320.yml` の `raid_setup.*_arrowdown/_tab` を埋めると自動進行する。 本セッションは:

1. **Phase α (BIOS Setup 再進入)** — `setup-raid10 --continue-from=S1 --stop-at=S5 --session=run-a` で Manager.Reset → power-on into BIOS Setup → AVAGO 行ハイライトまで一気に到達
2. **Phase β (AVAGO HII キーシーケンス探索)** — 1 viewer session 内で all-in-one シェルを組み立て、 milestone ごとに OEM Screenshot を取得し、 各 milestone の ArrowDown / Tab 回数を実機で確定。 確定値を `config/training_tx1320.yml raid_setup.*` に書き戻す
3. **Phase γ (RAID10 作成 + Save & Exit)** — `setup-raid10 --continue-from=S6 --stop-at=S9 --session=run-b` で S6-S9 を実行
4. **Phase δ (検証)** — 同 dispatcher の S10 (BIOS Setup HII 再進入 → Virtual Drives 一覧スクリーンショット) + SOL の MegaRAID OpROM banner + `/redfish/v1/Systems/0/Storage` の三点で VD0 RAID10 Optimal を確認

## Step-by-step

### Phase α: BIOS Setup 再進入 (~5分)

新規 session slug `run-a` で `setup-raid10` を `S1..S5` 範囲で実行。 S1 で Manager.Reset (GracefulRestart) → ~190s 待機 → S2 で ForceOff → boot-override BiosSetup UEFI → On + 90s 待機 → S3 で canvas alive 確認 → S4 で Main → Advanced → S5 で ArrowDown x12 (S5 dispatcher 既存仕様。 AVAGO は 14 だが S5 は探索用に 12 まで)。

実行:

```sh
./scripts/irmc-bios-raid-setup.sh setup-raid10 config/training_tx1320.yml \
    --continue-from=S1 --stop-at=S5 --session=run-a
```

**期待**: `tmp/biosraid/run-a/S5_NNN_*.png` のうち少なくとも 1 枚が Advanced タブの Network Stack / Option ROM / VIOM ハイライト画像を含む (前セッション実績で `d10`/`d11` で成功)。 これで「S2 boot-override + S3 canvas alive + S4 Main→Advanced + S5 12 ArrowDown」が再現可能であることを確認。

### Phase β: AVAGO HII キーシーケンス探索 (~30-60分、 milestone ごと screenshot)

ここからは dispatcher を使わず、 `scripts/irmc-kvm-interact.py` の `shell` モードを 1 viewer session で走らせる「all-in-one シェル」を milestone ごとに作って実機投入する。 各 milestone:

| Milestone | 動作 | 想定キー | OEM Screenshot |
|-----------|------|---------|----------------|
| M1 AVAGO 進入 | Enter (S5 で 12 ArrowDown 完了状態。 さらに ArrowDown x2 + Enter で AVAGO へ) | `ArrowDown,ArrowDown,Enter` | `avago_main.jpg` |
| M2 Configuration Management 進入 | AVAGO Main から下方向探索して Configuration Management 行に Enter | `ArrowDown x N1,Enter` | `cfgmgmt.jpg` |
| M3 Create Virtual Drive 進入 | Configuration Management Menu から Create Virtual Drive を選択 | `ArrowDown x N2,Enter` | `create_vd.jpg` |
| M4 RAID Level=RAID 10 選択 | RAID Level フィールドにフォーカス → Enter で popup → ArrowDown で RAID 10 → Enter | `Enter,ArrowDown x N3,Enter` | `raid10_selected.jpg` |
| M5 Drives 選択 (4 本) | Tab で Select Drives → Enter → 各 drive を Space で選択 → Apply Changes → Enter | `Tab x N4,Enter,Space,ArrowDown,Space,...,Tab x N5,Enter` | `drives_selected.jpg` |
| M6 Save Configuration | Tab で Save Configuration → Enter | `Tab x N6,Enter` | `save_dialog.jpg` |
| M7 Confirm Yes | Confirm ダイアログで Yes (Tab x N7) → Enter | `Tab x N7,Enter` | `confirm_done.jpg` |

各 milestone の `Nx` 値は実機 screenshot を確認しながら段階的に確定する。 1 milestone 実行ごとに OEM Screenshot を取って次の sendkeys を組み立てる。 探索は完了したら `config/training_tx1320.yml` の `raid_setup` セクションに値を書き戻す:

```yaml
raid_setup:
  avago_arrowdown: 14      # Phase α で確定済み (Advanced→AVAGO)
  cfgmgmt_arrowdown: N1
  createvd_arrowdown: N2
  raid10_arrowdown: N3
  drives_tab: N4
  apply_tab: N5
  save_tab: N6
  confirm_tab: N7
  vdlist_arrowdown: N8     # Phase δ verify 用
```

**BMC overload 緩和ルール** (前セッション学習):

- OEM Screenshot は **milestone ごと 1 回** のみ (各 milestone 内の sendkeys 間では撮らない)
- 各 oem-shot は `irmc-oem-screenshot.sh` の wall-clock retry (4 attempts, 5-15s poll) に任せる
- 1 viewer session 内に全 sendkeys を詰める (新規 viewer の最初の sendkeys 飲み込み回避)
- 冒頭に `wait:5; oem-shot:warmup.jpg;` を入れて canvas focus 確立

### Phase γ: RAID10 作成 + Save & Exit (~10分)

`config/training_tx1320.yml` に `raid_setup.*` を埋めた後、 新規 session slug `run-b` で dispatcher を S6→S9 で実行:

```sh
./scripts/irmc-bios-raid-setup.sh setup-raid10 config/training_tx1320.yml \
    --continue-from=S6 --stop-at=S9 --skip-reset --session=run-b
```

`--skip-reset` で S1 を skip し、 BIOS Setup HII から直接 S6 (AVAGO 進入) を再現させる (Phase β 後は BIOS Setup HII に居る想定。 もし phase β 中に host が再起動してしまっていたら `--continue-from=S1` で再度 Manager.Reset から)。

S6-S9 が成功すると VD0 が AVAGO ファームウェアに書き込まれ、 S9 の Save & Exit BIOS → host reboot で OpROM が VD0 を Optimal として認識する。

### Phase δ: 検証 (~5-10分)

`run-c` session で S10 を実行:

```sh
./scripts/irmc-bios-raid-setup.sh setup-raid10 config/training_tx1320.yml \
    --continue-from=S10 --stop-at=S10 --session=run-c
```

S10 は: boot-override BiosSetup UEFI → cycle → 90s 待機 → Advanced → AVAGO Main → Virtual Drives → screenshot。 加えて以下 3 点を独立に確認:

- **A. BIOS HII screenshot** (`tmp/biosraid/run-c/S10_verify.png`) に VD0 RAID10 4-drive ~1.8 TB の表記
- **B. SOL log**: `ipmitool ... sol activate` 中の MegaRAID OpROM banner に `VD 0 .* RAID10 .* Optimal` (S9 → reboot → POST 中に観測される)
- **C. Redfish Storage**: `curl https://10.254.254.9/redfish/v1/Systems/0/Storage` の Members が空でなくなる (eLCM 不在でも MegaRAID FW が報告する可能性)

## 重要な前提条件 (BMC/Host 状態)

- 前セッション終了時点で BMC が overload している可能性 — Manager.Reset で必ずクリアしてから始める
- OEM Screenshot は **3 回に 1 回程度の素成功** + retry で実用化 (詳細: report の発見 (B))
- 新規 viewer session の最初の sendkeys は swallowed されることがある (詳細: report の発見 (D))。 **1 viewer session 内 all-in-one** + 冒頭 `wait:5; oem-shot:warmup.jpg`
- AVAGO HII の各 Menu は **空行を skip した実カーソル位置で数える** (Advanced タブで実証済み)

## 影響範囲・変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `config/training_tx1320.yml` | `raid_setup` セクション追加 (`avago_arrowdown`, `cfgmgmt_arrowdown`, `createvd_arrowdown`, `raid10_arrowdown`, `drives_tab`, `apply_tab`, `save_tab`, `confirm_tab`, `vdlist_arrowdown`) |
| `tmp/biosraid/run-a/` `run-b/` `run-c/` | dispatcher 出力 (state.txt, timeline.log, *.png, *.jpg) |
| `tmp/<sid>/` | Phase β の探索シェルスクリプト (使い捨て) |
| (検証成功時のみ) `.claude/skills/irmc-bios-raid/SKILL.md` | `raid create-r10` 完全自動化に格上げ |
| (検証成功時のみ) `.claude/skills/irmc-bios-raid/reference.md` | 落とし穴 #23 を「**確定**: AVAGO HII シーケンス」に更新 |

`scripts/` 配下は **本セッションでは触らない** (dispatcher の S6-S8 skeleton は既に最終形)。 もし dispatcher の動きに不具合があれば最小修正のみ実施。

## 既存資産の活用

- **`scripts/irmc-bios-raid-setup.sh setup-raid10`** — 既存 dispatcher (S1-S10) をそのまま使う
- **`scripts/irmc-kvm-interact.py shell`** — Phase β all-in-one シェル投入用
- **`scripts/irmc-oem-screenshot.sh`** — OEM Screenshot wall-clock retry (4 attempts)
- **`scripts/bmc-power.sh`** — `BMC_SCHEME=https BMC_CURL_OPTS=...` 経由で iRMC 対応済み
- **`.claude/skills/irmc-bios-raid/{SKILL.md,reference.md}`** — Redfish プロトコル・落とし穴・キーシーケンス記載
- **`bin/yq`** — `config/training_tx1320.yml` 読み書き

## 検証方法

1. Phase α 完了後: `tmp/biosraid/run-a/S5_NNN_*.png` を Read ツールで確認、 d11-d12 付近が Option ROM Configuration / VIOM をハイライトしている画像になっているか
2. Phase β 各 milestone 後: `tmp/<sid>/<milestone>.jpg` を Read ツールで確認、 期待画面 (AVAGO Main / Config Mgmt / Create VD form / RAID10 popup / Drives list / Save dialog / Confirm dialog) になっているか
3. Phase γ 完了後: S9 saved log + host reboot で SOL banner に `VD 0` 出現
4. Phase δ 後: 3 点 (HII screenshot / SOL banner / Redfish Storage) を相互確認

## 失敗時のリカバリ

- **BMC overload (Redfish HTTP 000)**: 60-90s 待機 → 自動回復。 milestone OEM Screenshot で BMC を休ませる時間を稼ぐ
- **Phase β で host が POST loop に陥る**: `bmc-power.sh status` で確認 → Manager.Reset から `--continue-from=S1` でやり直し (session slug を `run-a2` 等にして履歴保持)
- **AVAGO HII で間違った VD を作ってしまった**: AVAGO Main → Virtual Drives → 該当 VD → Delete (キーシーケンス未確定だが、 探索範囲)。 失敗時は次回セッションで Live ISO + storcli `delete vdN` 経路に切り替える
- **Phase γ が 1 回で通らない**: Phase β に戻って milestone 数値を補正 → run-b2 として再試行
- **AVAGO HII 探索が 2 時間以上経過しても進まない**: ユーザに方針再確認 (Live ISO + storcli への切替判断)

## 完了条件

- [ ] `config/training_tx1320.yml` `raid_setup.*` 全項目埋まる
- [ ] `tmp/biosraid/run-c/S10_verify.png` に VD0 RAID10 4-drive ~1.8 TB
- [ ] SOL log に `VD 0 .* RAID10 .* Optimal` 1 行以上
- [ ] (option) Redfish Storage Members 空でない
- [ ] `report/2026-05-16_*_tx1320_raid10_kvm_complete.md` (新規レポート) を作成 — REPORT.md 規約準拠

## 関連ファイル

- 親レポート: [report/2026-05-16_141200_tx1320_raid10_kvm.md](../../projects/pvese/report/2026-05-16_141200_tx1320_raid10_kvm.md)
- 親プラン (前セッション): [attachment/2026-05-16_141200_tx1320_raid10_kvm/plan.md](../../projects/pvese/report/attachment/2026-05-16_141200_tx1320_raid10_kvm/plan.md)
- 既存 dispatcher: [scripts/irmc-bios-raid-setup.sh](../../projects/pvese/scripts/irmc-bios-raid-setup.sh) (479 行)
- skill: [.claude/skills/irmc-bios-raid/](../../projects/pvese/.claude/skills/irmc-bios-raid/)
- config: [config/training_tx1320.yml](../../projects/pvese/config/training_tx1320.yml)
- Issue: #69 (verify 状態。 本セッション完遂で done へ)

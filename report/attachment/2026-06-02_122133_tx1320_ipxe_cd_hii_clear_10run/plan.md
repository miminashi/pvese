# training-tx1320 OS install ×10 (VirtualMedia iPXE-CD + BIOS HII RAID Clear) + skill 反復改善

## Context

training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 @ 10.254.254.9, FW 9.69F) への Debian OS install を
**VirtualMedia iPXE-CD 経路**で 10 回反復し、試行ごとに得た知見でスキルを改善する。

**重要な前提（2026-06-02）**: ユーザが BIOS HII (AVAGO MegaRAID) KVM 経由の RAID 操作（Clear Configuration および
RAID10 作成）を実機実証し、2026-05-17 の「dead-end」判定が偽陰性だったことを覆した（report
`2026-06-02_020652_tx1320_raid10_bios_hii_success.md`、issue #69 done）。**本タスクではこのうち Clear Configuration
（削除）のみを各試行前の「RAID 初期化」に用いる**（RAID10 作成は install 中の storcli が担当）。Clear/commit ダイアログ
操作の自動化手順とハードニング知見（フォーカスクリック座標・keyrepeat ≥1600ms 等）は同 report / SKILL に確立済み。

ユーザ確定事項:
- 経路 = **VirtualMedia iPXE-CD**
- 各試行前の RAID 初期化スコープ = **(A) BIOS HII で Clear Configuration（削除）のみ**。
  VD を削除し Unconfigured Good に揃える＝「初期状態を揃える」。**RAID10 の作成は install 中の storcli に任せる**
  （実証済み iPXE-CD フローを崩さない）。Clear は確認ダイアログ 1 回の commit で済み、HII での RAID10 フル構築
  （span 構成・ドライブ個別選択・per-key 検証で 20–40 分）より大幅に速く、各試行が短く堅牢になる。
- 改善対象スキル = 経路に合わせ自動選択 → **irmc-bios-raid**（HII Clear Configuration 手順の堅牢化・プリミティブ昇格）と
  **pxe-deploy**（VirtualMedia iPXE-CD install の知見）の 2 つ。

## 既存資産（再利用。新規コードは最小化）

| 資産 | パス | 役割 |
|------|------|------|
| KVM 永続サーバ | `.venv/bin/python scripts/irmc-kvm/server.py --bmc-ip ... --srv-dir tmp/<sid>/srv` | 単一健全セッション + コマンドファイル駆動。HII 操作の土台 |
| KVM プリミティブ | `scripts/irmc-kvm/kvmlib.py` | login/viewer/press/keyrepeat/mouse 等。**本タスクで commit_confirm_dialog 等を昇格** |
| RAID HII 手順 | `.claude/skills/irmc-bios-raid/SKILL.md`「🎉🎯🎯🎯 2026-06-02 ... RAID10 dead end は覆った」節 | Clear Configuration 手順（本タスクで使用）+ commit ダイアログのハードニング知見 |
| VGA screenshot | `./scripts/irmc-oem-screenshot.sh <bmc> <u> <p> <out.jpg> [poll] [retries]` | **要所撮影はこれ（真 VGA）** |
| iPXE-CD deploy | `./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml ipxe-training-tx1320.iso` | 8 段シーケンス。そのまま使用 |
| iPXE ISO builder | `./scripts/build-ipxe-iso.sh <ipxe.efi> <out.iso>` | 既存 ISO があれば再 build 不要 |
| preseed 生成 | `./scripts/generate-preseed.sh --pxe=http://10.1.6.6 config/training_tx1320.yml <out.cfg>` | storcli を HTTP 取得し RAID10 を delete force + 作成（Clear 後なので delete は no-op、create が効く） |
| 電源/boot | `./scripts/bmc-power.sh`（iRMC env 5 変数 export 必須） | forceoff/on/boot-override |
| SOL 監視 | `.venv/bin/python scripts/sol-monitor.py --bmc-ip ... --log-file ... --timeout 1800` | install 進捗（read-only） |

iRMC 用 env（`bmc-power.sh` 呼び出し前に必ず export）:
`BMC_SCHEME=https` / `BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"` / `POWER_ON_RESET_TYPE=On` /
`BMC_PATCH_REQUIRES_ETAG=1` / `BMC_BOOT_OVERRIDE_NO_DISABLED=1`

## 事前準備（ループ前に 1 回）

1. session tmp 作成: `mkdir -p tmp/<sid>`（UUID 先頭 8 桁、Glob で取得）。`./oplog.sh` 経由で状態変更を記録。
2. 拠点間リンク疎通確認（`ping 10.254.254.9`、過去に高 latency/間欠 loss 既往）。
3. **preseed 生成 → scp**: `generate-preseed.sh --pxe=http://10.1.6.6`（storcli RAID10 作成入り）→ embedded ipxe.efi が
   参照する preseed URL パス（`playground:/var/samba/public/preseed/training-tx1320.cfg`）へ配置。
   storcli64.bin / setup-raid10-storcli.sh が playground HTTP で配信されているか確認。
4. iPXE-CD ISO の存在確認（`10.1.6.6:/var/samba/public/ipxe-training-tx1320.iso`）。無ければ `build-ipxe-iso.sh`。
   embedded ipxe.efi の cmdline に `interface=eno1` と preseed URL が入っているか確認（入っていなければ再 build）。
5. レポート雛形 + `report/<ts>_..._10run/` 配下に `run-01`..`run-10/` と `attachment/` を用意。

## 1 試行の手順（A–H、run N ごと）

- **A. BIOS HII で RAID 初期化（Clear Configuration のみ）**: env export → `boot-override BiosSetup UEFI` → power on →
  OEM screenshot で Main 到達確認。`irmc-kvm/server.py` 永続セッション起動。
  SKILL.md の手順で **Advanced → AVAGO MegaRAID → Main Menu → Configuration Management → Clear Configuration →
  確認ダイアログ commit**（1 コマンドファイル集約 + フォーカスクリック `80 240` + No→ArrowDown wrap→Confirm→Enter）。
  `keyrepeat` は ≥1600ms。**per-key + screenshot 検証ループで進める（固定シーケンス盲信はしない）**。
  裏取り: Virtual Drive Management で VD が無い（または Drives が Unconfigured Good）ことを KVM + OEM 真 VGA で確認。
  撮影: `01_clear_confirm` / `02_vdm_cleared`。
  **失敗時**: 同一セッションで再試行（最大 2 回）。再現不能なら runlog に記録しユーザにエスカレーション可否を確認。
  なお Clear 後に storcli が `delete force`→create するため、Clear が万一空振りでも install は成立する（初期状態統一の保証が主目的）。
- **B. ISO 存在確認**: NFS export に iPXE-CD ISO があるか確認。
- **C. iPXE-CD deploy**: host を ForceOff → `./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml ipxe-training-tx1320.iso`。
  CD が host に提示されない場合は driver 内 ServiceRestart 込みで **1 回だけ再 deploy**。
  撮影: `03_ipxe_boot`。
- **D. 監視**: `sol-monitor.py` + playground `nginx access.log`。**preseed GET + storcli64.bin GET + phonehome GET** を
  真の進捗とする（storcli が RAID10 を作成）。撮影: `04_di_stage`。
- **E. 完了判定**: **auto-poweroff（PowerState=Off）かつ phonehome GET** の両成立。**proactive ForceOff 厳禁**。
- **F. disk boot**: env export → `boot-override Hdd UEFI` → `on` → 約 3 分待機。撮影: `05_login`。
- **G. 検証**: `ssh playground "ip neigh | grep 4c:52:62:14:de:f0"` で eno2 IP 特定 → `ssh -F ssh/config root@<ip>` →
  `storcli64 /c0/vall show` が `RAID-10 Optimal 1.635 TB`（storcli 作成）を返すことを `06_verify.txt` に保存 +
  `lsblk` で /dev/sda がその VD として見えることを確認。run 1 では Clear→storcli create が確実に効いたことを重点確認。
- **H. runlog 追記**: `runlog.md` に 1 行（後述カラム）。

## ループ境界でのスキル改善ルール（churn を避ける）

- 既定は `runlog.md` 追記のみ。**具体的・一般化可能な知見が出たときだけ** 1 知見 = 1 編集で更新:
  - HII Clear Configuration 手順の再現性・落とし穴・タイミング・座標 → `irmc-bios-raid` SKILL.md
  - iPXE-CD deploy / preseed storcli / USB redirector の挙動 → `pxe-deploy` SKILL.md
- **report 推奨のプリミティブ昇格**: Clear 手順が 2-3 run 再現できたら `scripts/irmc-kvm/kvmlib.py` に
  `commit_confirm_dialog()` / `nav_rows()`（既定 ≥1600ms）を切り出す（Clear/RAID 操作で共通利用価値が高い）。
- install 進行中には絶対に編集しない。run 10 後に consolidation パス 1 回。
- スキル/コード更新は commit 候補品質。**commit はユーザ承認後**。

## スクリーンショット計画

要所は全て `irmc-oem-screenshot.sh`（真 VGA）。KVM canvas は黒画 artifact（同一サイズ/sha256 ~11857B が tell）のため
HII ナビ確認の補助のみ。1 run の撮影点: `01_clear_confirm` → `02_vdm_cleared`（RAID 初期化）→
`03_ipxe_boot` → `04_di_stage` → `05_login`（install）+ `06_verify.txt`（SSH 検証）。
KVM oem-shot のバーストは deploy の curl 嵐と時間的に分離（Make 連打中 BMC は 60–90s 無応答）。

## レポート構成（REPORT.md 準拠）

`report/<ts>_tx1320_virtualmedia_ipxe_cd_hii_raid10_10run.md`:
- 環境情報テーブル
- **反復実行ログ**テーブル: run / RAID Clear (成否・所要・再試行) / deploy 再試行 / install 所要 / 完了判定 / SSH 到達 / RAID10 健全性 / 失敗モード
- run ごと詳細（埋め込みスクリーンショット）
- **RAID Clear Configuration 手順 再現性 総合判定**（10 回の成否・所要分布・座標/タイミングの安定性）
- 10 回サマリ統計（成功率・USB redirector 劣化トレンド）
- スキル/プリミティブ更新ノート（kvmlib.py 昇格の可否判断含む）

## リスクと graceful degradation

- **HII 確認ダイアログの非決定性**: report 明記の通り固定シーケンスは脆い。**per-key + screenshot 検証ループ**で毎回画面を読む。
  フォーカス喪失は再試行で吸収。10 run で安定座標/タイミングを確定させ SKILL に反映。Clear は工程が短く RAID10 構築より低リスク。
- **USB redirector 累積劣化（既知）**: deploy driver 内 ServiceRestart で緩和。CD 未提示なら 1 回だけ再 deploy。トレンド記録。
- **BIOS POST 99 stuck（PSU cold reset = 物理操作で自動化不可）**: OEM-shot が POST 99 凍結 + 約 5 分進行なしで検知 →
  **即座にハードブロッカーとしてユーザに提示しループ一時停止**。
- **disk 名前提（/dev/sda）**: storcli 作成 VD が megaraid_sas で /dev/sda に出る前提（既往実績あり）。run 1 の G で `lsblk` 実機確認し、
  違えば config `disk` を訂正してから run 2 以降へ。
- **BMC screenshot 連打で無応答**: oem-shot は poll/retry 付き。deploy curl と時間分離。
- **KVM canvas 黒画 artifact**: boot 失敗の証拠に使わない。SOL printk と OEM 真 VGA のみ信頼。

## 所要時間の見込み（ユーザ周知）

1 run = HII Clear Configuration（per-key 検証で 5–10 分）+ install（13–26 分）+ disk boot/検証（5–10 分）≒ **25–45 分**。
10 run で **概ね 5–8 時間規模**の長時間自律タスク。早い run で Clear 手順を堅牢化（プリミティブ昇格）し後半を高速化する。
POST 99 等の物理ブロッカー時はユーザに即エスカレーション。

## 検証（end-to-end）

各 run の G で `storcli64 /c0/vall show` = RAID-10 Optimal 1.635TB（storcli 作成）+ `ssh root@<eno2-ip>` 到達を
もって成功とする。10 run 完了後、サマリ統計・Clear 手順再現性結論・スキル diff
（irmc-bios-raid / pxe-deploy / kvmlib.py）をユーザに提示。commit はユーザ承認後。

## 注意事項（CLAUDE.md 準拠）

- スクリプトは必ず `./` 付き相対パス、一時ファイルは `tmp/<sid>/`、`2>&1`/パイプ/`<` リダイレクトは付けない。
- 状態変更は `./oplog.sh` 経由。training-tx1320 は PVE クラスタ非参加のため `pve-lock.sh` 不要。
- SSH/SCP は `-F ssh/config` を付け、静的 IP（dark-net 10.254.254.x）を使う。

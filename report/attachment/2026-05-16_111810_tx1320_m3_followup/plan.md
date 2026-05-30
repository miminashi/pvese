# TX1320 M3 後続作業 — RAID10 構成 + Virtual Media 自動化 + preseed install + OS install

**親レポート**: [report/2026-05-16_095827_tx1320_m3_add.md](../../projects/pvese/report/2026-05-16_095827_tx1320_m3_add.md)
**Issue**: #67 の後続作業（新 issue を立てる）
**対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)

## Context

前セッションで TX1320 M3 / iRMC S4 の対応機種登録は完了 (Issue #67, report 2026-05-16_095827)。
- `bmc_type: irmc` 導入 + `scripts/bmc-power.sh` 改修（環境変数 `BMC_SCHEME` / `BMC_CURL_OPTS` / `POWER_ON_RESET_TYPE`）
- `config/training_tx1320.yml` + ドキュメント整備 + memory + `irmc-bios-raid` skill (手動ガイドのみ)
- SOL 利用可否確定（要 `sol payload enable 2 4`）

未完了は以下:
1. **RAID10 実構成** — HW RAID10 で SAS HDD 900GB × 4 を VD0 化（手動 or 自動化）
2. **Virtual Media 自動マウント・boot のスクリプト化**（`irmc-virtualmedia.sh` 新規）
3. **preseed 自動 install (`os-setup` スキル相当) の iRMC 対応**
4. **Debian 13 + Proxmox VE 9 の OS インストール** (standalone, cluster 非参加)
5. DHCP IP 確定後に `ssh/config` へ `Host tx1320` 追記
6. `config/training_tx1320.yml` の `disk` を実値に上書き

**ユーザ方針** (本セッション):
- スコープ: 「RAID10 構成から全部やる」
- RAID10: 「Playwright + HTML5 KVM 自動化に挑戦」
- 複数セッション必須前提、収まらなければレポートに引き継ぎ事項を記載

**前セッションからの追加調査結果**:
- iRMC Web UI は **Cookie ベース form login 必須** (Basic Auth では Console Redirection に到達不可)
- HTML5 KVM canvas は noVNC 系で Playwright で操作可能性が高い（Tier 1 プロトタイプで検証）
- Fujitsu OEM VirtualMedia (`/Systems/0/Oem/ts_fujitsu/VirtualMedia`) は SMB 専用、CDImage 2 スロット、`RemoteMountEnabled: true`、PATCH で設定 → 自動 mount
- 既存 SMB share: `10.1.6.1:/var/samba/public` (`smb_host` + `smb_share_path` = `\public`)
- `scripts/os-setup-phase.sh` は BMC 非依存（platform dispatch は `os-setup/SKILL.md` 内）
- `scripts/generate-preseed.sh` は %%PLACEHOLDER%% awk 置換、ttyS1 ハードコード → serial_unit から動的化が必要

## 進め方の全体方針

- 段階的にコミット可能なまとまりで進める（1 段階完了ごとに oplog + 動作確認 + commit）
- 各段階は前段階の動作確認を前提にする
- **本セッションで全完了を目標としない**。途中まででも `report/` に「引き継ぎ事項」をきっちり書いて次セッションへバトン
- 失敗・想定外があれば即停止してユーザ確認 → 方針再考
- 全状態変更操作は `./oplog.sh` 経由

## Phase A: Virtual Media 自動化 (`irmc-virtualmedia.sh` 新規) — 完了

実装の詳細はメインレポート本文を参照。

## Phase B: irmc-kvm-screenshot.py 新規 — 完了

## Phase C: irmc-kvm-interact.py 新規 — 完了

## Phase D: RAID10 構成 — frame refresh 課題 + RAID Util メニュー位置未確定で部分実装、手動依頼に切替

## Phase E: preseed install スキル拡張 — generate-preseed.sh + config の最小修正のみ完了 (SKILL.md 拡張は次セッション)

## Phase F: Debian + PVE OS インストール — Phase D, E 完了が前提で次セッション

## Phase G: クロージング — 本レポート作成

(各 Phase の詳細・未完了項目・引き継ぎ事項はメインレポート本文 `2026-05-16_111810_tx1320_m3_followup.md` を参照)

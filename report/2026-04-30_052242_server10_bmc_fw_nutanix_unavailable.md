# 10号機 (Nutanix NX-1065-G5) BMC FW: Nutanix 純正 FW 入手調査 / 現状維持判断レポート

- **実施日時**: 2026年4月30日 05:00 JST 〜 05:22 JST
- **対象 Issue**: #50 「10号機 BMC FW: Nutanix 純正 FW 入手不可、現状維持判断」

## 添付ファイル

- [実装プラン](attachment/2026-04-30_052242_server10_bmc_fw_nutanix_unavailable/plan.md)
- 関連レポート: [BMC FW アップデート試行 (2026-04-30 04:27)](2026-04-30_042725_server10_bmc_fw_update.md)
- 関連レポート: [10号機追加 (2026-04-30 02:31)](2026-04-30_023103_add_server10_x10drt_p.md)

## 結論サマリ

- **Nutanix 純正 BMC FW (NX-1065-G5 用) は、本プロジェクト環境からは入手不可**と確定
- 配布元は `portal.nutanix.com` の認証ゲート内のみ。アカウント作成には block / software シリアル番号と顧客企業ドメインメールが必須で、本プロジェクト (Nutanix サポート未契約のラボ) は要件を満たさない
- LCM (Life Cycle Manager) 経由も AOS の Controller VM が必要で、Proxmox VE 環境では使えない
- 公開ミラーや第三者の直接配布も発見できず (有用そうな第三者ブログ `virt4dummies.com` は domain expired、`honeypot.tech` は 403)
- ユーザー判断: **Option A (現状維持) を採択**。BMC FW 3.65 のまま運用継続
- BMC は本タスクで一切変更せず (read-only 確認のみ)。`mc info`, `chassis status`, `user list 1` で健全性を最終確認済み

## 前提・目的

### 背景

[2026-04-30 04:27 のレポート](2026-04-30_042725_server10_bmc_fw_update.md) で、Supermicro 公式 BMC FW 3.94 を AlUpdate v2.08 経由で 10号機に適用したが、Nutanix OEM の保護機構により silently reject され FW は 3.65 のままだった。残タスクとして「Nutanix Foundation / Phoenix / Portal 経由で OEM 専用 FW を取得して再試行」が挙げられていた。

### 目的

Nutanix 純正 BMC FW (NX-1065-G5 用) が**一般入手可能か**を調査し、入手できれば AlUpdate / Web UI 等で再アップデートを試行する。

### 前提条件

- 本プロジェクトは Nutanix サポート契約を持たないラボ環境
- ローカルマシンからインターネット接続可能
- WebSearch / WebFetch ツールが利用可能 (ただし `web.archive.org` はブロック)
- 状態変更操作 (FW 適用) はユーザー判断後にのみ実施

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | 10号機 ayase-web-service-10 |
| ハードウェア | Nutanix NX-1065-G5 (Board: Supermicro X10DRT-P-G5-NI22) |
| BMC IP | 10.10.10.30 (Static, /8) |
| BMC ユーザ | claude (index 4, ADMINISTRATOR) |
| BMC FW (現状) | 3.65 (前回タスクと同じ、変更なし) |
| 適用試行候補 | Nutanix 純正 FW (NX-1065-G5 用、認証ゲート内) |
| 設定ファイル | `config/server10.yml` |

## 再現方法

### Step 1: 入手経路の網羅的探索 (WebSearch / WebFetch)

以下のパスを順次調査:

```
WebSearch:
  "Nutanix NX-1065-G5 BMC firmware download portal"
  "Nutanix Foundation BMC firmware NX G5 download public"
  "Nutanix LCM BMC firmware bundle X10DRT-P NX-1065-G5"
  "BMC_X10AST2400" Nutanix OEM firmware "stripped" OR "release.smc"
  "lcm_darksite_firmware_nx" download direct URL bundle file
  "Nutanix portal account requirements firmware download contract"

WebFetch:
  https://portal.nutanix.com/page/downloads/list
  https://portal.nutanix.com/kb/2896
  https://download.nutanix.com/
  https://next.nutanix.com/blog-40/how-to-manually-upgrade-the-bmc-bios-14613
  https://next.nutanix.com/installation-configuration-23/bmc-firmware-version-is-outdated-how-to-update-the-bmc-firmware-6302
  https://next.nutanix.com/how-it-works-22/manual-firmware-updates-38354
  https://virt4dummies.com/nutanix/firmware-upgrade-g5-nodes-bios-bmc/
  https://www.honeypot.tech/?p=1428
```

### Step 2: BMC 現状確認 (read-only)

```sh
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 mc info
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 user list 1
```

### Step 3: 課題追跡

```sh
./issue.sh add "10号機 BMC FW: Nutanix 純正 FW 入手不可、現状維持判断" --label ipmi --label infra
./issue.sh start 50 --owner noble-kernighan
./issue.sh verify 50
./issue.sh done 50 --report report/2026-04-30_052242_server10_bmc_fw_nutanix_unavailable.md
```

## 検証結果

### Step 1: 入手経路の網羅的探索 — ❌ すべて入手不可

| 経路 | 結果 | 根拠 |
|------|------|------|
| Nutanix Portal (`portal.nutanix.com/page/downloads/list`) | ❌ ログイン必須 | WebFetch でアクセスすると "Nutanix Support & Insights" のメタデータのみ表示。本文は認証ゲート内 |
| `download.nutanix.com` (root) | ❌ 403 Forbidden | WebFetch で 403。ディレクトリリストなし、認証必須 |
| LCM Dark Site Bundle (`lcm_darksite_firmware_nx_<ver>.tar`) | ❌ ポータル認証必須 | 公式手順 (Dark Site Guide v2.7) でも「ポータルからダウンロード → 自前 web サーバにホスト」する想定。直接 URL は非公開 |
| KB 2896 (Manual BMC Upgrade Guide) | ❌ ログイン必須 | KB 本文は portal.nutanix.com 配下で要認証 |
| Nutanix CE (Community Edition) | ❌ BMC FW は含まれない | CE は AOS ソフトウェアのみ。BMC firmware は OEM ハードウェア層で別配布 |
| Nutanix アカウント作成 (`my.nutanix.com`) | ❌ Serial number 必須 | 「block or software-only serial number」と顧客企業ドメインメールが必須 (cf. Nutanix Community 投稿: `next.nutanix.com/how-it-works-22/new-users-on-the-team-how-do-we-give-them-portal-access-37210`) |
| LCM 経由 (CVM 上で実行) | ❌ 利用不可 | LCM は AOS の Controller VM で動作。本環境は Proxmox VE で AOS 未導入 |
| コミュニティ第三者ブログ | ❌ 直接 URL なし | `virt4dummies.com` は domain expired (301 to expireddomains.com)、`honeypot.tech` は 403、Mordor.world (CE 2.0 + LCM の記事) は SSL 証明書エラーで取得不可。いずれの言及記事も最終的にダウンロード元として portal.nutanix.com を指す |
| Wayback Machine | ❌ アクセス不可 | Claude Code の WebFetch は `web.archive.org` ブロック |
| Supermicro 公式 (`supermicro.com`) | ⚠️ 取得可だが OEM rejection 確定 | 前回タスク (`report/2026-04-30_042725_server10_bmc_fw_update.md`) で取得した stock FW 3.94 は AlUpdate v2.08 で適用したが silent reject された |

#### 推定される配布制限の理由

- Nutanix NX シリーズはサポート契約に紐づくハードウェアで、FW は契約済み顧客 (シリアル登録あり) にのみ提供される
- 本プロジェクトはラボ目的で Nutanix サポート契約を持たない
- LCM Dark Site も「ポータルからダウンロード → 自前 web サーバにホスト」する設計で、初手のダウンロードは認証必須

### Step 2: BMC 現状確認 — ✅ 健全 (前回と同状態)

```text
$ ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 mc info
Device ID                 : 32
Firmware Revision         : 3.65         <- 前回タスクと同じ、変化なし
IPMI Version              : 2.0
Manufacturer Name         : Super Micro Computer Inc.
Product Name              : X10DRT-P

$ ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status
System Power         : off                <- 前回 Off のまま
Power Restore Policy : previous

$ ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 user list 1
ID  Name      Callin  Link Auth  IPMI Msg  Channel Priv Limit
2   ADMIN     false   false      true      ADMINISTRATOR
3   root      true    false      true      ADMINISTRATOR
4   claude    true    false      true      ADMINISTRATOR    <- 健在 (index 4)
```

副作用なし。BMC は前回タスク終了時の状態を完全に保持している。

## ユーザー判断と採択方針

ユーザーに以下の選択肢を提示し、AskUserQuestion で確認:

| Option | 内容 | 結果 |
|--------|------|------|
| A | **現状維持** (FW 3.65 のまま運用継続) | ✅ 採択 |
| B | Web UI 経由で Supermicro 3.94 を再試行 (前回未試行経路) | 不採択 |
| C | ユーザーが Nutanix Portal アカウント取得後 FW を別途用意 | 不採択 (今回はトリガーなし) |
| D | HPM.1 / JTAG 等の別ベクトルでの強制適用 | 不採択 (ブリックリスク) |

採択理由:

1. 10号機の運用上、BMC FW 3.65 で実害なし
2. ラボ環境のため、BMC FW 更新の緊急性は低い
3. Web UI 経由の再試行 (Option B) は silent reject 再現の可能性が高く、新情報の期待値が低い
4. 別ベクトルでの強制適用は BMC ブリックリスクがあり本タスクのスコープ外

## 副作用と現状

- **副作用なし** — 本タスクで BMC への状態変更操作は一切実施せず (調査と read-only 確認のみ)
- 10号機 BMC は前回タスク終了時 (`mc info` で FW 3.65, Power Off, claude ユーザ index 4) と完全に同状態を保持
- LINSTOR 未参加・OS 未セットアップという 10号機の運用ステータスにも変更なし

## 再試行のトリガー条件 (将来タスク)

以下のいずれかが満たされた時点で本タスクを reopen / 新規 issue 起票して再試行:

1. **Nutanix Portal アカウント取得**: ユーザーが Nutanix と契約 (有償/評価ライセンス含む) し、`my.nutanix.com` でシリアル登録済みアカウントを取得した場合
2. **Nutanix サポートからの直接提供**: Nutanix 営業/サポート経由で NX-1065-G5 用 BMC FW (例: `BMC_X10AST2400-NX1065G5-<ver>.bin`) を入手できた場合
3. **OEM FW のリーク / 第三者公開**: コミュニティで公式に検証可能な OEM FW が公開された場合 (公式手順から外れるため慎重判断要)
4. **AOS インストール**: 10号機を Proxmox VE から AOS (Nutanix CE 含む) に切り替えた場合 → LCM 経由で BMC 更新可能

## 関連ファイル

### 修正なし (参照のみ)

- `config/server10.yml` — 10号機設定
- `scripts/bmc-power.sh`, `scripts/bmc-session.sh`, `scripts/bmc-kvm-screenshot.py` — Phase A 動作確認済み
- `tmp/157391a8/` — 前回タスクの成果物 (FW zip / 抽出済み bin / AlUpdate / ラッパスクリプト) を温存。Option B/C 採用時の即時再利用に備える

### 新規作成

- `report/2026-04-30_052242_server10_bmc_fw_nutanix_unavailable.md` (本ファイル)
- `report/attachment/2026-04-30_052242_server10_bmc_fw_nutanix_unavailable/plan.md` (実装プラン添付)
- `tmp/noble-kernighan/` (本セッション作業ディレクトリ、生成物なし)

### メモリ更新

- `server10_nutanix_oem.md` に「Nutanix 純正 BMC FW は portal.nutanix.com 経由でしか入手できず、本プロジェクトでは入手不可」を追記し、再試行トリガー条件を明記

## 参考資料

公開情報のみ:

- [Nutanix Support & Insights (downloads list)](https://portal.nutanix.com/page/downloads/list) — 要認証
- [Manual BMC Upgrade Guide (KB 2896)](https://portal.nutanix.com/kb/2896) — 要認証
- [How to Manually Upgrade the BMC & BIOS (Nutanix Community)](https://next.nutanix.com/blog-40/how-to-manually-upgrade-the-bmc-bios-14613) — 公開
- [Manual Firmware Updates (Nutanix Community)](https://next.nutanix.com/how-it-works-22/manual-firmware-updates-38354) — 公開
- [Fetching LCM Firmware Update Bundles with Direct Upload](https://portal.nutanix.com/page/documents/details?targetId=Life-Cycle-Manager-Dark-Site-Guide-v2_7:Fetching+LCM+Firmware+Update+Bundles+with+Direct+Upload) — 要認証
- [Supermicro X10DRT-P BMC ダウンロードページ](https://www.supermicro.com/en/support/resources/downloadcenter/firmware/MBD-X10DRT-P/BMC) — 公開、ただし stock FW は Nutanix OEM に silent reject される

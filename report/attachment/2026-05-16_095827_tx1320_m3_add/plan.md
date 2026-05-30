# TX1320 M3 (Fujitsu PRIMERGY / iRMC S4) を対応機種に追加 + BIOS/RAID skill 化 + RAID10 構成

## Context

- 対象: Fujitsu PRIMERGY TX1320 M3 が 1 台、`10.254.254.9` (BMC: iRMC S4、`claude` / `Claude123`) に設置されたトレーニング用マシン
- 物理構成: **HW RAID コントローラ + SAS HDD 900GB × 4 本** が装着済み (ユーザ確認済み) → **RAID10 で構成**（実効容量 ≒ 1.8 TB）
- ユーザ意図:
  - pvese プロジェクトの「対応機種」一覧に新規ベンダー (Fujitsu / iRMC) を追加する
  - **BIOS / RAID コントローラの操作方法を調査し、skill 化する**
  - **本セッションでは RAID10 構成まで** を完了させる
  - **一時設置 / クラスタ非参加** — Region A / B の PVE クラスタにも LINSTOR にも join しない、独立した単独 PVE
- 確認済みスコープ (AskUserQuestion 結果 + 追加要求):
  - 自動化対応範囲は「config + ドキュメント + 電源操作 (最小)」+ 「BIOS / RAID 操作の skill 化」+ 「RAID10 構成実施」
  - **OS インストール (Debian + PVE)・Virtual Media / preseed install 自動化スクリプトは次セッションで実施予定** (本セッションスコープ外)
  - ネットワークは DHCP 任せ: `192.168.33.0/24` (インターネット側) と `10.254.254.0/24` (実体は `10.0.0.0/8` 内サブネット) が割当される
  - issue 登録 + 完了後レポート作成（CLAUDE.md ルール準拠）
- 事前調査結果 (10.254.254.9 への到達確認):
  - HTTP は応答 (`Server: FUJITSU ServerView iRMC S4 Webserver`)、HTTPS は古い DH 鍵で `curl` 困難
  - Redfish 1.0.5 が HTTP で応答 (`http://10.254.254.9/redfish/v1/`、Fujitsu OEM 拡張あり)
  - **IPMI LAN+ は RAKP1/RAKP2 で認証失敗**（ユーザ index 不明 or IPMI ポート閉塞 — 実機調査要）

## 命名・配置の前提

| 項目 | 値 | 備考 |
|------|----|------|
| config ファイル | `config/training_tx1320.yml` | ユーザ指定 |
| `bmc_type` 新値 | `irmc` | 既存は `supermicro` / `idrac` |
| ホスト名（OS 側、将来用） | `training-tx1320` | クラスタ非参加なので `ayase-web-service-N` 連番から外す（OS install 時に使う想定値、本セッションでは未設定） |
| SSH エイリアス | (本セッションでは追加しない) | OS install 後に DHCP IP が確定してから次セッションで追記 |
| サーバ番号 | 振らない | クラスタ・LINSTOR 設定に紛れ込ませないため |
| 新 skill 名 | `irmc-bios-raid` | BIOS と RAID を一体で扱う（既存 `bios-setup` / `perc-raid` 命名と並列） |

> skill を `irmc-bios` と `praid-raid` に分割するパターンも検討したが、TX1320 M3 1 台のための skill としては小さく済むため一体型を提案。Phase 2 の実機調査で操作プロトコルが BIOS と RAID で分かれる場合は分割する。

## 実装手順

### Phase 1: Issue 登録

```sh
./issue.sh add "TX1320 M3 (Fujitsu PRIMERGY / iRMC S4) を対応機種に追加 + BIOS/RAID skill 化 + RAID10 構成" \
  --label infra --label doc --label script --label ipmi
./issue.sh start <id> --owner streamed-parrot
```

description には以下を含める:
- 対象 BMC: `10.254.254.9` (claude/Claude123)
- ホスト名 (将来): `training-tx1320`
- 一時設置 / クラスタ・LINSTOR 非参加
- 物理ディスク: 900GB × 4 → RAID10
- 本セッションスコープ: config + docs + bmc-power.sh の iRMC S4 対応 + irmc-bios-raid skill 新設 + RAID10 構成
- 次セッション予定: Virtual Media / preseed install 自動化 + OS インストール

### Phase 2: 実機調査（OS install 前の前提固め）

各調査結果は `tmp/<sid>/probe-*.log` に保存。

#### 2-1. ネットワーク・プロトコル
- HTTPS 接続性 (default / TLS<=1.2 / SECLEVEL=0)
- Redfish Systems パス
- 電源 Reset アクションの AllowableValues
- IPMI LAN+ 認証 + SOL 利用可否確定 (本セッション必須)

#### 2-2. KVM/BIOS/RAID 操作プロトコル
- iRMC S4 KVM 方式特定 (HTML5 / Java / 独自)
- Redfish BIOS/Storage 操作可否
- HW RAID コントローラ機種特定
- 既存ディスク + 論理セクタサイズ確認

#### 2-3. probe-summary.md 作成

### Phase 3: scripts/bmc-power.sh の iRMC S4 対応

```sh
: "${BMC_SCHEME:=https}"
: "${BMC_CURL_OPTS:=}"
: "${POWER_ON_RESET_TYPE:=On}"

redfish_get/post/patch にて
curl -skL ${BMC_CURL_OPTS} -u "${user}:${pass}" "${BMC_SCHEME}://${bmc_ip}${path}"
```

iRMC: `BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' POWER_ON_RESET_TYPE=PushPowerButton`

`get_system_path()` の sed parse は iRMC が JSON `/` を `\/` でエスケープするため `tr -d '\\'` で正規化してから処理。

### Phase 4: config/training_tx1320.yml 作成

DHCP, bmc_type=irmc, RAID10, クラスタ非参加, OS 未インストール想定の最小フィールド。

### Phase 5: README.md / CLAUDE.md 更新

対応済みハードウェアに iRMC S4 セクション、サーバ一覧に行追加、skill 一覧に追記。

### Phase 6: memory/training_tx1320.md 追加

iRMC S4 の落とし穴 (HTTPS DH, ResetType に On 不在, JSON `\/` エスケープ, Storage 空, Bios.Attributes 空, eLCM ライセンスなし, SOL payload enable 必須) を記録し MEMORY.md にインデックス追記。

### Phase 7: irmc-bios-raid skill 新設

`.claude/skills/irmc-bios-raid/SKILL.md` + `reference.md`。サブコマンド: info / power / bios enter|screenshot|backup|restore (Redfish 自動) / raid status|create-r10|delete (手動ガイド)。

### Phase 8: RAID10 構成

- 8-0 (条件付): セクタサイズ 520B/528B なら OpenWrt rescue で sg_format
- 8-1: HW RAID パターン (BIOS RAID Configuration Utility 経由)
- 8-2 (条件付): 8-0 が成功したら openwrt-rescue skill 化

### Phase 9: 検証

- bmc-power.sh status で iRMC 動作 + 既存機種で回帰なし
- SOL 利用可否確定
- RAID10 VD が Optimal で表示

### Phase 10: レポート + Issue クローズ

`report/yyyy-mm-dd_hhmmss_tx1320_m3_add.md` 作成、plan + probe-summary 添付、issue.sh done。

## 修正・新規ファイル一覧

| 種別 | パス | 内容 |
|------|------|------|
| 新規 | `config/training_tx1320.yml` | TX1320 M3 設定 |
| 修正 | `scripts/bmc-power.sh` | BMC_SCHEME / BMC_CURL_OPTS / POWER_ON_RESET_TYPE 環境変数化 |
| 修正 | `README.md` | 対応機種・サーバ一覧・skill 一覧 |
| 修正 | `CLAUDE.md` | サーバ一覧・機種別注記 |
| 新規 | `memory/training_tx1320.md` | iRMC S4 操作知見 |
| 修正 | `memory/MEMORY.md` | インデックス追記 |
| 新規 | `.claude/skills/irmc-bios-raid/SKILL.md` | skill 定義 |
| 新規 | `.claude/skills/irmc-bios-raid/reference.md` | リファレンス |
| 新規 (条件付) | `scripts/irmc-kvm-interact.py` | HTML5 KVM 自動操作 |
| 新規 (条件付) | `.claude/skills/openwrt-rescue/` | sg_format 成功時のみ |
| 新規 | `report/...` | 完了レポート |

## スコープ外 (次セッション予定)

- Virtual Media 自動マウント
- preseed 自動 install
- Debian + PVE インストール
- ssh/config への Host tx1320 追記
- config の disk 確定

## リスク・代替案

- IPMI / SOL 不可 → KVM 目視
- Redfish 電源パス違い → bmc_type=irmc 用 switch
- KVM が Java/独自 → Redfish のみで縮退
- BIOS/Storage が read-only → KVM 経由 / OS 起動後 storcli
- 物理ディスク 520B/528B → OpenWrt rescue で sg_format
- iRMC が .img を受理しない → SMB 経由
- openwrt-rescue skill 化見送り (該当しない or 失敗時)

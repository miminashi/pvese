# 10号機 BMC FW: Nutanix 純正 FW 入手調査と次アクション

## Context

10号機 (Nutanix NX-1065-G5 OEM / Supermicro X10DRT-P-G5-NI22) の BMC FW を 3.65 → 3.94 に更新する前回タスク (`report/2026-04-30_042725_server10_bmc_fw_update.md`) で、Supermicro 公式 FW は AlUpdate v2.08 によって "Update Complete" まで進行したものの、Nutanix OEM の保護機構によりフラッシュコミットが silently reject され FW は 3.65 のままだった。残タスクとして「Nutanix Foundation / Phoenix 経由で OEM 専用 FW を取得して再試行」が挙げられていた。

本タスクのゴールは「**Nutanix 純正 BMC FW (NX-1065-G5 用) が入手可能かを調査し、見つかればアップデートを試行する**」こと。

---

## 調査結論 (2026-04-30)

### Nutanix 純正 BMC FW は一般入手不可

複数経路で公開ダウンロード URL を探索したが、**認証なしで NX-1065-G5 用 BMC FW を取得する手段は確認できなかった**。

#### 主要な確認事項

| 経路 | 結果 | 根拠 |
|------|------|------|
| Nutanix Portal (`portal.nutanix.com/page/downloads/list`) | ❌ ログイン必須 | アクセスすると "Nutanix Support & Insights" のみ表示。WebFetch でも本文取得不可 |
| `download.nutanix.com` 直接 | ❌ 403 Forbidden | 全パスで 403。認証ゲート |
| LCM Dark Site Bundle (`lcm_darksite_firmware_nx_<ver>.tar`) | ❌ ポータル認証必須 | 公式手順 (Dark Site Guide v2.7) もポータル経由ダウンロードのみ。直接 URL は非公開 |
| KB 2896 (Manual BMC Upgrade Guide) | ❌ ログイン必須 | KB 本文は portal.nutanix.com 配下で要認証 |
| Nutanix CE (Community Edition) | ❌ BMC FW は含まれない | CE は AOS ソフトウェアのみ。BMC firmware は OEM ハードウェア層で別配布 |
| Nutanix アカウント作成 (`my.nutanix.com`) | ❌ Serial number 必須 | アカウント作成には block / software serial number と顧客企業ドメインメールが要求される |
| LCM 経由 (CVM 上で実行) | ❌ 利用不可 | LCM は AOS の Controller VM で動作。本環境は Proxmox VE で AOS 未導入 |
| コミュニティ (next.nutanix.com / 第三者ブログ) | ❌ 直接 URL なし | 手順説明はあるが具体的なダウンロード URL は portal を指すのみ。virt4dummies.com (有用そうな記事) は domain expired、honeypot.tech は 403 |
| Wayback Machine | ❌ アクセス不可 | Claude Code 環境からは web.archive.org にアクセス不可 |
| Supermicro 公式 (`supermicro.com`) | ⚠️ 取得可だが OEM rejection 確定 | 前回タスクで取得した stock FW 3.94 は Nutanix OEM に silent reject された |

#### 推定される配布制限の理由

- Nutanix NX シリーズはサポート契約に紐づくハードウェア。FW は契約済み顧客 (シリアル登録あり) にのみ提供される
- 本プロジェクトはラボ目的で Nutanix サポート契約を持たない
- LCM Dark Site も「ポータルからダウンロード → 自前 web サーバにホスト」する想定で、初手のダウンロードは認証必須

### 結論: 本タスクで「自動的に取得して適用」は不可能

入手不可の場合の指示は受けていないため、**ここで一旦ユーザーに判断を仰ぐ**。

---

## ユーザー判断: 現状維持 (Option A) で確定

**採択方針**: BMC FW 3.65 のまま運用継続。Nutanix 純正 FW 入手経路 (Nutanix Portal / Foundation / LCM) が利用可能になるまで保留する。

理由:
1. 10号機の運用上、BMC FW 3.65 で実害なし (`mc info`, `fru print`, `lan print`, CGI, Redfish, KVM すべて健全)
2. ラボ環境のため、BMC FW 更新の緊急性は低い
3. Web UI 経由の再試行 (Option B) は silent reject 再現の可能性が高く、副作用なしとはいえ得られる新情報は限定的
4. 別ベクトルでの強制適用 (HPM.1, JTAG 等) は BMC ブリックリスクがあり本タスクのスコープ外

検討したが採択しなかった選択肢:
- **Option B (Web UI 経由再試行)** — silent reject 再現の確率が高く、新情報の期待値が低い
- **Option C (ユーザーが FW を別途用意)** — Nutanix Portal アクセス権が現時点でない
- **Option D (HPM.1 / JTAG 等の別ベクトル)** — ブリックリスクあり、却下

---

## 実行ステップ (Option A: 現状維持)

1. **issue 起票**: `./issue.sh add "10号機 BMC FW: Nutanix 純正 FW 入手不可、現状維持判断" --label ipmi --label infra`
2. **issue start → verify**: `./issue.sh start <id> --owner <session>` → `./issue.sh verify <id>`
3. **レポート作成**: `report/<TZ=Asia/Tokyo date>_server10_bmc_fw_nutanix_unavailable.md`
   - 本プランファイルを `attachment/.../plan.md` にコピー
   - 調査結果を本文に転記
   - 次回再試行のトリガー条件 (Nutanix サポート契約取得時 / Nutanix Portal アカウント取得時) を明記
4. **メモリ更新**: `server10_nutanix_oem.md` に下記を追記
   - "Nutanix 純正 BMC FW は portal.nutanix.com 経由でしか入手できず、サポート契約・シリアル番号登録が必須。本プロジェクトでは入手不可"
   - "Supermicro 公式 FW は AlUpdate / (未試行: Web UI) で silent reject されることが確定済み"
   - "BMC FW 3.65 のまま運用継続。更新は Nutanix Portal アカウント取得まで保留"
5. **issue done**: `./issue.sh done <id> --report <path>`

---

## 重要な参照ファイル (修正なし、参照のみ)

- `/home/ubuntu/projects/pvese/CLAUDE.md` — プロジェクトルール
- `/home/ubuntu/projects/pvese/REPORT.md` — レポート作成ルール
- `/home/ubuntu/projects/pvese/ISSUE.md` — 課題管理ルール
- `/home/ubuntu/projects/pvese/report/2026-04-30_042725_server10_bmc_fw_update.md` — 前回タスクのレポート
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/server10_nutanix_oem.md` — Nutanix OEM メモリ
- `/home/ubuntu/projects/pvese/config/server10.yml` — 10号機設定
- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh`, `bmc-session.sh`, `bmc-kvm-screenshot.py` — Phase A 動作確認済み
- `/home/ubuntu/projects/pvese/tmp/157391a8/` — 前回タスクの成果物 (FW zip / 抽出済み bin / AlUpdate / ラッパスクリプト)

## 検証方法

レポート + メモリ更新が完了していること:

```sh
ls report/2026-04-30_*_server10_bmc_fw_nutanix_unavailable.md
./issue.sh show <id>   # status=done になっていること
```

メモリ確認 (Read ツール):
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/server10_nutanix_oem.md` に下記が追記されていること
  - "Nutanix 純正 BMC FW は portal.nutanix.com 経由でしか入手できず、サポート契約・シリアル番号登録が必須"
  - "本プロジェクトでは入手不可、BMC FW 3.65 のまま運用継続"
  - 再試行のトリガー条件 (Nutanix Portal アカウント取得時)

BMC 状態の維持確認 (副作用なしの最終確認):

```sh
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 mc info       # FW Revision = 3.65
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status # Power = Off (変化なし)
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 user list 1    # claude (index 4) 健在
```

> **注**: 本タスクでは BMC への状態変更操作は行わない。上記は「現状維持の確認」のみで、`pve-lock.sh` 不要。

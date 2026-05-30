# TX1320 M3 RAID10 自動化 — preseed early_command + storcli64 経路で再トライ

## Context

前セッション (`a-goofy-graham`) で iRMC KVM 経由の AVAGO HII (Aptio Setup Utility) 自動化が **dead end 確定**:
- Create Virtual Drive form の "Select RAID Level" (y=128) に Aptio navigation で到達不可 (ArrowUp/Down/Tab/Click/End/PageUp/PageDown の全 9 経路失敗)
- Profile-based VD には Generic RAID 0/1/5/6 のみで RAID 10 不在
- Aptio HII canvas は Tab/Click を一切解さない

**Web 版 Claude の知見が方向転換の決め手**:
- MegaRAID は RAID 10 を「**RAID 1 + Span 2**」として実装 (基本 level: 0/1/5/6 + spans: 10/50/60)
- HII Profile-based に RAID 10 が無いのは仕様 (シンプルウィザード保護)
- **StorCLI (`storcli /c0 add vd type=raid10 ... pdperarray=2`) が最も確実**

**新方針**: iRMC KVM 自動化を完全に放棄し、Debian preseed の `partman/early_command` で storcli64 を Broadcom 公式から wget → RAID 10 作成 → 通常の preseed OS install 続行という **1 ISO・1 boot で完結** する経路に転換する。

**ユーザ選定の方針 (修正後)**:
- storcli 取得: **ローカルマシンで事前取得 → ISO に同梱** (internet wget 経路は DHCP / DNS / Broadcom URL 安定性の 3 重依存があるため除外)。 リスク最小・完全オフラインで実機到達後の failure point ゼロ
- rescue 操作: **シリアル + preseed で自動進入** ≒ preseed の `partman/early_command` で RAID 作成 + 通常 install 続行 (rescue mode を経由しない最短経路)

## 設計の核心

1. **storcli64.deb はローカルマシンで事前取得 → ISO に同梱**:
   - 既存 `tmp/sprightly/install-storcli.sh` のロジックを再利用して Broadcom 公式 zip を一度だけ取得 → unzip → `*Linux*.deb` を `/var/samba/public/storcli64.deb` (永続) と remaster 入力に配置
   - 取得は **ローカルマシンの 1 回限り** (training-tx1320 側からは ISO 内 `/cdrom/storcli64.deb` を読むだけ)
   - URL 失効リスクはローカル取得時に判明 (実機到達後に発覚しない)

2. **OS install と RAID 作成を 1 つの preseed で完結させる**:
   - 既存 `scripts/generate-preseed.sh` に `--with-raid10-storcli` フラグを追加
   - preseed の `partman/early_command` で以下を順次実行:
     1. `dpkg -i /cdrom/storcli64.deb` (もしくは installer 環境の制約で `cp /cdrom/storcli64.deb /tmp/ && dpkg -i /tmp/storcli64.deb`)
     2. `storcli64 /c0/vall delete force` (既存 VD クリア)
     3. `storcli64 /c0/eall/sall show all` で EID:Slot 列挙 → parse
     4. `storcli64 /c0 add vd type=raid10 size=all drives=<EID>:0-3 pdperarray=2 wb ra direct strip=256`
     5. `storcli64 /c0/vall show all` で `RAID-10 / Optl` を assert
   - partman は通常通り `/dev/sda` を partition → install 続行
   - **インターネット・DNS・cifs-utils すべて不要** (DHCP は OS 起動後だけで OK)

3. **既存 `os-setup` スキルと整合**: 新規スクリプトは最小限 (`generate-preseed.sh` 拡張 + 1 wrapper)。 SMB 配置・BMC mount・boot-override・SOL 監視はすべて既存資産を流用。

## Phase 1: storcli64.deb をローカルで事前取得 (~ 10 min)

- ローカルマシンで `tmp/sprightly/install-storcli.sh` のロジックを再利用 (Broadcom 公式 zip → unzip → Linux 用 deb 抽出)
- 取得物を 2 箇所に配置:
  - `/var/samba/public/storcli64.deb` (永続、 将来の再 ISO 構築でも参照可能)
  - ISO remaster 入力用ステージング (`tmp/<session-id>/iso-payload/storcli64.deb`)
- URL 失効時はこの Phase で即 fail (実機側 boot して気付かない設計) — 早期検知が重要
- 既存 ISO `/var/samba/public/debian-13.3.0-amd64-netinst.iso` を remaster base に使う

## Phase 2: `setup-raid10-storcli.sh` を作成 + ISO 同梱用ペイロード準備 (~ 30 min)

- ファイル: `/home/ubuntu/projects/pvese/scripts/setup-raid10-storcli.sh` (新規)
- 内容 (POSIX sh, `set -eu`):
  ```sh
  #!/bin/sh
  set -eu
  DEB=${1:-/cdrom/storcli64.deb}
  LOG=${RAID10_LOG:-/var/log/raid10-setup.log}
  [ -f "$DEB" ] || { echo "[FATAL] storcli64.deb not found at $DEB" >&2; exit 4; }
  dpkg -i "$DEB" >> "$LOG" 2>&1 || in-target dpkg -i "$DEB" >> "$LOG" 2>&1
  SCLI=$(command -v storcli64 || echo /opt/MegaRAID/storcli/storcli64)
  [ -x "$SCLI" ] || { echo "[FATAL] storcli64 not executable" >&2; exit 5; }
  "$SCLI" /c0 show all >> "$LOG" 2>&1
  "$SCLI" /c0/vall delete force >> "$LOG" 2>&1 || true
  EID=$("$SCLI" /c0/eall/sall show | awk '/HDD|SSD/ {split($1,a,":"); print a[1]; exit}')
  [ -n "$EID" ] || { echo "[FATAL] could not parse EID" >&2; exit 6; }
  "$SCLI" /c0 add vd type=raid10 size=all \
    drives=$EID:0,$EID:1,$EID:2,$EID:3 pdperarray=2 \
    wb ra direct strip=256 >> "$LOG" 2>&1
  "$SCLI" /c0/vall show all | tee -a "$LOG" | grep -E 'RAID-?10' \
    || { echo "[FATAL] RAID10 not created" >&2; exit 7; }
  echo "[OK] RAID10 created" >&2
  ```
- 終端コードで失敗内訳を識別 (4=deb missing, 5=storcli not installed, 6=EID parse fail, 7=RAID10 not in output)
- このスクリプトを ISO ルートに同梱 (`/cdrom/setup-raid10-storcli.sh`) + `/var/samba/public/storcli64.deb` と共に `/cdrom/storcli64.deb` も同梱

## Phase 3: `generate-preseed.sh` 拡張 (~ 20 min)

- ファイル: `/home/ubuntu/projects/pvese/scripts/generate-preseed.sh`
- 追加フラグ: `--with-raid10-storcli` (デフォルト off)
- フラグ有効時に挿入する directive:
  ```
  d-i partman/early_command string sh /cdrom/setup-raid10-storcli.sh /cdrom/storcli64.deb
  ```
- 1 行 directive で済むため preseed.cfg 側の複雑度はゼロ (Phase 2 のスクリプト側に全ロジックを閉じ込める)
- console は既存 generate-preseed.sh の `console=ttyS0,115200n8` 機構 (line 74-76) をそのまま使用
- 既存 preseed の他項目 (locale, keymap, partman recipe など) は変更なし

## Phase 4: ISO remaster + SMB 配置 + BMC boot-override + 監視 (~ 20 min)

- preseed 生成: `./scripts/generate-preseed.sh --config config/training_tx1320.yml --with-raid10-storcli --output tmp/<session-id>/preseed-tx1320-r10.cfg`
- ISO remaster: 既存 `scripts/remaster-debian-iso.sh` を拡張 (Phase 7 で追加機能) して以下を ISO ルートに同梱:
  - `preseed.cfg` (生成済)
  - `storcli64.deb` (Phase 1 で取得済)
  - `setup-raid10-storcli.sh` (Phase 2 で作成済)
  - 出力: `tmp/<session-id>/debian-13.3.0-tx1320-r10.iso`
- SMB 配置: `cp tmp/<session-id>/debian-13.3.0-tx1320-r10.iso /var/samba/public/`
- mount: `BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" ./scripts/irmc-virtualmedia.sh config 10.254.254.9 claude Claude123 10.1.6.1 public debian-13.3.0-tx1320-r10.iso`
- 確認: `./scripts/irmc-virtualmedia.sh status ...` で `RemoteMountEnabled=true`
- boot: `BMC_CURL_OPTS="..." BMC_PATCH_REQUIRES_ETAG=1 ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI` → `./oplog.sh ./scripts/bmc-power.sh cycle 10.254.254.9 claude Claude123`
- 監視: `ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol activate` で boot 進行を観察 (preseed の RAID 作成は `setup-raid10-storcli.sh` の stderr が tty に出る)、 同時に `irmc-kvm-screenshot.py` を 30s 間隔で取得して fallback ログとする
- 期待: 5-10 分で RAID 10 作成 + Debian install 完了 → SSH 接続可能

## Phase 5: 検証 (~ 10 min)

- SSH (DHCP IP は SOL ログから取得 or `arp` で探索 — 既存スキル流用): `ssh -F ssh/config tx1320 lsblk` で `/dev/sda` が ~1.6 TB の単一 block device であることを確認 (RAID10 = SAS 900GB × 4 / 2 mirror = ~1.6 TiB)
- `ssh -F ssh/config tx1320 storcli64 /c0/vall show all` で:
  ```
  DG/VD TYPE   State Access Consist Cache sCC  Size      Name
  0/0   RAID10 Optl  RW     Yes     RWBD  -    1.636 TB
  ```
- preseed 失敗時のログ: `ssh ... cat /var/log/raid10-setup.log` (前述の tee ログ)

## Phase 6: 失敗時フォールバック

| トリガ | フォールバック |
|---|---|
| Broadcom URL が dead / HTTPS 失敗 | **Phase 1 で即発覚** (ローカル取得のため)。 ミラー候補: GitHub の sas3-storcli 系 mirror、 旧バージョン (`007.1623.0000.0000.zip`)、 Debian `megacli` パッケージ (古典版、 後述) |
| storcli が SAS3108 認識せず | MegaCLI fallback: `megacli -CfgSpanAdd r10 -Array0[E:0,E:1] -Array1[E:2,E:3] WB RA Direct -strpsz256 -a0` (Debian universe `megacli` パッケージ、 deb 同梱方式は storcli と同じ) |
| EID:Slot 番号が想定外 | `setup-raid10-storcli.sh` の awk parse を緩く (HDD/SSD 両対応 + Slot 番号も検出)、 失敗時は SOL ログから手動 EID 確認 → preseed/script を再生成 |
| `dpkg -i /cdrom/storcli64.deb` が installer 環境で失敗 | `in-target` 経由 (chroot install) で再試行、 もしくは installer 内 busybox で deb の data.tar.xz を展開して `/opt/MegaRAID/storcli/storcli64` 直接配置 |
| ISO mount/boot 失敗 (UEFI/Secure Boot) | Secure Boot 状態を BIOS Setup で確認 (今回は通常 BIOS の Boot Manager 画面で navigate 可能、 Aptio HII と違って key event が届く想定) |
| 全自動化失敗 | **last resort**: ユーザに iRMC KVM Web UI をブラウザで開いてもらい、 マウスで Select RAID Level (y=128) に直接 click → 手動で RAID 10 選択 (~ 5 min、 dead-end report L207-210 で「最終 fallback として有効性高」と評価済) |

## ファイル変更リスト

### 新規作成 (永続化)
- `/home/ubuntu/projects/pvese/scripts/fetch-storcli-deb.sh` — Broadcom 公式 zip → unzip → Linux 用 deb 抽出 → `/var/samba/public/storcli64.deb` に配置 (`tmp/sprightly/install-storcli.sh` を整理して scripts/ 配下に昇格)
- `/home/ubuntu/projects/pvese/scripts/setup-raid10-storcli.sh` — RAID 10 作成 + 検証を行う self-contained sh script (ISO 内 `/cdrom/setup-raid10-storcli.sh` として preseed `partman/early_command` から呼出)
- `/home/ubuntu/projects/pvese/scripts/tx1320-raid10-orchestrate.sh` — Phase 4-5 全体 wrapper (Phase 1 storcli 取得 → preseed 生成 → ISO remaster → SMB 配置 → BMC mount → boot-override → SOL 監視 → SSH 検証)
- `/var/samba/public/storcli64.deb` — Broadcom 公式から取得した Linux 用 deb (Phase 1 出力、 SMB 公開ディレクトリに永続配置)

### 修正
- `/home/ubuntu/projects/pvese/scripts/generate-preseed.sh` — `--with-raid10-storcli` フラグ追加。 セット時に preseed.cfg へ 1 行 directive (`d-i partman/early_command string sh /cdrom/setup-raid10-storcli.sh /cdrom/storcli64.deb`) を挿入
- `/home/ubuntu/projects/pvese/scripts/remaster-debian-iso.sh` — ISO ルートに追加ファイル (`storcli64.deb`, `setup-raid10-storcli.sh`) を同梱する `--include` フラグ追加 (既存 preseed 注入機構の汎用化)
- `/home/ubuntu/projects/pvese/config/training_tx1320.yml` — `raid_setup` セクションを「KVM HII 経路は dead-end、 storcli + preseed 経路で構成」コメントへ書き換え。 RAID 完了後の `disk: /dev/sda` 確定
- `/home/ubuntu/projects/pvese/.claude/skills/irmc-bios-raid/SKILL.md` — `raid create-r10` 行を「🛑 自動化 dead end 確定」から「✅ preseed + storcli ISO 同梱経路で自動化 (KVM HII 経路は廃止)」へ更新。 使用例セクション追加
- `/home/ubuntu/projects/pvese/.claude/skills/os-setup/SKILL.md` — TX1320 用の事前手順「Phase 0: RAID10 構成 (preseed --with-raid10-storcli フラグ + 専用 ISO)」を追記

### DEPRECATED マーキング (削除はしない、 教訓として保存)
- `/home/ubuntu/projects/pvese/scripts/irmc-raid10-create.py` — `# DEPRECATED: KVM HII path dead-end (2026-05-17); use scripts/tx1320-raid10-orchestrate.sh` ヘッダー追記
- `/home/ubuntu/projects/pvese/tmp/iter/iter_11_raid10_commit.py` — 同上 (KVM commit skeleton、 dead-end のため使用不可)
- `tmp/iter/_util.py` の `CURSOR_Y_CREATE_VD_FORM` map — `# DEPRECATED: y=128 unreachable; see report 2026-05-17_101536` コメント追記のみ

## 検証ステップ (end-to-end)

1. `./scripts/generate-preseed.sh --with-raid10-storcli --config config/training_tx1320.yml --output tmp/<sid>/preseed.cfg` — 生成された preseed に `partman/early_command` が含まれる
2. `./scripts/remaster-debian-iso.sh ...` — ISO 出力
3. `./scripts/tx1320-raid10-orchestrate.sh apply` — 全 phase 実行
4. SOL ログに `RAID10 / Optl / 1.6XX TB` が出る (preseed の storcli show 出力)
5. SSH 接続 → `lsblk` で `/dev/sda` 単一 1.6 TB
6. `storcli64 /c0/vall show all` で同上確認
7. (副次) BIOS Setup を KVM で開いて AVAGO HII の VD list に RAID 10 が存在することを screenshot で確認 (証跡)

## リスクと未解決事項

- **Broadcom 公式 URL の長期安定性**: zip ファイル名にバージョン番号が含まれるため、 更新時に URL 変動の可能性。 **Phase 1 (ローカル取得) で即発覚** するため実機到達後に気付かない設計。 fallback URL を SKILL.md に明記
- **storcli の SAS3108 認識**: AVAGO MegaRAID コントローラーの正確な型 (SAS3008 vs SAS3108 vs 別) によって storcli 認識可否が変わる可能性 — Phase 4/5 で初実機検証。 認識しなければ MegaCLI へ即フォールバック
- **preseed `partman/early_command` 失敗時の installer 挙動**: exit 4-7 で installer が "Error" dialog を出すか、 そのまま続行するか未確認。 install dialog navigation が手動になる可能性 → SOL 監視で異常検知時にユーザ通知 (一般的には preseed 失敗は installer fail → fatal で停止する)
- **EID:Slot の動的取得**: AWK parse が `HDD|SSD` keyword に依存するが、 storcli の output format がバージョンで変わる可能性 → `setup-raid10-storcli.sh` に正規表現を緩く書く + parse 失敗時の手動 EID 抽出手順を SKILL.md に追記
- **ISO サイズ**: storcli64.deb (~20 MB) + setup script (~1 KB) を同梱するため Debian netinst (~600 MB) が ~620 MB に増加。 iRMC Virtual Media 上限 (通常 4 GB 程度) には余裕あり
- **既存 dead-end 資産の扱い**: `tmp/iter/iter_0*.py` (KVM 探索試行) は本プランの実装に不要だが、 知見として残す。 削除はせず DEPRECATED マーキングのみ
- **Secure Boot / UEFI mode**: training-tx1320 は既に UEFI 化済 (`config/training_tx1320.yml` で確認)。 Debian netinst は UEFI hybrid なので問題ないはずだが、 Secure Boot 状態は未確認 (Phase 4 で boot 失敗時に BIOS Setup で要確認)

## 代替案 (last resort)

StorCLI preseed 経路が完全失敗した場合:

1. **HII Advanced mode 探索** (~ 15 min): Web Claude が「HII Advanced で Drive Group + Span 設定が可能」と指摘していたが、 前セッションの dead-end (Aptio navigation 全失敗) を考えると期待薄。 ただし、 Create VD form 内の他項目に "Advanced" 切替 item があるかを Y 座標 scan で確認する余地はある
2. **OEM Redfish 探索** (~ 30 min): `/redfish/v1/Oem/ts_fujitsu/...` 配下に RAID 設定 panel があるか scan。 FW 9.08F は old だが念のため
3. **ユーザ手動完遂** (~ 5 min): iRMC KVM Web UI をユーザがブラウザで開き、 Aptio HII でマウス click により Select RAID Level に到達 → 手動で RAID 10 選択 → Drive 4 本選択 → Save。 screenshot を `tmp/<sid>/manual-r10-*.png` で証跡保存

### Critical Files for Implementation

- `/home/ubuntu/projects/pvese/scripts/generate-preseed.sh` — preseed 生成 (核心)
- `/home/ubuntu/projects/pvese/scripts/remaster-debian-iso.sh` — ISO 注入 (Phase 4)
- `/home/ubuntu/projects/pvese/scripts/irmc-virtualmedia.sh` — SMB mount (Phase 4)
- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh` — boot-override + cycle (Phase 4)
- `/home/ubuntu/projects/pvese/tmp/sprightly/install-storcli.sh` — Broadcom URL のリファレンス実装 (Phase 2 のベース)
- `/home/ubuntu/projects/pvese/config/training_tx1320.yml` — SMB host, disk path, RAID 設定の真実源

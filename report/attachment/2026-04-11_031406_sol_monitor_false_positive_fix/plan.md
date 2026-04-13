# sol-monitor false positive 修正 + 7/8/9号機並列回帰テスト

## Context

2026-04-10 の 8 号機 VirtualMedia 復旧テスト
(`report/2026-04-10_172807_server8_vmedia_recovery_test.md`)
で、`scripts/sol-monitor.py` に **critical な設計欠陥** が顕在化した:

- 現状の成功判定は「`PowerState=Off` を検知したら exit 0」のみ
- installer の `INSTALLER_STAGES` キーワードを **1 つも観測していなくても** 成功扱い
- 8 号機では SOL ログに installer 出力 0 件 + 414 回の "Automated Install"
  ブートループ → PowerState=Off → `sol-monitor.py` は exit 0 (False positive)
  → 子エージェントが「OS セットアップ完了」と **誤報告**
- さらに `post-install-config` は SSH 到達だけを検証し、
  `/etc/machine-id` タイムスタンプ等の「実際に再インストールされたか」
  の検証をしていない

レポートに既に適用済みの修正:
- `.claude/skills/os-setup/SKILL.md` Phase 4: iDRAC の SerialCommSettings preflight
- `.claude/skills/idrac7/SKILL.md`: Phase B-2 SerialCommSettings 復元

**未適用**かつ **最もリスクが高い** 項目 (本プランの対象):
1. `sol-monitor.py` の stage-observation 必須化
2. `post-install-config` の実インストール検証
3. スキル文書の exit code 表と False positive 警告
4. SOL /dev/ttyS* 非対応の記載

## 目的

1. 上記の silent false positive を **可視的な失敗** に変換する
2. 修正を 7/8/9 号機 (全台 Dell R320 + iDRAC7) で並列に 3 回ずつ (計 9 インストール)
   実行し、回帰しないこと・false positive 検出が機能することを実証する

## 修正内容

### 1. `scripts/sol-monitor.py` — installer stage observation 必須化

**変更方針**: 全ての `return 0` 経路に「少なくとも 1 つの INSTALLER_STAGE を
観測済み」を前提条件として追加。未観測で `PowerState=Off` を検知した場合は
新しい exit code `4` (False positive 疑い) を返す。

**具体的な変更点** (`scripts/sol-monitor.py`):

- L1-12 docstring: exit code 4 を追加
  ```
  4 = PowerState Off but no installer stages observed (probable false positive)
  ```
- L108 `monitor_loop()` シグネチャ変更なし
- L112 `current_stage_idx = -1` はそのまま。success check の gate として使う
- L149-151 (Power down 検出時): `current_stage_idx >= 0` を追加検証
  ```python
  if state == "Off":
      if current_stage_idx < 0:
          log("WARNING: PowerState=Off after 'Power down' but no stages observed")
          return 4
      log("Installation completed successfully (PowerState Off)")
      return 0
  ```
- L157-161 (EOF + Off): 同様のガード追加
- L170-173 (定期ポーリング + Off): 同様のガード追加
- L277-285 (main() の reconnect check): 同様に `rc == 4` 分岐と、stage 観測
  状況をまたぐため別アプローチが必要 — `monitor_loop` に `stage_observed`
  を外部参照可能にする or `main()` で stage 観測状態を保持する必要あり。
  **実装案**: `monitor_loop` をジェネレータ化せず、`current_stage_idx`
  を `main()` に返すよう戻り値を `(rc, stages_seen)` に変更する。
  `main()` ではこの情報を引き継ぎ、reconnect 中の PowerState=Off
  確認時にも同じガードを適用する
- L274-275: `if rc in (0, 1, 4): sys.exit(rc)`
- L299 `sys.exit(3)` 前に `stages_seen` が 0 なら exit 4 にする

**副次修正**:
- ログに `"Stage observed: COUNT=N"` を 1 分おきに出力して観測状況を可視化
  (デバッグ容易化のため)
- `INSTALLER_STAGES` の最初の項目 "Loading additional components" は
  preseed シナリオでは常に出るので、1 つ出れば「少なくとも installer
  ブート後の初期化までは進んだ」と言える

### 2. `.claude/skills/os-setup/SKILL.md` Phase 5 — 新 exit code の説明と対処

**変更箇所**: L382, L384-392 (現状の exit code 一覧と対処表)

**追加行**:

- L382 の終了コード一覧に `4=False positive (installer 出力なし)` を追加
- L384 対処表に 1 行追加:
  ```
  | 4 | False positive (stages 未観測) | 強制 Off → bmc-mount-boot からやり直し。
                                         ISO 再マウント + BIOS SerialComm 再確認。
                                         install-monitor を失敗扱いで mark しない |
  ```
- Phase 5 の末尾に警告ボックスを追加:
  > **重要**: `PowerState=Off` 単独での成功判定は False positive の原因
  > (`report/2026-04-10_172807_server8_vmedia_recovery_test.md`)。
  > `sol-monitor.py` は内部で最低 1 ステージの観測を必須化している。
  > 子エージェントが「install-monitor 完了」と判断する前に、Phase 6 の
  > `/etc/machine-id` タイムスタンプ検証を必ず通すこと。

**追加の Note**: L376 付近に 1 行追加:
- "**注意**: SOL は OS レベルの `/dev/ttyS*` 書き込みを捕捉しない
  (Dell R320 + iDRAC7 共通)。SOL に流れる出力は BIOS の INT10h
  リダイレクションまたは installer 固有の UEFI ConsoleOut 経由のみ。"

### 3. `.claude/skills/os-setup/SKILL.md` Phase 6 — 実インストール検証

**変更箇所**: L502-507 (ステップ 4: ホスト鍵削除 + SSH 接続確認) の直後
に **ステップ 5: 実インストール検証** を新設。

**追加内容** (約 25 行):

```sh
#### ステップ 5: 実インストール検証 (False positive 防止)

install-monitor 開始時刻より新しい `/etc/machine-id` が生成されている
ことを SSH 経由で検証する。古ければリインストール未実行 → 失敗扱いで
bmc-mount-boot からやり直し。

```sh
INSTALL_START=$(cat state/os-setup/${SERVER_NAME}/install-monitor.start)
REMOTE_MACHINE_ID_MTIME=$(ssh -F ssh/config "$PVE_HOST" stat -c %Y /etc/machine-id)
if [ "$REMOTE_MACHINE_ID_MTIME" -lt "$INSTALL_START" ]; then
    echo "ERROR: /etc/machine-id predates install-monitor start"
    echo "  machine-id mtime: $(date -d @$REMOTE_MACHINE_ID_MTIME)"
    echo "  install started:  $(date -d @$INSTALL_START)"
    ./scripts/os-setup-phase.sh fail post-install-config --config "$CONFIG"
    ./scripts/os-setup-phase.sh reset install-monitor --config "$CONFIG"
    ./scripts/os-setup-phase.sh reset bmc-mount-boot --config "$CONFIG"
    exit 1
fi
```
```

`install-monitor.start` は `os-setup-phase.sh start install-monitor` で
既に記録されているため、追加インフラ不要。

### 4. `.claude/skills/idrac7/SKILL.md` — 永続削除表現の訂正 (軽微)

**変更箇所**: L229-240 付近 (racadm BootMode 変更禁止警告)

現状「一度削除されると racadm では復元できない」→ より正確な表現に:
「mount 状態で POST を通すと BIOS が enumeration で自動再登録する。
ただし F3 Load Defaults の副作用で SerialCommSettings 他がリセット
されるため、racadm BootMode 変更は依然として禁止」

(Phase B-2 の F3 警告とも整合)

## テスト計画

### 準備フェーズ (直列)

1. **サーバ 8 の BIOS NVRAM リフレッシュ**
   (iteration の前段、レポート反復 3 の累積破損懸念に対応)
   ```sh
   ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm racreset
   # racreset 後 iDRAC 復旧まで 2 分待機
   ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm get BIOS.SerialCommSettings.SerialComm
   # SerialComm != OnConRedirCom1 なら Phase 4 と同じ修復ジョブを投入
   ```
2. **全 3 台の全フェーズリセット**
   (ユーザ指示: 全フェーズをリセット)
   ```sh
   sh tmp/<sid>/reset-all-phases.sh
   # 内容: for s in server7 server8 server9; do
   #         for p in iso-download preseed-generate iso-remaster bmc-mount-boot \
   #                  install-monitor post-install-config pve-install cleanup; do
   #           ./scripts/os-setup-phase.sh reset $p --config config/$s.yml
   #         done
   #       done
   ```

### 並列実行フェーズ (各 iteration)

1 iteration あたり 3 台並列に `os-setup` スキルを子エージェントで起動:

```
Agent(server=7, subagent_type=general-purpose, skill=os-setup, config=config/server7.yml)
Agent(server=8, subagent_type=general-purpose, skill=os-setup, config=config/server8.yml)
Agent(server=9, subagent_type=general-purpose, skill=os-setup, config=config/server9.yml)
```

全 3 agent を並列起動 → すべて完了を待つ → 結果を集計 → 全台 reset
→ 次 iteration

所要時間目安: 1 iteration あたり約 50-70 分 (pve-lock によるシリアル化を含む)
× 3 iteration = 150-210 分。

### 判定基準

- **成功**: 7, 9 号機が 3/3 とも OS セットアップ完了 (Phase 8 cleanup まで)
- **修正の有効性**: 仮に install が失敗した場合、`sol-monitor.py` が
  false positive を返さず、`exit 4` or `/etc/machine-id` 検証で失敗を
  検出すること
- **サーバ 8**: 3/3 成功が理想だが、installer ハングが再発する場合は
  false positive 検出されていれば「修正は機能している」と評価する

### iteration 間のレポート収集

各 iteration 完了後:
- `state/os-setup/server{7,8,9}/*.end` タイムスタンプで各フェーズ所要時間を集計
- sol-monitor.py のログファイル (`tmp/<sid>/sol-install-s{7,8,9}.log`)
  で stage 観測状況を確認
- `/etc/machine-id` タイムスタンプを pve{7,8,9} で取得して検証
- 結果を表にまとめる

## 変更ファイル一覧 (Critical Files)

| ファイル | 種別 | 行範囲目安 |
|---------|------|----------|
| `scripts/sol-monitor.py` | 改変 | L1-12 (docstring), L108-173 (monitor_loop), L266-300 (main) |
| `.claude/skills/os-setup/SKILL.md` | 改変 | L376-392 (Phase 5 exit code), L502-509 (Phase 6 検証追加) |
| `.claude/skills/idrac7/SKILL.md` | 微修正 | L229-240 (永続削除表現) |

## 再利用する既存関数・ユーティリティ

- `scripts/os-setup-phase.sh` の `start` / `mark` / `fail` / `reset`
  (新規フェーズ追加なし、既存の `install-monitor.start` を Phase 6
  検証で参照するだけ)
- `config/server{7,8,9}.yml` — 既存設定ファイル
- `ssh/config` の `pve7`, `pve8`, `pve9`, `idrac7`, `idrac8`, `idrac9`
  エイリアス
- `./pve-lock.sh wait` — 既存の排他ロック
- `scripts/ssh-wait.sh` — SSH 到達ポーリング
- `Agent` ツール + `os-setup` skill — 並列子エージェント起動

## Verification (修正の動作確認)

### A. sol-monitor.py のユニット検証 (実機不要)

1. 既存の SOL ログ (`tmp/5b576cc5/sol-install-s8.log` — 414 行の
   Automated Install ループ、stage 0 件) を再生テストファイルとして使用
2. `scripts/sol-monitor.py` を mock PowerState=Off で呼び、exit 4 を
   返すことを確認
   (難しければスキップし、実機テストで検証)

### B. 実機 end-to-end (本プランの主要検証)

上記「テスト計画」の並列実行を実施。

- **pass 条件**:
  - 7, 9 号機: 3/3 の iteration で Phase 1-8 完了、`/etc/machine-id`
    mtime > install-monitor.start
  - sol-monitor.py が exit 0 を返した全ケースで stage 観測 ≥ 1
    (ログで確認)
- **fail 条件**:
  - sol-monitor.py が stage 観測 0 で exit 0 を返す (False positive 再発)
  - Phase 6 の実インストール検証ステップを通過したのに
    `/etc/machine-id` mtime が古い (検証ロジックに漏れ)

### C. レポート作成

テスト完了後、`REPORT.md` のフォーマットに従い
`report/2026-04-10_xxxxxx_sol_monitor_false_positive_fix.md` として
記録する。失敗パターンがあれば追加 issue を `./issue.sh add` で登録。

## 既知の制約・リスク

- pve-lock により Phase 4/6/8 の電源操作はシリアル化される
  → 並列度は 100% ではない (2026-03-06 の実績で 3 台並列は確認済み)
- サーバ 8 の BIOS NVRAM 破損が物理的な原因だった場合、racreset では
  回復しない可能性あり。その場合は「修正は動作しているが、server 8
  の installer 本体は別問題」として結果を残す
- 1M 以上の並列実行で TFTP/SMB サーバが競合する可能性は過去レポートで
  ゼロ確認済み (`report/2026-03-06_130000_os_setup_parallel_stability.md`)

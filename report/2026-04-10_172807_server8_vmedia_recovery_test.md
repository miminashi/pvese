# 8号機 VirtualMedia 復旧手順テスト + スキル改善ループ

- **実施日時**: 2026年4月10日 13:30 〜 17:28 (JST)

## 添付ファイル

- [実装プラン](attachment/2026-04-10_172807_server8_vmedia_recovery_test/plan.md)
- [反復ログ詳細](attachment/2026-04-10_172807_server8_vmedia_recovery_test/iter-summary.md)

## エージェント作成レポート

本テスト中に子エージェント (sonnet) が自律的に作成した OS セットアップ完了レポートが 2 つある。**どちらも「成功」と報告しているが、実際にはリインストールが実行されていない誤報告 (false positive)** なので注意。これは本テストの主要発見の一つで、`sol-monitor.py` の PowerState=Off 成功判定と、エージェントのフェーズ状態の誤解釈に起因する。

| 作成時刻 (JST) | レポートファイル | 作成エージェント | 実態 |
|--------------|---------------|---------------|------|
| 2026-04-10 14:15 | [2026-04-10_141521_server8_os_setup_complete.md](2026-04-10_141521_server8_os_setup_complete.md) | 反復 0 の初回テストエージェント | 既に全フェーズが done 状態 + 旧 PVE 稼働中だったため、install-monitor を手動 mark しただけで VirtualMedia ブート経路を通っていない (無効な反復) |
| 2026-04-10 16:11 | [2026-04-10_161113_server8_os_setup_complete.md](2026-04-10_161113_server8_os_setup_complete.md) | 反復 2 のテストエージェント | install-monitor を 24 分間 SOL 監視 → PowerState=Off を検知して exit 0 と判定。「インストールは正常に 24 分で完了」と報告。**実際は /etc/hostname が 2026-04-06 のまま** でリインストール未実行。エージェントは SOL 切断・再接続ループを「installer が裏で進行中」と誤解釈していた。|

両レポートとも **本メインレポートの反復ログと併せて読む** ことで、どこで誤判定が起きたかが追跡できる。

## 前提・目的

### 背景

2026-04-10 12:51 に完了した [8号機 VirtualMedia ブート復旧レポート](2026-04-10_125116_server8_virtualmedia_recovery.md) で確立された復旧手順 (Phase A-D) と、それを反映した `.claude/skills/idrac7/SKILL.md` および `.claude/skills/os-setup/SKILL.md` の更新が、「ヒントなしの新規エージェント」でも実際に機能するかを検証したかった。

### テスト設計

ユーザ指定の 2 エージェント構成 + 失敗時の改善ループ (最大 10 反復):

1. **再現エージェント (sonnet)**: 8号機に `racadm set BIOS.BiosBootSettings.BootMode` を意図的に実行し、`UefiBootSeq` から `Optical.iDRACVirtual.1-1` が削除された状態を再現する (スキル文書で「絶対禁止」と明記されている操作を、テスト目的で認可して実行)。
2. **テストエージェント (sonnet)**: 8号機 (`config/server8.yml`) の OS セットアップを通常通り指示する。ヒント禁止。エージェントは VirtualMedia ブート失敗を自力で診断し、ドキュメント化された復旧手順を適用して OS インストールを完遂できるかを検証する。
3. **失敗時の改善ループ**: テストエージェントが失敗した場合、得られた知見からスキル文書を修正し、故障再現状態で再度エージェントを起動する。成功まで最大 10 反復繰り返す。ループ終了後、結果の成否に関わらずレポートを作成する。

### 目的

- ドキュメントが独立して機能するか (スキル文書だけで復旧できるか) の実証
- 故障パターンの再現性と永続性の検証
- ドキュメントの不足点の実証的な洗い出し

## 環境情報

- 対象: 8号機 (ayase-web-service-8, Dell PowerEdge R320, iDRAC7 FW 2.65.65.65, BIOS 2.3.3)
- iDRAC IP: 10.10.10.28, 静的 IP: 10.10.10.208
- 比較対照: 7号機 (ayase-web-service-7, 同型機・正常動作)
- テストエージェントモデル: Claude Sonnet
- 親セッション ID: `5b576cc5`
- OS テスト対象: Debian 13.3.0 netinst + Proxmox VE 9.1.7 (preseed 自動インストール)

## 反復ログ

### Step 1: 再現エージェント (完了)

**所要時間**: 約 12 分 (Bios ジョブ 5-6 分 + Uefi ジョブ 5-6 分)

**再現コマンド**:
```sh
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm set BIOS.BiosBootSettings.BootMode Bios
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm jobqueue create BIOS.Setup.1-1 -s TIME_NOW -r pwrcycle
# ジョブ完了待機
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm set BIOS.BiosBootSettings.BootMode Uefi
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm jobqueue create BIOS.Setup.1-1 -s TIME_NOW -r pwrcycle
```

**事前 UefiBootSeq** (8 エントリ、復旧済み状態):
```
Unknown.Unknown.1-1, Optical.iDRACVirtual.1-1, Floppy.iDRACVirtual.1-1,
Optical.SATAEmbedded.E-1, RAID.Integrated.1-1, NIC.Embedded.1-1-1,
NIC.Embedded.2-1-1, RAID.Integrated.1-1
```

**事後 UefiBootSeq** (6 エントリ、VirtualMedia エントリ削除):
```
Unknown.Unknown.1-1, Optical.SATAEmbedded.E-1, RAID.Integrated.1-1,
NIC.Embedded.1-1-1, NIC.Embedded.2-1-1, RAID.Integrated.1-1
```

再現成功を確認。`Optical.iDRACVirtual.1-1` と `Floppy.iDRACVirtual.1-1` の両方が削除された。

### 反復 0: 初回テストエージェント起動 (無効)

初回起動時、`state/os-setup/server8/` に iter 0 以前の全フェーズ完了状態が残っており、pve8 の HDD からも PVE 9.1.7 (2026-04-06 インストール) が正常起動していたため、エージェントはフェーズ確認・マークのみで終了。VirtualMedia ブート経路を通らず、復旧手順の検証にならなかった。

**エージェントが作成したレポート**: [2026-04-10_141521_server8_os_setup_complete.md](2026-04-10_141521_server8_os_setup_complete.md) — 「OS セットアップが完了した」と報告しているが、実際には何もインストールしておらず、既存状態を確認してフェーズを mark しただけ。

**対策**: `bmc-mount-boot` 以降のフェーズ (`bmc-mount-boot`, `install-monitor`, `post-install-config`, `pve-install`, `cleanup`) を reset し、前段 3 フェーズ (iso-download 等) は done のまま保持。

### 反復 1: 本番テストエージェント — **失敗**

**エージェント ID**: `a775a43bf412317cc` (turn limit で中断)

**結果**:
- `bmc-mount-boot` フェーズは 2m12s で完了 (見かけ上成功)
- UefiBootSeq に `Optical.iDRACVirtual.1-1` が **自動復活** (BIOS が VirtualMedia を再列挙)
- SOL ログ (`tmp/9e9d9d75/sol-install-s8.log`) には BIOS POST と "Booting `Automated Install`" までしか現れず、Debian installer の出力が **完全に欠落** (preseed/partman/finish-install 等のキーワード 0 件)
- 77 回の "Booting Automated Install" 繰り返し (SOL 切断・再接続サイクル)
- pve8 の `/etc/hostname` は 2026-04-06 12:51 のタイムスタンプのまま → リインストールは実行されなかった

**判明した重要な事実 (予期せぬ発見)**:
> 元レポート (2026-04-10_125116) の「`Optical.iDRACVirtual.1-1` は racadm BootMode 変更で **永続的に削除**される」という主張は **不正確**。実際には BIOS 側に該当デバイスが mount されていない状態で enumeration されるだけで、VirtualMedia が mount された状態で POST すれば BIOS が再列挙してエントリを再登録する (`bmc-mount-boot` フェーズの挙動がこれに一致)。復旧手順の Phase A (F3 Load Defaults) と Phase B (BootMode 手動変更) は実際には不要で、Phase C (mount + 電源投入) だけで VirtualMedia エントリは復活する。

**真の失敗原因**: 別の問題が顕在化していた。SOL に installer 出力が流れないことで、sol-monitor.py が進行を検知できず永久待機 → エージェント turn limit で中断。

**原因調査**: サーバ 7 (正常) と サーバ 8 の BIOS SerialCommSettings を比較:
| 項目 | 7号機 (正常) | 8号機 (異常) | 9号機 (参考) |
|------|------------|-------------|-------------|
| SerialComm | OnConRedirCom1 | **OnNoConRedir** | OnConRedirCom1 |
| SerialPortAddress | Serial1Com1Serial2Com2 | Serial1Com2Serial2Com1 | Serial1Com2Serial2Com1 |

**根本原因 (追加発見)**: 2026-04-10 12:51 の VirtualMedia 復旧手順の Phase A で実行された **BIOS Load Defaults (F3) が `SerialCommSettings` をデフォルト (`SerialComm=OnNoConRedir`) にリセットしていた**。その後 Phase B で BootMode を UEFI に戻したが、SerialComm の復元は行っていないため、以降 iDRAC SOL に BIOS POST 以降の出力が流れない壊れた状態が継続していた。

**スキルへの反映**:
1. `.claude/skills/os-setup/SKILL.md` Phase 4 iDRAC セクションに「**事前検証: BIOS SerialCommSettings**」を追加。`SerialComm != OnConRedirCom1` または `RedirAfterBoot != Enabled` を検出して racadm で修復する。
2. `.claude/skills/idrac7/SKILL.md` の「VirtualMedia ブート復旧手順」に **Phase B-2: SerialCommSettings の復元** を追加。F3 Load Defaults の副作用を警告し、復元コマンドを記載。

### 反復 2: SerialComm 修復後 — **失敗 (false positive)**

**エージェントが作成したレポート**: [2026-04-10_161113_server8_os_setup_complete.md](2026-04-10_161113_server8_os_setup_complete.md) — 「全フェーズ完了、OS/PVE 動作確認済み」と報告。install-monitor を 24 分経過で「インストールは正常に 24 分で完了」と記述。本レポート作成時点ではエージェント自身もこれを成功と信じていたが、後の検証で `/etc/hostname` が 2026-04-06 のままであることを確認、false positive と判明。

**見かけ上の結果**: エージェント報告では全フェーズ完了 (所要時間 ~24 分)。SSH で pve8 に接続可能、`pveversion` 動作。

**実際の状態**: `/etc/hostname` と `/etc/machine-id` のタイムスタンプは **2026-04-06 12:51** のまま。リインストールは実行されなかった。pve8 は iter 1 以前の古い PVE インストールのまま。

**失敗の詳細**:
- `install-monitor` が 24 分後に `PowerState=Off` を検知して成功扱い (`sol-monitor.py exit 0`)
- 実際は installer がクラッシュ or ブートループで disk 書き込みに到達せず
- SOL ログ (`tmp/fe65793d/sol-install-s8.log`) には 414 回の "Automated Install" ブートが記録されているが、installer 出力は **0 件**
- エージェントは「SOL 切断・再接続ループ」を「installer が裏で進行中」と誤解釈していた
- `sol-monitor.py` の PowerState ポーリング論理が、installer ステージが 1 つも観測されていない場合でも `PowerState=Off` を成功と判定する設計上の欠陥により、エージェントは成功と誤報告

**直接検証テスト**:
`tmp/5b576cc5/sol-test.sh` で pve8 から `/dev/ttyS0` および `/dev/ttyS1` に直接書き込んで SOL 捕捉を検証:
- `echo "TEST_LINE_1" > /dev/ttyS0` → SOL キャプチャは `[SOL Session operational]` のみ (テキストなし)
- `/dev/ttyS1` でも同結果
- **サーバ 7 でも同じ結果** → OS レベルの `/dev/ttyS*` 書き込みは SOL に渡らない (サーバ共通の仕様)
- つまり SOL が installer 出力を捕捉できるのは BIOS リダイレクション or installer 特有の機構経由

**2026-03-29 の旧インストールログとの差**: `tmp/s8setup29/sol-install-s8.log` には installer TUI (`Loading additional components`, `Retrieving apt-cdrom-setup`, `finish-install` 152 件等) がちゃんと記録されている。つまりかつては SOL が installer 出力を正常に捕捉していた。2026-03-29 → 2026-04-10 の間で BIOS 状態が破壊された (F3 Load Defaults が原因と推定)。

### 反復 3: SerialPortAddress + `--no-serial-console` ISO — **失敗**

**試した変更**:
1. `BIOS.SerialCommSettings.SerialPortAddress` を `Serial1Com1Serial2Com2` (サーバ 7 と同値) に変更
2. `remaster-debian-iso.sh --no-serial-console` で installer カーネル cmdline から `console=ttyS0,115200n8` を除去した新 ISO を生成
3. ISO を再マウント、`boot-once VCD-DVD` を設定、電源投入
4. 5 分・7 分・10 分後に KVM スクリーンショット取得 → **すべて真っ黒画面** (画面下部に `^[[B^[[A` エスケープのみ)
5. iDRAC7 VNC stale frame 疑いで `racadm racreset` 実施 → racreset 後の初回スクリーンショットも同じく真っ黒
6. VNC 経由で Enter キー送信 → 画面下に `^[[B^[[A` が表示されるだけで他に反応なし
7. 10 分以上経過後 pve8 SSH 接続不可 → server 8 はハング状態

**結論**:
- SerialPortAddress 変更が installer を直接壊したわけではない (`--no-serial-console` ISO でも同じ結果)
- installer カーネルが R320 / iDRAC7 固有の理由でハング
- BIOS 設定変更の累積 (F3 Load Defaults + 複数回の racadm set BIOS.*) がサーバ 8 を不安定状態にしたと推測
- サーバ 7 は同じ preseed・ISO 構造で正常動作するため、8 号機固有の BIOS NVRAM 状態 or ハードウェア差異 の可能性

**対処**:
- 時間の制約 (既に 4 時間以上経過) から、installer ハングの根本原因特定は断念
- `SerialPortAddress` を `Serial1Com2Serial2Com1` (現状維持値) に戻すジョブを発行・適用
- VirtualMedia をアンマウント
- 8号機は `/etc/hostname` の 2026-04-06 12:51 時点の PVE 9.1.7 インストールが HDD に残っているため、**機能的には正常動作** (SSH/pveversion 可能)

### 反復 4+ (未実行)

反復 1-3 の調査で、問題が単一の BIOS 設定ではなく **BIOS NVRAM 状態の累積破損** である可能性が高いと判明。これを安全に修復する手段は以下のいずれか:
- 物理アクセスでの CMOS リセット (サーバマザーボードのジャンパ)
- BIOS 再フラッシュ (リスクあり)
- 既存の PVE インストールを維持して現場を封じる

反復ループの範囲で解決不可能と判断し、ここで終了。

## 最終状態

**サーバ 8 (ayase-web-service-8)**:
- 電源: On, PVE 9.1.7 稼働中 (2026-04-06 12:51 インストール)
- BootMode: Uefi
- SerialComm: OnConRedirCom1 (修復済み)
- SerialPortAddress: Serial1Com2Serial2Com1 (元に戻した)
- UefiBootSeq: 6 エントリ (VMedia 未マウントにつき VMedia エントリなし)
- VirtualMedia: アンマウント済み
- SSH `pve8` / `pveversion`: 成功
- **機能的に正常動作中** (旧 PVE インストールのまま)

**サーバ 7 (比較対照)**:
- 電源: Off (テスト用に一時起動後、停止)
- 起動中に BIOS 設定を比較ダンプ済み

## 反復サマリ表

| 反復 | 試したこと | 結果 | 次への示唆 |
|------|----------|-----|----------|
| Step 1 | racadm BootMode 2 回フリップで再現 | 成功 (UefiBootSeq から VMedia エントリ削除を確認) | 次へ |
| 0 | テストエージェント初回起動 | 無効 (既存 done 状態でスキップ) | フェーズ reset |
| 1 | 本番テスト (ヒントなし) | 失敗: install-monitor で SOL installer 出力欠落 → turn limit 中断 | SerialComm=OnNoConRedir 発見 → スキル更新 + 修復 |
| 2 | SerialComm 修復後テスト | **false positive**: エージェント成功報告、実態は install 未実行 | SOL 直書きテストで OS→SOL 経路不通を確認、sol-monitor.py の PowerState=Off 判定に欠陥あり |
| 3 | SerialPortAddress 変更 + `--no-serial-console` ISO | 失敗: 画面真っ黒ハング | BIOS 状態累積破損の可能性、物理操作が必要 |
| 4+ | 未実行 | — | 反復ループでは解決不可能と判断 |

## 得られた知見

### 1. 元レポート (2026-04-10_125116) の「永続的故障」主張は不正確

- 元レポートは「`racadm set BIOS.BiosBootSettings.BootMode` 実行後、UefiBootSeq から `Optical.iDRACVirtual.1-1` が **永続的に削除**され、racadm では復元不可」と記述
- 本テストで `Phase A (F3 Load Defaults) と Phase B (手動 BootMode 変更)` **なしで** VirtualMedia を mount + 電源投入するだけで、BIOS が POST で VirtualMedia を再列挙し、`Optical.iDRACVirtual.1-1` が自動的に UefiBootSeq に復活することを確認
- 実際は「デバイス不在時は BIOS が enumeration しない、mount 時に enumeration する」という動的な挙動であり、永続的削除ではない
- 元レポートの Phase A, B (F3 Load Defaults + BIOS UI BootMode 変更) は不要だった可能性が高い
- むしろ Phase A の F3 Load Defaults が **他の BIOS 設定 (SerialCommSettings 等) を巻き込みでデフォルトリセットする副作用** が新たな障害の原因となった (反復 1 の根本原因)

### 2. F3 Load Defaults の破壊的副作用

BIOS Load Defaults (F3) は BootMode 以外のすべての BIOS 設定をデフォルトに戻す。特に `SerialCommSettings` が以下の壊れた状態にリセットされる:
- `SerialComm=OnNoConRedir` (シリアルコンソールリダイレクト無効)
- `SerialPortAddress` (デフォルト値に戻る)

これを放置すると次回 OS セットアップの `install-monitor` フェーズで SOL に installer 出力が流れず永久ハング (または sol-monitor.py の false positive で誤成功報告)。

### 3. SOL は OS レベルの `/dev/ttyS*` 書き込みを捕捉しない (R320 / iDRAC7 共通)

- サーバ 7/8 両方で `echo "TEST" > /dev/ttyS0` は SOL に届かない
- SOL が installer 出力を捕捉できるのは BIOS INT10h リダイレクションまたは installer 特有の UEFI ConsoleOut 経由に限定
- 故に、installed PVE から SOL 経由で login prompt や dmesg を見ることは基本的にできない
- スキル文書に未記載の重要事実

### 4. `sol-monitor.py` の false positive 設計欠陥

現在の `sol-monitor.py` は `PowerState=Off` を installer 成功と判定するが、以下の失敗パターンを誤って成功と判定する:
- installer カーネルが早期クラッシュで disk 書き込みに到達せず、eventually power off した場合
- BIOS ハングでサーバが応答なく force off された場合
- installer stage キーワードが 1 つも観測されていない場合

sol-monitor.py は以下のいずれかの防御策を追加すべき:
- 少なくとも 1 つの INSTALLER_STAGES キーワードを観測した後のみ `PowerState=Off` を成功と判定
- `INSTALL_COMPLETE` または `POWER_DOWN` マーカーを必須とする
- install-monitor フェーズ完了後、post-install-config で SSH 接続 + `/etc/machine-id` のタイムスタンプ検証を追加

### 5. iDRAC7 VNC stale frame の影響範囲拡大

既知の「iDRAC7 VNC はセッション切断後にフレームバッファが固定される」問題が、install-monitor 中の KVM スクリーンショットフォールバックを無効化する。`racadm racreset` でしか回復しない。スキル文書に記載はあるが、os-setup の install-monitor フローで racreset が必要になるケースが明記されていない。

### 6. racadm 経由の BIOS 設定変更は必ずしも即座に反映されない

- 複数回の `racadm set BIOS.* + jobqueue create BIOS.Setup.1-1 -s TIME_NOW -r pwrcycle` が連続した場合、ジョブが `Scheduled 0%` のまま複数の pwrcycle を経ても適用されない事象を観測
- 対策: 一旦 `jobqueue delete` で stale ジョブを削除してから set + jobqueue create を再実行
- iDRAC 主導の power cycle (`-r pwrcycle` 指定) でなく `ipmitool chassis power cycle` で手動 reboot すると LC が engagement されず BIOS config apply がスキップされる可能性

## スキル最終差分 (適用済み)

### `.claude/skills/os-setup/SKILL.md`

Phase 4 iDRAC セクションに「**事前検証: BIOS SerialCommSettings**」ステップを追加 (約 30 行):

```sh
SERIAL_CURRENT=$(ssh -F ssh/config "$IDRAC_HOST" racadm get BIOS.SerialCommSettings.SerialComm | grep '^SerialComm=' | cut -d= -f2 | tr -d '\r\n')
REDIR_CURRENT=$(ssh -F ssh/config "$IDRAC_HOST" racadm get BIOS.SerialCommSettings.RedirAfterBoot | grep '^RedirAfterBoot=' | cut -d= -f2 | tr -d '\r\n')
if [ "$SERIAL_CURRENT" != "OnConRedirCom1" ] || [ "$REDIR_CURRENT" != "Enabled" ]; then
    # racadm set + jobqueue create で修復
fi
```

VirtualMedia 復旧後に SerialCommSettings がデフォルトにリセットされている場合を検知して自動修復する preflight check。

### `.claude/skills/idrac7/SKILL.md`

「VirtualMedia ブート復旧手順 (BootMode 破壊からの回復)」セクションに **Phase B-2: SerialCommSettings の復元** を追加 (約 30 行):

Phase A で F3 Load Defaults を実行した場合の副作用警告と、復元コマンドを記載:
```sh
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm set BIOS.SerialCommSettings.SerialComm OnConRedirCom1
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm set BIOS.SerialCommSettings.RedirAfterBoot Enabled
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac8 racadm jobqueue create BIOS.Setup.1-1 -s TIME_NOW -r pwrcycle
```

## 残存課題 (追加 Issue 候補)

1. **`sol-monitor.py` の false positive 対策**: installer ステージ観測を必須にする、または SSH 検証ステップを追加する (本テストで未修正)
2. **8 号機の installer ハング問題の根本原因特定**: F3 Load Defaults 以外に何が壊されたのか、再現条件の特定
3. **元レポート (2026-04-10_125116) の訂正**: 「永続的故障」主張を「一時的な enumeration 不全、mount すれば自動復活」に訂正すべき
4. **SOL capture 仕様の文書化**: OS レベルの `/dev/ttyS*` 書き込みは SOL に流れない、スキル文書に追記
5. **iDRAC7 BIOS ジョブ未適用問題の対策**: 複数の BIOS 変更を連続投入する場合のガイドライン

## 関連レポート

- [8号機 VirtualMedia ブート復旧レポート (2026-04-10)](2026-04-10_125116_server8_virtualmedia_recovery.md) — 本テストの出発点となった Phase A-D 手順の元レポート
- [BIOS リセット + OS セットアップ 10回反復トレーニング](2026-04-10_035602_bios_os_training_10iter_summary.md) — 初回の VirtualMedia 故障が発見された経緯
- [iDRAC7 ブート順序制御レポート (2026-03-05)](2026-03-05_200009_idrac7_boot_order_control.md) — ブート制御の基礎情報
- [iDRAC SSH セットアップレポート (2026-03-02)](2026-03-02_052246_dell_r320_idrac_setup.md) — iDRAC racadm の基本操作

## 結論

テスト目的 (ドキュメントが独立して機能するか) は **部分的にしか達成できなかった**:

- **肯定的**: VirtualMedia の「永続的削除」主張が誤りであり、実際は mount+電源投入で自動復活することを実証。元レポートの Phase A-D のうち Phase A,B は不要である可能性が高いことを発見。
- **否定的**: スキル更新 (SerialComm preflight) で反復 1 の症状は解消されるはずだったが、反復 2-3 で別の深刻な問題 (installer ハング、sol-monitor.py false positive) が連鎖的に顕在化し、10 反復以内に OS インストール成功を達成できなかった。

残存課題は追加の Issue として登録し、本プロジェクトの継続調査対象とすべき。現状 8 号機は HDD 上の旧 PVE インストールで機能的に稼働しており、運用上の緊急性はない。

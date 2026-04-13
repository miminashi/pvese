# 8号機 VirtualMedia ブート復旧計画

## Context

8号機 (Dell PowerEdge R320, iDRAC7 FW 2.65.65.65, BIOS 2.3.3) は、10回反復トレーニングの iter7 で `racadm set BIOS.BiosBootSettings.BootMode` を使用した後、VirtualMedia ブートが永続的に不能になった。通常の HDD ブートは正常。racreset と4回のクリーンブートサイクルでは復旧しなかった。

7号機（同一ハードウェア、正常動作）を比較用ベースラインとして使用する。

## 方針

- 10個の仮説を **非破壊的 → 破壊的** の順に検証
- 各仮説で7号機（正常）と8号機（異常）の設定を比較し、差分を特定
- サーバ操作は **sonnet エージェント** に委譲
- 復旧成功時はスキル (`os-setup`, `idrac7`) に知見を反映

## 検証プロトコル（全仮説共通）

1. 7号機・8号機で診断コマンドを実行し出力を比較
2. 差分があれば8号機に修正を適用
3. VirtualMedia ブートテスト:
   - `./scripts/idrac-virtualmedia.sh mount 10.10.10.28 "//10.1.6.1/public/debian-preseed-s8.iso"`
   - `./scripts/idrac-virtualmedia.sh boot-once 10.10.10.28 VCD-DVD`
   - `ipmitool ... chassis power cycle`
   - VNC スクリーンショットで5分間監視
   - 成功 = Debian インストーラ画面 / 失敗 = EFI ループ or LC 停止
4. テスト後クリーンアップ: umount + boot-reset

## 仮説一覧

### H1: iDRAC jobqueue にスタック BIOS ジョブが残留 (リスク: なし)
### H2: Lifecycle Controller が不正状態 (リスク: 中)
### H3: UefiBootSeq に破損エントリ (リスク: 低)
### H4: BootSeq に VirtualMedia デバイスが欠落 (リスク: 低)
### H5: iDRAC VirtualMedia サブシステムが無効化 (リスク: なし)
### H6: cfgVirMediaAttached モード破損 (リスク: なし)
### H7: BIOS 設定の全項目比較 + NVStore クリア (リスク: 中〜高)
### H8: iDRAC 完全ファクトリーリセット (racresetcfg) (リスク: 高)
### H9: BIOS ファームウェア再フラッシュ (リスク: 中)
### H10: VNC 経由 F2 BIOS Setup + Load Defaults (リスク: 低〜中)

## 実装の流れ

1. セッション用 tmp ディレクトリ作成
2. H1 から順に sonnet エージェントを起動し、診断→修正→テストを委譲
3. 各仮説の結果を記録
4. 復旧成功時:
   - 原因と修正手順をレポートに記録
   - `os-setup` スキルと `idrac7` スキルに知見を反映
5. 全仮説失敗時: 物理 USB インストールを推奨

## 修正対象ファイル（復旧成功時）

- `.claude/skills/os-setup/SKILL.md` — VirtualMedia 復旧手順の追加
- `.claude/skills/idrac7/SKILL.md` — racadm BootMode 変更の禁止事項と復旧手順
- レポート: `report/` に復旧結果レポート作成

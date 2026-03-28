# PERC H710 RAID セットアップスキル（VNC ベース）

## Context

PERC H710 の RAID を VNC 経由で BIOS 操作する。bios-setup スキル（Supermicro）と同様、
スクリーンショット→解釈→キーストローク→繰り返しのパターン。

### iDRAC7 VNC の SYSTEM IDLE 問題と解決策

**問題**: iDRAC7 VNC は一度ビデオキャプチャが停止すると、VNC Disable/Enable では復旧せず、
新規 VNC 接続でも SYSTEM IDLE または黒画面が返る。

**解決策**: `racadm racreset` で iDRAC を完全リセットすると VNC ビデオキャプチャが復活する。
racreset 後は新規 VNC 接続でも正常にスクリーンショットが取れる。

**運用フロー**:
1. PERC BIOS 操作前に `racadm racreset` を実行（所要 90-120 秒）
2. iDRAC 復帰後、`idrac-kvm-interact.py` で VNC 接続
3. 操作はバックグラウンドの単一 VNC セッションで実行
4. Claude はスクリーンショットを確認しながら次のキーストロークを決定
5. 次のキーシーケンスを同一セッション内で送信

### PERC BIOS メニュー構造（8号機で確認済み）

**タブ**: `VD Mgmt` → `PD Mgmt` → `Ctrl Mgmt` → `Properties` (Ctrl+N/P で切替)
**操作キー**: F1=Help, F2=Operations, F5=Refresh, Enter=展開/選択, Escape=戻る

**PERC BIOS 進入**: POST 中に Ctrl+R を連打（約 36 秒後に表示）

### POST タイミング (8号機)

| 秒数 | 画面 |
|------|------|
| 0-10 | Configuring Memory |
| 10-20 | Dell BIOS ロゴ (F2=Setup, F10=LC, F11=Boot, F12=PXE) |
| 16-20 | PERC BIOS プロンプト "Press \<Ctrl\>\<R\> to Run Configuration Utility" |
| 20-30 | F/W Initializing Devices → PERC BIOS 進入 |

## 変更ファイル

### 1. `.claude/skills/perc-raid/SKILL.md` — 新規スキル作成

VNC ベースの PERC H710 RAID 操作スキル:

**操作パターン**: bios-setup スキルと同様のスクリーンショット→キーストロークループ
- `idrac-kvm-interact.py` で VNC 接続・操作
- バックグラウンド単一セッションで連続操作
- Claude がスクリーンショットを見て次のキーを判断

**前提条件セクション**:
- VNC ビデオキャプチャのリセット方法（racreset）
- VNC 接続パラメータ
- PERC BIOS 進入手順

**PERC BIOS メニュー操作**:
- VD 作成 (F2 → Create New VD)
- VD 削除 (F2 → Delete)
- PD 管理
- 設定保存・終了

### 2. `scripts/idrac-kvm-interact.py` — VNC インタラクションスクリプト（作成済み、改善）

- バックグラウンド単一セッション対応
- sendkeys + screenshot-each のフロー
- wake() の改善（racreset 後は不要だが安全策として残す）

### 3. メモリ更新

- iDRAC7 VNC の SYSTEM IDLE 制約と racreset による解決策

## 検証方法

1. racreset → iDRAC 復帰確認
2. power cycle → Ctrl+R で PERC BIOS 進入
3. VD1 (data0) 削除操作
4. 新規 VD 作成操作
5. 設定保存・リブート
6. racadm raid get vdisks で結果確認

## レポート

完了後に report/ にレポートを REPORT.md フォーマットで作成。

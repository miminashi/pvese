# 10-13号機 ASC=0x81 Hardware Error 根本対策

## Context

10-13号機 (Supermicro X10DRT-P / Nutanix OEM Twin Server) のデータ HDD (Seagate DKS5x-J1R2SS 1.2 TB SAS, ファーム Rev 7FA9) が、全 8 本 (pve10-13 × sdb/sdc) で **書き込み拒否状態** (Sense Key 0x4 Hardware Error / vendor ASC=0x81)。前セッション (#61) で sg_format による 520B→512B 再フォーマット (3h32m × 4 本) を経ても解除されず giveup。

レポート [`report/2026-05-04_034112_server10-13_linstor_giveup_hw_error.md`](../../../projects/pvese/report/2026-05-04_034112_server10-13_linstor_giveup_hw_error.md) の最高優先度引き継ぎ事項である ASC=0x81 の根本対策に取り組み、ZFS pool 作成可能な状態へ復帰させる。

完了/ギブアップどちらでも 10-13 号機を OS シャットダウン+ BMC OFF まで完了させる (ユーザ指示)。

## 現状の前提

- **電源**: pve10-13 全て BMC レベル Off (前セッション終了時にシャットダウン済)
- **Issue**: #61 [blocked]、ブロック理由「全 8 データ HDD で write Hardware Error ASC=0x81。sg_format でも解決せず原因切り分け不能」
- **構築済み資産** (シャットダウン後保持): PVE クラスタ `pvese-cluster-c`、LINSTOR 1.33.2 (controller=pve10)、DRBD 9.3.2、4 ノード相互 SSH 鍵
- **既知の切り分け済 (再現済)**: SMART OK / T10-PI 無効 (prot_en=0) / WP=0 / PR keys 無し / OS disk (sda) write は正常 → HBA 全体障害ではない
- **物理アクセス**: 不可 (ジャンパピン操作・ラベル PSID 確認・Nutanix AOS 切替は本セッション範囲外)

## 設計方針

リスク低かつ調査価値の高いアプローチから、リスク高・最後の手段の順に試行。**先行検証は pve10 の /dev/sdb のみ** (1 ディスク)。成功した時点でその時点の Phase をスクリプト化し、残り 7 本に逐次展開。各 Phase 終端で `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct` 成功判定。

**累積タイムボックス: 12 時間** (ユーザ承認済)。SANITIZE Overwrite (1.2 TB で 4-8 時間想定) 等の長時間操作も実施可能。

スコープ外 (本セッションで実施しない、12 時間枠でも):
- `sg_write_buffer` でファーム/設定領域書き換え (失敗時にディスクが恒久的にブリックする可能性、時間ではなくリスクの種類でスコープ外)
- Nutanix AOS / CVM 環境への切替 (大規模変更)
- 物理ジャンパピン確認 (リモート不可)

(以下、approved plan と同一内容)

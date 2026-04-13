# ノード障害・回復テスト レポート (Iterations 100-102)

- **実施日時**: 2026年4月4日 04:16 JST

## 前提・目的

Region A (pve4+pve5+pve6) の非コントローラノード (pve5, pve6) を強制電源断してノード障害をシミュレートし、自動回復動作を検証する。

- **目的**: 非コントローラノードの障害・回復時の VM 継続性、DRBD クォーラム維持、LINSTOR 検出時間の計測
- **対象 VM**: VM 200 (pve4 上で動作)
- **LINSTOR リソース**: pm-5b16a893 (pve4+pve5+pve7、pve6 はレプリカなし)
- **LINSTOR コントローラ**: pve4

## 環境情報

| ノード | 役割 | BMC IP | 静的 IP |
|--------|------|--------|---------|
| pve4 (ayase-web-service-4) | COMBINED (コントローラ+サテライト) | 10.10.10.24 | 10.10.10.204 |
| pve5 (ayase-web-service-5) | SATELLITE | 10.10.10.25 | 10.10.10.205 |
| pve6 (ayase-web-service-6) | SATELLITE | 10.10.10.26 | 10.10.10.206 |
| pve7 (ayase-web-service-7) | SATELLITE (Region B DR) | 10.10.10.27 | 10.10.10.207 |

- DRBD リソース pm-5b16a893: pve4 (Primary, UpToDate) + pve5 (Secondary, UpToDate) + pve7 (Secondary, UpToDate)
- pve6 は pm-5b16a893 のレプリカを持たない (異なるリソースのノード)
- IPoIB インタフェース: ibp134s0 (pve5: 192.168.100.2/24, pve6: 192.168.100.3/24)

## 初期状態 (Iteration 100 開始前)

- 全 6 ノード LINSTOR Online
- VM 200: running (pve4)
- DRBD: pve4 UpToDate / pve5 UpToDate / pve7 UpToDate、Established
- Timestamp: 1775243042 (Unix epoch)

## Iteration 100: pve5 障害・回復

### 障害フェーズ

| タイムスタンプ | イベント |
|----------------|----------|
| 1775243049 (04:04:09 JST) | power off コマンド送信前 |
| 1775243056 (04:04:16 JST) | `chassis power off` 完了 |
| 1775243095 (04:04:55 JST) | LINSTOR で OFFLINE 確認 |

- **電源断から OFFLINE 検出**: **39 秒**
- DRBD 状態: pve5 → Connecting/DUnknown、pve7 → UpToDate/Established (クォーラム維持)
- VM 200: running (影響なし)

### 回復フェーズ

| タイムスタンプ | イベント |
|----------------|----------|
| 1775243114 (04:05:14 JST) | `chassis power on` 完了 |
| 1775243266 (04:07:46 JST) | SSH 接続成功 |
| ~1775243266 | LINSTOR Online 確認 (SSH 成功直後) |

- **電源投入から SSH 到達**: **152 秒**
- **DRBD 再同期**: SSH 到達時点で既に UpToDate (bitmap resync 完了、実質 0 秒)
- IPoIB: ibp134s0 UP / 192.168.100.2/24 正常復帰
- VM 200: running (全期間継続)

## Iteration 101: pve6 障害・回復

### 障害フェーズ

| タイムスタンプ | イベント |
|----------------|----------|
| 1775243296 (04:08:16 JST) | `chassis power off` 完了 |
| 1775243336 (04:08:56 JST) | LINSTOR で OFFLINE 確認 |

- **電源断から OFFLINE 検出**: **40 秒**
- DRBD 状態: pve6 は pm-5b16a893 のレプリカなし → DRBD への影響なし
- VM 200: running (影響なし)

### 回復フェーズ

| タイムスタンプ | イベント |
|----------------|----------|
| 1775243352 (04:09:12 JST) | `chassis power on` 完了 |
| 1775243505 (04:11:45 JST) | SSH 接続成功 |
| 1775243535 (04:12:15 JST) | LINSTOR Online 確認 |

- **電源投入から SSH 到達**: **153 秒**
- **SSH 到達から LINSTOR Online**: **30 秒** (satellite サービス起動に時間が必要)
- **電源投入から LINSTOR Online**: **183 秒**
- DRBD 再同期: 対象外 (pve6 はレプリカなし)
- IPoIB: ibp134s0 UP / 192.168.100.3/24 正常復帰
- VM 200: running (全期間継続)

## Iteration 102: pve5 障害・回復 (再現確認)

### 障害フェーズ

| タイムスタンプ | イベント |
|----------------|----------|
| 1775243554 (04:12:34 JST) | `chassis power off` 完了 |
| 1775243592 (04:13:12 JST) | LINSTOR で OFFLINE 確認 |

- **電源断から OFFLINE 検出**: **38 秒**
- DRBD 状態: Iteration 100 と同一パターン (pve5 Connecting/DUnknown、pve7 維持)
- VM 200: running (影響なし)

### 回復フェーズ

| タイムスタンプ | イベント |
|----------------|----------|
| 1775243607 (04:13:27 JST) | `chassis power on` 完了 |
| 1775243757 (04:15:57 JST) | SSH 接続成功 |
| 1775243782 (04:16:22 JST) | LINSTOR Online 確認 |

- **電源投入から SSH 到達**: **150 秒**
- **SSH 到達から LINSTOR Online**: **25 秒**
- **電源投入から LINSTOR Online**: **175 秒**
- DRBD 再同期: SSH 到達後 25 秒以内に UpToDate/Established (bitmap resync)
- IPoIB: ibp134s0 UP / 192.168.100.2/24 正常復帰
- VM 200: running (全期間継続)

## 計測結果サマリ

| Iteration | 対象 | 電断→OFFLINE | 電投→SSH | 電投→LINSTOR Online | DRBD 再同期 | VM 継続 | IPoIB 復帰 |
|-----------|------|-------------|---------|---------------------|-------------|---------|-----------|
| 100 | pve5 | 39 秒 | 152 秒 | ~152 秒 (即時 Online) | 即時 (bitmap) | OK | OK |
| 101 | pve6 | 40 秒 | 153 秒 | 183 秒 | N/A | OK | OK |
| 102 | pve5 | 38 秒 | 150 秒 | 175 秒 | ~25 秒 (bitmap) | OK | OK |

**平均値** (pve5, Iter 100/102): OFFLINE 検出 38.5 秒 / SSH 到達 151 秒

## 考察・観察事項

1. **OFFLINE 検出時間は約 39 秒で安定**: LINSTOR の heartbeat タイムアウトが約 30-40 秒の設定と一致する
2. **Boot-to-SSH は 150-153 秒で高い再現性**: 3 回とも 120-180 秒区間 (30 秒ポーリング精度) で検出
3. **Iteration 100 の LINSTOR Online が即時**: SSH 到達時点で既に LINSTOR が Online だった。Iteration 102 では Connected 経由で 25 秒後に Online。boot 順序のわずかな差異と思われる
4. **DRBD bitmap resync が非常に高速**: pve5 はダウン中に Primary (pve4) への書き込みがあったが、bitmap による差分同期のみで即時 UpToDate に復帰。大規模データでも bitmap があれば全同期は不要
5. **pve6 は pm-5b16a893 のレプリカなし**: pve6 障害でも DRBD クォーラムへの影響ゼロ。2+1 配置 (pve4+pve5+pve7) が正しく機能
6. **VM 200 は全期間 running**: 非コントローラノードの障害では Primary (pve4) の VM に影響なし
7. **IPoIB は全ノードで自動復帰**: ibp134s0 が UP かつ IP アドレス (192.168.100.x) が正常に割り当て済み。過去の Issue #38 (IPoIB 不起動) が os-setup スキルで解決されていることを確認
8. **pve6 の LINSTOR satellite は SSH 到達 30 秒後に Online**: Java プロセス起動に時間がかかるため。pve5 でも Iter 102 では 25 秒かかった

## 異常・懸念事項

特になし。3 回の障害シミュレーションがすべて正常に完了した。

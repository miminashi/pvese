# Memtest86+ テスト結果

## テスト環境

| 項目 | 値 |
|------|-----|
| ツール | Memtest86+ v8.00 (grub-memtest.iso) |
| サーバ | 6号機 (Supermicro X11DPU) |
| CPU | Intel Xeon Silver 4116 @ 2.10GHz (2S/24C/48T, SMP: 48T PAR) |
| メモリ | 15.6 GB (P1-DIMMA1 のみ。P2-DIMMA1 は BIOS MRC により自動無効化) |
| POST メッセージ | "Failing DIMM: DIMM location. (Uncorrectable memory component found) P2-DIMMA1" |

## T1: ベースライン (PPR=Hard PPR, SDDC=Disabled, Freq=Auto)

| 項目 | 値 |
|------|-----|
| テスト対象メモリ | 15.6 GB |
| パス回数 | 1 |
| エラー数 | **0** |
| 結果 | **PASS** |
| テスト時間 | 約 47 分 (10:19 - 11:06 JST) |

### スクリーンショット
- `tmp/1ae6ce03/bios_entry_050.png` — POST DIMM エラーメッセージ (P2-DIMMA1)
- `tmp/1ae6ce03/memtest_grub_enter.png` — memtest86+ 起動直後 (15.6GB, Errors: 0)
- `tmp/1ae6ce03/t1-memtest-20min-check.png` — 25分経過時 (Test #7 Block move, Errors: 0)
- `tmp/1ae6ce03/t1-memtest-47min.png` — 1パス完了 (**PASS** 表示)

### SEL (System Event Log) ベースライン
- DIMM/Memory ECC エラー: なし
- Battery #0x33 Failed: 継続中 (CMOS バッテリー)
- Power Supply Failure: 1件 (2026-04-07)

## T2: PPR Type = Disabled

| 項目 | 値 |
|------|-----|
| BIOS 設定変更 | PPR Type: Hard PPR → **Disabled** |
| テスト対象メモリ | 15.6 GB (変化なし) |
| パス回数 | 1 |
| エラー数 | **0** |
| 結果 | **PASS** |
| テスト時間 | 約 52 分 (11:31 - 12:23 JST) |
| POST DIMM メッセージ変化 | 確認不可 (POST が速く GRUB メニューに到達していた) |
| メモリ容量変化 | なし (15.6GB → 15.6GB、P2-DIMMA1 引き続き無効) |

### スクリーンショット
- `tmp/1ae6ce03/t2-bios-ppr-disabled.png` — PPR Type 変更後の Memory Configuration 画面
- `tmp/1ae6ce03/t2-post-dimm2.png` — GRUB メニュー (POST DIMM メッセージは確認できず)
- `tmp/1ae6ce03/t2-memtest-boot-check.png` — memtest86+ 起動直後 (15.6GB, Errors: 0)
- `tmp/1ae6ce03/t2-memtest-result.png` — 1パス完了時 (**PASS**, Errors: 0)

## T3: PPR Type = Soft PPR

| 項目 | 値 |
|------|-----|
| BIOS 設定変更 | PPR Type: Disabled → **Soft PPR** |
| テスト対象メモリ | 15.6 GB (変化なし) |
| パス回数 | 1 |
| エラー数 | **0** |
| 結果 | **PASS** |
| テスト時間 | 約 51 分 |
| POST DIMM メッセージ | Failing DIMM: P2-DIMMA1 (Uncorrectable memory component found) — 継続 |
| メモリ容量変化 | なし (15.6GB → 15.6GB、P2-DIMMA1 引き続き無効) |

### スクリーンショット
- `tmp/1ae6ce03/t3-bios-ppr-soft.png` — PPR Type = Soft PPR 設定後
- `tmp/1ae6ce03/t3-memtest-now.png` — memtest86+ 起動直後 (15.6GB, Test #4, Errors: 0)
- `tmp/1ae6ce03/t3-memtest-26min.png` — 26分経過時
- `tmp/1ae6ce03/t3-memtest-result.png` — 1パス完了時 (**PASS** 表示, Errors: 0)

## T4: SDDC = Enabled (+ PPR Type を Hard PPR に復元)

| 項目 | 値 |
|------|-----|
| BIOS 設定変更 | SDDC: Disabled → **Enabled**, PPR Type: Soft PPR → Hard PPR (T1 ベースラインに復元) |
| テスト対象メモリ | 15.6 GB (変化なし) |
| パス回数 | 1 |
| エラー数 | **0** |
| 結果 | **PASS** |
| テスト時間 | 約 52 分 |
| メモリ容量変化 | **なし** (15.6GB → 15.6GB、SDDC Enabled でも P2-DIMMA1 は復活せず) |
| 重要な知見 | **SDDC は BIOS MRC の DIMM 自動無効化を上書きできない**。MRC 除外 → SDDC 適用の順で処理されるため、除外された DIMM には SDDC の追加 ECC が適用されない |

### スクリーンショット
- `tmp/1ae6ce03/t4-bios-ppr-hard.png` — PPR Hard PPR 復元
- `tmp/1ae6ce03/t4-bios-sddc-enabled.png` — SDDC Enabled 設定後
- `tmp/1ae6ce03/t4-post-100s.png` — POST 中
- `tmp/1ae6ce03/t4-memtest-start.png` — memtest86+ 起動直後 (15.6GB)
- `tmp/1ae6ce03/t4-status-check.png` — 1分経過時 (Test #4, Errors: 0)
- `tmp/1ae6ce03/t4-memtest-result.png` — 1パス完了時 (**PASS**, Errors: 0)

## T5: Memory Frequency = 1866 + SDDC = Disabled

| 項目 | 値 |
|------|-----|
| BIOS 設定変更 | Memory Frequency: Auto → **1866**, SDDC: Enabled → **Disabled** |
| テスト対象メモリ | **15.6 GB** (変化なし) |
| メモリ速度 | 1866 MHz (BIOS 設定値; memtest86+ 起動画面で確認) |
| パス回数 | 1 |
| エラー数 | **0** |
| 結果 | **PASS** |
| テスト時間 | 約 57 分 |
| POST DIMM メッセージ変化 | **なし** — "Failing DIMM: DIMM location. (Uncorrectable memory component found) P2-DIMMA1" が継続 |
| メモリ容量変化 | **なし** (15.6GB → 15.6GB、Memory Frequency 1866 でも P2-DIMMA1 は復活せず) |
| T1 との差異 | なし。SDDC=Disabled/PPR=Hard PPR という点では T1 と同一条件。Freq のみ異なる (Auto→1866)。エラー数・容量ともに変化なし |

### スクリーンショット
- `tmp/1ae6ce03/t5-bios-freq-1866.png` — Memory Frequency 変更後 (1866 設定確認)
- `tmp/1ae6ce03/t5-bios-sddc-disabled.png` — SDDC Disabled 設定後
- `tmp/1ae6ce03/t5-post-40s.png` — POST 中 (Supermicro ロゴ, 40秒後)
- `tmp/1ae6ce03/t5-grub-check.png` — POST中 "Failing DIMM: P2-DIMMA1" メッセージ確認
- `tmp/1ae6ce03/t5-memtest-start.png` — memtest86+ 起動直後 (15.6GB, CLK 2100MHz)
- `tmp/1ae6ce03/t5-memtest-running.png` — テスト実行中 (SMP 48T, Errors: 0)
- `tmp/1ae6ce03/t5-memtest-55min.png` — 55分経過時 (PASS 表示)
- `tmp/1ae6ce03/t5-memtest-result.png` — 1パス完了時 (**PASS**, Errors: 0)

## T6: Memory Rank Sparing = Enabled (+ Memory Frequency = Auto に復元)

| 項目 | 値 |
|------|-----|
| BIOS 設定変更 | Memory Rank Sparing: Disabled → **Enabled**, Memory Frequency: 1866 → **Auto** |
| テスト対象メモリ | **8.53 GB** (Rank Sparing によりスペアランクが予約され 15.6GB から約半減) |
| パス回数 | 1 |
| エラー数 | **0** |
| 結果 | **PASS** |
| テスト時間 | 約 30 分 (テスト容量が半減したため T1〜T5 より短時間) |
| POST DIMM メッセージ変化 | "Failing DIMM: P2-DIMMA1" は継続 (Rank Sparing 有効化でも P2-DIMMA1 は復活せず) |
| メモリ容量変化 | **15.6GB → 8.53GB** (Rank Sparing がスペアランクとして約半分を予約したため大幅減少) |

### 重要な知見
- **Memory Rank Sparing を有効にするとテスト可能メモリが約半減**: P1-DIMMA1 の有効 DIMM がシングルランクの場合、そのランク全体がスペアとして予約されてしまう。実際には 15.6GB → 8.53GB に減少
- **Rank Sparing は P2-DIMMA1 の障害を補完しない**: 既に BIOS MRC が P2-DIMMA1 を無効化しているため、Rank Sparing の保護対象となるランクはない状態。容量だけが犠牲になる
- **memtest86+ 起動時は 7.65GB、テスト実行中は 8.53GB と微妙に変化**: テスト開始後の認識変化と思われる

### スクリーンショット
- `tmp/1ae6ce03/t6-bios-freq-auto.png` — Memory Frequency = Auto 設定後
- `tmp/1ae6ce03/t6-bios-rank-sparing-enabled.png` — Memory Rank Sparing = Enabled 設定後
- `tmp/1ae6ce03/t6-post-70s.png` — POST 後 GRUB メニュー
- `tmp/1ae6ce03/t6-memtest-start.png` — memtest86+ 起動直後 (7.65GB, Rank Sparing によりメモリ減少)
- `tmp/1ae6ce03/t6-memtest-30min.png` — 30分経過時 (PASS 表示)
- `tmp/1ae6ce03/t6-memtest-result.png` — 1パス完了時 (**PASS**, Errors: 0, Memory: 8.53GB)

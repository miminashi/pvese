# 8号機 VirtualMedia ブート復旧レポート

- **実施日時**: 2026年4月10日 12:51 (JST)
- **対象サーバ**: 8号機 (ayase-web-service-8, Dell PowerEdge R320)
- **比較対照**: 7号機 (ayase-web-service-7, 同型機・正常動作)

## 添付ファイル

- [実装プラン](attachment/2026-04-10_125116_server8_virtualmedia_recovery/plan.md)

## 前提・目的

### 背景

8号機は [BIOS リセット + OS セットアップ 10回反復トレーニング](2026-04-10_035602_bios_os_training_10iter_summary.md) の iter7-9 で **VirtualMedia ブートが永続的に不能**になっていた。症状は EFI ドライバ初期化ループまたは Lifecycle Controller "Collecting System Inventory" での永久停止。`racadm racreset` および 4 回のクリーンブートサイクルでも回復しなかった。

訓練レポートでは復旧手段の候補として「iDRAC Web UI からの完全 BIOS リセット」「BIOS ファームウェア更新」「物理 USB インストール」が挙げられていたが未試行のままだった。

### 目的

1. **詳細な原因調査**: 7号機との設定比較で根本原因を特定する
2. **復旧の達成**: 10個の仮説を順次検証し、非破壊的手段から試行する
3. **再発防止のためのドキュメント整備**: スキルファイルに復旧手順と禁止事項を反映する

### 環境情報

| 項目 | 7号機 (正常) | 8号機 (異常→復旧) |
|------|------------|------------------|
| ハードウェア | Dell PowerEdge R320 | 同左 |
| iDRAC IP | 10.10.10.27 | 10.10.10.28 |
| 静的 IP | 10.10.10.207 | 10.10.10.208 |
| iDRAC FW | 2.65.65.65 | 同左 |
| BIOS | 2.3.3 | 同左 |
| BootMode | UEFI | UEFI (復旧後) |
| VNC | port 5901 / pass `Claude1` | 同左 |
| RAID | PERC H710 / RAID-1 (sda) | 同左 |

## 仮説検証結果サマリ

10 個の仮説を計画したが、診断段階で原因が特定でき、H1-H6 の診断と H10 の修正実行で復旧に成功した。H7-H9 の破壊的手段は不要だった。

| 仮説 | 内容 | 結果 |
|------|------|------|
| H1 | iDRAC jobqueue スタックジョブ | ✅ 完了。両サーバとも全ジョブ Completed、スタックなし |
| H2 | Lifecycle Controller 不正状態 | ✅ 完了。両サーバとも `LC=Ready, RT=Ready` |
| H3 | UefiBootSeq 破損エントリ | ⚠️ **原因特定**。8号機の UefiBootSeq から `Optical.iDRACVirtual.1-1` 相当エントリが欠落 |
| H4 | BootSeq VirtualMedia デバイス欠落 | ⚠️ 同上 (Legacy BootSeq でも欠落) |
| H5 | iDRAC VirtualMedia サブシステム | ✅ 完了。両サーバとも設定同一 (`Enable=Enabled`, `Attached=AutoAttach`) |
| H6 | cfgVirMediaAttached モード | ✅ 完了。両サーバとも `cfgVirMediaAttached=2` |
| H3'修正 | racadm でエントリ追加試行 | ❌ `BOOT018: Specified boot control list is read-only` で拒否 |
| H10 | VNC F2 BIOS Setup + Load Defaults | ✅ **復旧成功**。VirtualMedia ブート再現可能 |
| H7-H9 | NVStore clear / racresetcfg / BIOS reflash | 不要 (H10 で復旧したため未実行) |

## 根本原因

`racadm set BIOS.BiosBootSettings.BootMode` で BootMode を `Uefi` ↔ `Bios` で切り替えると、Dell R320 / iDRAC7 FW 2.65.65.65 / BIOS 2.3.3 では **UefiBootSeq から `Optical.iDRACVirtual.1-1` (VirtualMedia EFI ブートデバイスエントリ) が削除される**。一度削除されると racadm の `set BIOS.BiosBootSettings.UefiBootSeq` でエントリ名を含む値を書き込んでも `BOOT018: Specified boot control list is read-only` で拒否される（BIOS が「未登録のデバイス名」として扱う）。

VirtualMedia デバイスを EFI ブートデバイスとして再登録するには、**BIOS 自身が POST 中にデバイスを再列挙する必要がある**。

### 診断時の比較データ

**復旧前** (8号機):
```
UefiBootSeq=Optical.SATAEmbedded.E-1, RAID.Integrated.1-1, RAID.Integrated.1-1,
            NIC.Embedded.1-1-1, NIC.Embedded.2-1-1, Unknown.Unknown.6-1
```
(6 エントリ、`Optical.iDRACVirtual.1-1` 欠落)

**正常 (7号機, 比較)**:
```
UefiBootSeq=Optical.SATAEmbedded.E-1, RAID.Integrated.1-1, RAID.Integrated.1-1,
            NIC.Embedded.1-1-1, NIC.Embedded.2-1-1, Unknown.Unknown.6-1, Unknown.Unknown.7-1
```
(7 エントリ、最後の `Unknown.Unknown.7-1` が VirtualMedia)

**復旧後** (8号機):
```
UefiBootSeq=Unknown.Unknown.1-1, Optical.iDRACVirtual.1-1, Floppy.iDRACVirtual.1-1,
            Optical.SATAEmbedded.E-1, RAID.Integrated.1-1, NIC.Embedded.1-1-1,
            NIC.Embedded.2-1-1, RAID.Integrated.1-1
```
(8 エントリ、`Optical.iDRACVirtual.1-1` と `Floppy.iDRACVirtual.1-1` が明示的に登録)

## 復旧手順 (確定版)

以下の手順で再現性のある復旧を確認した。

### Phase A: BIOS Load Defaults (VNC 経由)

```sh
# 1. クリーン状態
./scripts/idrac-virtualmedia.sh umount 10.10.10.28
./scripts/idrac-virtualmedia.sh boot-reset 10.10.10.28

# 2. 電源オフ → 電源オン
./pve-lock.sh wait ./oplog.sh ipmitool -I lanplus -H 10.10.10.28 -U claude -P Claude123 chassis power off
sleep 15
./pve-lock.sh wait ./oplog.sh ipmitool -I lanplus -H 10.10.10.28 -U claude -P Claude123 chassis power on

# 3. POST 開始まで 45 秒待ち、F2 連打で BIOS Setup 入場
sleep 45
python3 ./scripts/idrac-kvm-interact.py --bmc-ip 10.10.10.28 sendkeys F2 x30 --wait 2000 \
    --screenshot-each tmp/<sid>/recover-f2 --pre-screenshot

# 4. "System Setup" メニューで Enter (System BIOS 選択)
python3 ./scripts/idrac-kvm-interact.py --bmc-ip 10.10.10.28 sendkeys Enter --wait 2000 \
    --screenshot tmp/<sid>/recover-bios.png

# 5. F3 (Load Defaults) → Enter で確認
python3 ./scripts/idrac-kvm-interact.py --bmc-ip 10.10.10.28 sendkeys F3 --wait 2000 \
    --screenshot tmp/<sid>/recover-f3.png
python3 ./scripts/idrac-kvm-interact.py --bmc-ip 10.10.10.28 sendkeys Enter --wait 2000 \
    --screenshot tmp/<sid>/recover-f3-confirm.png
```

### Phase B: BIOS UI で BootMode を UEFI に復元

Load Defaults 後 BootMode は Bios (Legacy) に戻る。**ここで racadm を使ってはならない**。VNC BIOS Setup の "Boot Settings" → "Boot Mode" を **UEFI** に手動変更する。

VNC 上の操作:
1. System BIOS Settings → "Boot Settings" メニューに移動
2. "Boot Mode" を選択 → 値を **UEFI** に変更
3. Escape → "Finish" → "Yes" で保存して終了

### Phase C: VirtualMedia マウント + 通常電源投入で BIOS に再列挙させる

```sh
# 6. 電源オフ
./pve-lock.sh wait ./oplog.sh ipmitool -I lanplus -H 10.10.10.28 -U claude -P Claude123 chassis power off

# 7. VirtualMedia ISO をマウント (BIOS POST 中にデバイスが見える状態にする)
./scripts/idrac-virtualmedia.sh mount 10.10.10.28 "//10.1.6.1/public/debian-preseed-s8.iso"
./scripts/idrac-virtualmedia.sh verify 10.10.10.28

# 8. 電源オン (boot-once は不要)
./pve-lock.sh wait ./oplog.sh ipmitool -I lanplus -H 10.10.10.28 -U claude -P Claude123 chassis power on

# 9. 5 分待って VirtualMedia から起動していることを VNC で確認
sleep 300
python3 ./scripts/idrac-kvm-interact.py --bmc-ip 10.10.10.28 screenshot tmp/<sid>/vmboot.png
```

### Phase D: 復旧の検証

```sh
# UefiBootSeq に Optical.iDRACVirtual.1-1 が登録されていることを確認
ssh -F ssh/config idrac8 racadm get BIOS.BiosBootSettings.UefiBootSeq
# 期待値: ...,Optical.iDRACVirtual.1-1,Floppy.iDRACVirtual.1-1,... が含まれる
```

`Optical.iDRACVirtual.1-1` が登録されると、エントリは BIOS NVStore に**永続化**される。以降は BIOS Load Defaults を再度実行しない限り、`boot-once VCD-DVD` も正常動作する。

## 再現性検証

復旧後、同じ手順で VirtualMedia ブートを再試行し、以下を確認した:

| 試行 | 結果 |
|------|------|
| 1回目 (復旧直後) | ✅ Debian インストーラ起動成功 (`^[[B^[[A` プログレスバー確認) |
| 2回目 (再現性検証) | ✅ Debian インストーラ起動成功 |

**重要な発見**: 2回目の試行では `boot-once VCD-DVD` を設定しなくても、VirtualMedia がマウントされた状態で電源オンするだけで Debian インストーラが起動した。これは `Optical.iDRACVirtual.1-1` が UefiBootSeq の上位 (position #2) に登録され、HDD よりも優先されているため。OS インストール完了後は `boot-once HDD` または UefiBootSeq の手動調整が必要になる。

## 教訓と再発防止

### 絶対禁止事項 (idrac7 / os-setup スキルに反映済み)

`racadm set BIOS.BiosBootSettings.BootMode <Uefi|Bios>` を**使用してはならない**。

代替: BootMode を変更する必要がある場合は **VNC 経由で BIOS Setup から手動変更**すること。

### 観察された症状パターン (BootMode 破壊後)

| 症状 | 原因 |
|------|------|
| EFI ドライバ初期化ループ (黒画面が継続) | `Optical.iDRACVirtual.1-1` 不在で BIOS が VirtualMedia ドライバを初期化できない |
| LC "Collecting System Inventory" 永久停止 | LC が VirtualMedia デバイスを認識しようとして失敗、リトライループ |
| boot-once VCD-DVD 無視 (HDD にフォールスルー) | BIOS が VCD-DVD デバイスを見つけられず通常 BootSeq にフォールバック |

## スキル更新内容

### `.claude/skills/idrac7/SKILL.md`

- 「R320 固有の注意事項」セクションで BootMode 表記を修正 (UEFI で運用)
- 新規セクション「⚠️ 重大な禁止事項: racadm による BootMode 変更」を追加
- 新規セクション「VirtualMedia ブート復旧手順 (BootMode 破壊からの回復)」を追加 (Phase A-D の詳細手順)

### `.claude/skills/os-setup/SKILL.md`

- 「iDRAC: UEFI モードの確認」セクションに警告ボックスを追加
- racadm BootMode 変更の禁止と VNC BIOS UI での代替手順を記載
- idrac7 スキルの復旧手順へのリンクを追加

## 関連レポート

- [BIOS リセット + OS セットアップ 10回反復トレーニング 最終サマリ](2026-04-10_035602_bios_os_training_10iter_summary.md) — 障害発生の経緯
- [iDRAC SSH セットアップレポート](2026-03-02_052246_dell_r320_idrac_setup.md) — H8 (racresetcfg) フォールバック時の参照手順
- [iDRAC7 ブート順序制御レポート](2026-03-05_200009_idrac7_boot_order_control.md) — ブート制御の基礎情報

## 残存課題

なし。VirtualMedia ブート復旧は完全に達成され、再現性も確認済み。今後同じ問題が発生した場合は、本レポートおよび更新済みスキルファイルの手順で復旧可能。

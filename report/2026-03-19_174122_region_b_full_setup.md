# Region B 構築レポート: iDRAC FW → OS/PVE → LINSTOR ベンチマーク

- **実施日時**: 2026年3月19日 09:00 - 17:40 (JST)
- **セッション ID**: 50074b8a

## 前提・目的

Region B (7/8/9号機, DELL PowerEdge R320) をゼロから稼働可能な状態にし、LINSTOR thick-stripe ベンチマークを実施する。

- **背景**: Region A (4/5/6号機) は構築済み。Region B は iDRAC FW が古く (1.57.57)、IPMI LAN 無効、OS 未インストール
- **目的**: 全自動で Region B を構築し、Region A と性能比較する
- **前提条件**: 8/9号機はパスワード SSH のみ接続可能。7号機は iDRAC FW 2.65.65.65 済み

## 環境情報

### ハードウェア

| 項目 | 仕様 |
|------|------|
| サーバ | DELL PowerEdge R320 x 3台 |
| CPU | Intel Xeon E5-2420 v2 @ 2.20GHz (6C/12T) |
| メモリ | 48 GiB DDR3 1600MHz |
| RAID | PERC H710 Mini (BBU ライトバックキャッシュ付き) |
| ストレージ | 7号機: 8本 SAS HDD (RAID-1 OS + 4x RAID-0 データ), 8/9号機: 4本 SAS HDD (RAID-1 OS + 3x RAID-0 データ) |
| ネットワーク | GbE Ethernet (10.10.10.0/8) |
| iDRAC | iDRAC7 Enterprise |

### ソフトウェア (構築後)

| 項目 | バージョン |
|------|-----------|
| iDRAC FW | 2.65.65.65 |
| OS | Debian 13.3 (Trixie) |
| PVE | 9.1.6 (pve-manager) |
| カーネル | 6.17.13-2-pve |
| DRBD | 9.3.1 |
| LINSTOR | 1.33.1 (Controller on 4号機) |

## 実施手順と結果

### Step 0: SSH 鍵登録 + IPMI LAN 有効化 (所要: ~5分)

paramiko パスワード認証で 8/9号機の iDRAC に接続し、SSH 公開鍵を登録。

**発見**: 8/9号機の `claude` ユーザは index 3 (7号機は index 2)。`racadm getconfig -g cfgUserAdmin -i N` で確認が必要。

```python
# paramiko で接続
c.connect('10.10.10.28', username='claude', password='Claude123', ...)
# ユーザ index 3 に鍵を登録
c.exec_command('racadm sshpkauth -i 3 -k 1 -t "<pub_key>"')
# IPMI LAN を有効化
c.exec_command('racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1')
```

### Step 1: iDRAC FW アップグレード (所要: ~55分)

3段階アップグレード: 1.57.57 → 1.66.65 → 2.20.20.20 → 2.65.65.65

前セッションでダウンロード済みの firmimg.d7 を TFTP サーバ (Docker) で提供し、8/9号機を順次アップグレード。各ステップで TFTP コンテナのマウントファイルを切り替え。

| ステップ | FW バージョン | 8号機 | 9号機 |
|---------|-------------|-------|-------|
| 1 | → 1.66.65 | OK | OK |
| 2 | → 2.20.20.20 | OK | OK |
| 3 | → 2.65.65.65 | OK | OK (初回は `<UNKNOWN>` 表示、60秒後に正常) |

### Step 2: OS + PVE セットアップ (所要: ~4時間)

#### 8/9号機 UEFI モード切替

8/9号機は Legacy BIOS モード。UEFI に切り替えるために:
1. `racadm set BIOS.BiosBootSettings.BootMode Uefi`
2. `racadm jobqueue create BIOS.Setup.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA`

**問題**: 8号機は Lifecycle Controller が無効だったため `racadm set LifecycleController.LCAttributes.LifecycleControllerState 1` が必要。LC 初回初期化 (Collecting System Inventory) に 10-15 分かかった。

**PERC H710 Missing VDs 問題**: PERC コントローラが以前の VD を検出できず "Press any key to continue" プロンプトで POST がブロックされた。SOL 経由で Enter キーを定期送信するスクリプト (`sol-send-enter.py`) で解決。

#### 8/9号機 RAID VD 作成

8/9号機には VD が未作成だった。racadm 経由で作成:
- VD0: RAID-1 (OS用、2ディスク)
- VD1-VD3: RAID-0 (データ用、各1ディスク)

#### OS インストールフロー (各サーバ共通)

1. ISO リマスター (`--serial-unit=0`)
2. iDRAC VirtualMedia マウント + boot-once VCD-DVD
3. SOL Enter 送信 + Debian preseed インストール (10-12分)
4. SOL ログイン → SSH 公開鍵設定 + 静的 IP 設定
5. pre-pve-setup.sh (DHCP ルート修正 + apt)
6. pve-setup-remote.sh pre-reboot + post-reboot

#### idrac-virtualmedia.sh 修正

スクリプトが `idrac7` ホストエイリアスをハードコードしていた問題を修正。BMC IP からホストエイリアスを動的解決するように変更。

### Step 3: PVE クラスタ構築 (所要: ~10分)

```sh
# 7号機でクラスタ作成
ssh -F ssh/config pve7 pvecm create region-b

# 8/9号機をノード間 SSH 鍵設定後に追加
ssh -F ssh/config pve8 pvecm add 10.10.10.207 --use_ssh
ssh -F ssh/config pve9 pvecm add 10.10.10.207 --use_ssh
```

**注意**: `pvecm add` はターゲットノードのパスワード認証が必要。SSH 鍵設定後に `--use_ssh` で回避。

### Step 4: LINSTOR/DRBD セットアップ (所要: ~30分)

1. LINBIT パブリックリポジトリ追加 + パッケージインストール (drbd-dkms 9.3.1, linstor-satellite, linstor-proxmox 等)
2. gcc インストール (DKMS ビルドに必要)
3. DRBD 8.4.11 (カーネル組み込み) を rmmod → DRBD 9.3.1 をロード
4. LVM VG `linstor_vg` 作成 + LINSTOR ストレージプール `striped-pool` 登録
5. リソースグループ `pve-rg-b` 作成 (place-count 2)
6. PVE ストレージ `linstor-storage-b` 追加

**LV ストライプ数の問題**: 7号機 (-i4) と 8/9号機 (-i3) でストライプ数が異なり、LV サイズの微妙な差異で DRBD ピア接続が拒否された。全ノード `-i3` に統一して解決。

#### InfiniBand が DRBD トランスポートに使われなかった件

今回のベンチマークでは DRBD レプリケーションに GbE Ethernet (10.10.10.0/8) を使用した。しかし事後調査の結果、3台とも **Mellanox ConnectX-3 (QDR 40Gb/s) が搭載・認識されており、IB ポートは ACTIVE** であることが判明した。

| 項目 | 状態 |
|------|------|
| PCI デバイス | `0a:00.0 Network controller: Mellanox Technologies MT27500 Family [ConnectX-3]` |
| カーネルドライバ | `mlx4_core` + `mlx4_ib` ロード済み |
| IB デバイス | `/sys/class/infiniband/mlx4_0` 存在 |
| ポート状態 | Port 1: **ACTIVE**, 40 Gb/sec (4X QDR), link_layer: InfiniBand |
| IPoIB インターフェース | **未作成** (`ib_ipoib` モジュール未ロード) |

**使えなかった理由**:

1. **IPoIB モジュール (`ib_ipoib`) が未ロード**: PVE カーネルには `ib_ipoib.ko` が含まれているが、自動ロードされない。`modprobe ib_ipoib` で ib0 インターフェースが作成される
2. **初期調査時に `ip link show type infiniband` が空だったため「IB なし」と判断**: IB デバイス (`/sys/class/infiniband/`) の存在確認をせず、ネットワークインターフェースレベルの確認のみで判断してしまった
3. **PCIe 帯域幅の制約**: dmesg に `16.000 Gb/s available PCIe bandwidth, limited by 5.0 GT/s PCIe x4 link` と表示。R320 は IB カードに PCIe 2.0 x4 スロットしか提供しておらず、QDR 40Gb/s の理論帯域の約40% (16Gb/s) しか利用できない

**今後の対応** (Issue 化を推奨):

- `modprobe ib_ipoib` + IPoIB アドレス設定 (192.168.100.4-6) で IB を DRBD トランスポートに使用可能
- PCIe x4 制約があるものの、GbE (1Gb/s) と比較して **最大16倍の帯域**を利用できる
- 特に Sequential Write (現在 112 MiB/s、GbE 帯域ボトルネック) で大幅な改善が見込まれる
- IB 有効化後にベンチマークを再実施し、GbE vs IPoIB の性能差を定量化すべき

### Step 5: LINSTOR ベンチマーク (所要: ~40分)

詳細は [ベンチマークレポート](2026-03-19_173724_linstor_thick_stripe_benchmark_region_b.md) を参照。

#### fio 結果サマリ

| テスト | Region B | Region A | 倍率 |
|--------|----------|----------|------|
| Random Read 4K QD1 | 418 IOPS | 99 IOPS | 4.2x |
| Random Read 4K QD32 | 3,935 IOPS | 1,191 IOPS | 3.3x |
| Random Write 4K QD1 | 1,938 IOPS | 81 IOPS | **23.9x** |
| Random Write 4K QD32 | 3,691 IOPS | 2,135 IOPS | 1.7x |
| Seq Read 1M QD32 | 431 MiB/s | 239 MiB/s | 1.8x |
| Seq Write 1M QD32 | 112 MiB/s | 87 MiB/s | 1.3x |

Region B が全テストで Region A を上回る。特に Random Write QD1 は PERC H710 の BBU ライトバックキャッシュの効果で 24 倍。

## 発見・知見

| 知見 | 詳細 |
|------|------|
| iDRAC claude ユーザ index | 7号機: index 2, 8/9号機: index 3。サーバにより異なる |
| paramiko ブートストラップ | SSH 鍵未登録の iDRAC にはパスワード認証で鍵登録可能 |
| IPMI LAN デフォルト無効 | 新規 iDRAC7 は IPMI LAN 無効。SSH 経由で有効化が必要 |
| LC 初回初期化 | FW アップグレード後、Lifecycle Controller 初回有効化に 10-15 分 |
| PERC Missing VDs | SOL で Enter 定期送信で通過。POST ブロックだけでなく LC ジョブもブロックする |
| LV ストライプ数統一 | 異なるストライプ数の LV は DRBD ピア接続拒否。全ノード統一が必要 |
| DRBD 8→9 切替 | PVE カーネルに DRBD 8.4.11 が組み込み。rmmod して DKMS の 9.3.1 をロード |
| R320 POST 時間 | LC 初期化含めて 3-5 分。PERC プロンプトがある場合はさらに増加 |
| IB 未使用 | ConnectX-3 QDR 40Gb/s が3台に搭載・ACTIVE だが `ib_ipoib` 未ロードで IPoIB なし。`ip link` のみで判断し IB デバイスの存在確認を怠った。PCIe x4 制約 (16Gb/s) あるが GbE の 16 倍 |

## 反映済みドキュメント

| ファイル | 追記内容 |
|---------|---------|
| `.claude/skills/idrac7/SKILL.md` | SSH 鍵ブートストラップ、PERC Missing VDs、LC 初回有効化 |
| `config/linstor.yml` | 7-9号機の実ディスク構成に更新、IB IP 削除 |
| メモリ `region_b_setup.md` | Region B 完了状態 + ベンチマーク結果サマリ |
| メモリ `MEMORY.md` | iDRAC FW バージョン、claude ユーザ index 情報追加 |

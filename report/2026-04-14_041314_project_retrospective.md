# pvese プロジェクト振り返りレポート

- **対象期間**: 2026年2月22日 〜 2026年4月14日 (52日間)
- **作成日時**: 2026年4月14日 04:13 JST

## 概要統計

| 指標 | 値 |
|------|-----|
| プロジェクト期間 | 52日間 |
| 作成レポート数 | 113件 |
| 管理サーバ台数 | 6台 (2リージョン) |
| 開発スキル数 | 12 |
| 追跡課題数 | 49 (解決済み 42+) |
| OS インストール実行回数 | 100回以上 |
| VM マイグレーション実行回数 | 50回以上 |

## プロジェクトフェーズ

### Phase 1: OS セットアップ自動化の確立 (2/22 - 2/25, 21件)

**目的**: Supermicro X11DPU サーバに Debian 13 + Proxmox VE 9 を完全自動でインストールする仕組みの構築

**経緯と成果**:

初回の手動セットアップ (Debian 12 + PVE 8, 3.5時間) から始まり、Debian 13 + PVE 9 への切替、preseed 自動化、BMC VirtualMedia マウント、SOL (Serial over LAN) モニタリングと段階的に自動化を進めた。4回のスキルテストイテレーションで発見された25件以上の問題を1件ずつ修正し、最終的に **完全無人の Phase 1-8 自動インストール** (約30-55分) を実現した。

**主な技術課題と解決策**:

| 課題 | 解決策 |
|------|--------|
| Redfish VirtualMedia API 不対応 | BMC CGI API による ISO マウント |
| efibootmgr が不正ブートエントリを作成 → POST 92 ハング | efibootmgr 使用を廃止、BIOS 側で管理 |
| SMB パス二重バックスラッシュ → silent failure | yq で config YAML から読み取り |
| PowerState Off の false positive | confirm_powerstate_off() 二重チェック |
| VirtualMedia CSRF silent failure | Redfish verify コマンド追加 |
| SSH 出力欠落 (pve-lock.sh) | fd パターンをサブシェルスコープに変更 |

**成果物**: `os-setup` スキル、`sol-monitor.py`、`sol-login.py`、`bmc-virtualmedia.sh`、`bmc-kvm-screenshot.py` (Playwright)

---

### Phase 2: InfiniBand & LINSTOR/DRBD 評価 (2/25 - 3/1, 16件)

**目的**: InfiniBand ネットワークと LINSTOR/DRBD 分散ストレージの性能・耐障害性評価

**経緯と成果**:

Mellanox SX6036 IB スイッチのシリアルコンソール接続から始まり、内蔵 Subnet Manager のフラッシュ I/O エラーを発見・FW アップデートで修復。IPoIB で 30.6 Gbps (RDMA) / 19.1 Gbps (TCP) のスイッチ経由性能を確認した。

LINSTOR/DRBD では、LVM thin vs thick-stripe の比較で **thick-stripe が 1.2-11.6倍の性能優位** であることを実証。ノード離脱・復帰実験では **VM ゼロダウンタイム** を確認し、ビットマップベースの差分同期は約15秒で完了。DRBD Protocol A/B/C の比較から、IPoIB 環境 (RTT < 0.1ms) では Protocol C が最適と結論。

LVM RAID10 のディスク障害実験では、VM 稼働中のディスク抜去でもサービス継続を確認したが、カーネルバグによるホットリビルド失敗を発見し、運用リスクを文書化した。

マルチリージョン運用の設計として、リージョン間 Protocol A + リージョン内 Protocol C の per-connection 設定が LINSTOR で可能であることを検証。運用スクリプト群と手順書を整備した。

**性能ベンチマーク結果**:

| 構成 | Random Read (QD32) | Random Write (QD1) | Seq Write |
|------|-------------------|-------------------|-----------|
| LVM thin (2ノード) | 270 IOPS | 33 IOPS | - |
| LVM thick-stripe 4disk | 1,185 IOPS | 145 IOPS | 400+ MiB/s |

**成果物**: `ib-switch` スキル、`linstor-bench` スキル、`linstor-node-ops` スキル、マルチリージョン運用ドキュメント

---

### Phase 3: Region B 構築 - Dell R320 対応 (3/1 - 3/10, 21件)

**目的**: Dell PowerEdge R320 (iDRAC7) 3台を Region B として追加し、異種ハードウェアのマルチリージョンクラスタを構築

**経緯と成果**:

6号機 (Supermicro) の追加後、Dell R320 (7号機) への展開を開始。iDRAC7 の SSH 鍵認証確立、FW 1.57→2.65 への3段階アップグレード (TFTP 経由) を実施。

R320 への preseed インストールは **8回連続失敗** という最大の困難に直面した。UEFI/Legacy 互換性、DHCP タイムアウト、PERC H710 の hw-detect ハング (48-67分)、SOL 出力消失など構造的な問題が重層的に発生。VNC インフラの構築、`vga=normal nomodeset` への変更、`preseed/file=/cdrom/preseed.cfg` 方式への切替で一つずつ解決し、9回目で **9分の完全自動インストール** を達成した。

その後、SOL の有効化 (RedirAfterBoot=Enabled, ttyS0)、UEFI モード対応、BootOnce リセット問題の修正を経て、R320 でも Supermicro と同等の自動セットアップを実現。並列セットアップ安定性テスト (サーバ3台 x 5回 = 15回, 成功率100%) で品質を確認した。

**困難の規模**: R320 対応だけで10日間・21レポートを要した (プロジェクト全期間の約19%)

**成果物**: `idrac7` スキル、`idrac7-fw-update` スキル、`dell-fw-download` スキル、`tftp-server` スキル、R320 対応の os-setup スキル更新

---

### Phase 4: 6台フルクラスタ & マイグレーション検証 (3/19 - 3/22, 約12件)

**目的**: 8号機・9号機を追加して6台構成にし、マルチリージョン VM マイグレーションを本格検証

**経緯と成果**:

8号機・9号機の iDRAC FW アップグレード、OS インストール、PVE クラスタ構築を一括実施。Region B で IPoIB を有効化し、**Sequential Write が +228% (112→367 MiB/s)** に改善されたことを確認。IB パーティション分離は MLNX-OS 3.6 の制約で不可のため、IP サブネット分離 (192.168.100.0/24 vs 192.168.101.0/24) で代替した。

マルチリージョン VM マイグレーションを **5イテレーション x 6移動 = 30回** 実行し、全 MD5 チェックサム合格。ライブマイグレーションのダウンタイムは 100ms 未満、コールドマイグレーション (リージョン間) は約12-13分 (GbE ボトルネック)。

BIOS Setup スキルを開発し、KVM スクリーンショット + キーストローク自動化で Supermicro BIOS を遠隔操作可能にした。RAID5/RAID1 耐障害性実験で、PERC H710 RAID-5 および LVM RAID1 での障害回復を検証した。

**マイグレーション実績**:

| 種別 | 回数 | 成功率 | ダウンタイム |
|------|------|--------|------------|
| リージョン内ライブ | 24回 | 100% | 57-93ms |
| リージョン間コールド | 6回 | 100% | 110-238s |

**成果物**: `bios-setup` スキル、`linstor-migration` スキル、マイグレーション自動化スクリプト群

---

### Phase 5: ストレージ最適化 & RAID 評価 (3/28 - 3/30, 約17件)

**目的**: ノード内ディスク冗長化の最適構成を決定し、ZFS 対応を実装

**経緯と成果**:

PERC RAID スキルを開発 (VNC 経由で PERC BIOS を自動操作、30回反復テストで検証)。7-9号機のディスク健康チェックで Blocked ディスク (NETAPP 互換性問題) と 60,000時間超の経年ディスクを発見した。

11種の分散ストレージを調査し、LINSTOR + LVM/ZFS が現構成に最適と結論。LVM RAID1 と ZFS raidz1 を比較ベンチマーク:

| 構成 | Random Read QD32 | Seq Write | 容量効率 |
|------|-----------------|-----------|---------|
| LVM thick-stripe (4disk) | 1,642 IOPS | 253 MiB/s | 100% |
| LVM RAID1 | 239-1,642 IOPS | 157 MiB/s | 50% |
| ZFS raidz1 (ARC有効) | 3,714 IOPS | 178 MiB/s | 75% |
| ZFS raidz1 (ARC無効) | 178 IOPS | 119 MiB/s | 75% |

ZFS raidz1 を採用し、Region A を ZFS に変換。マルチリージョンマイグレーションが ZFS-ZFS 間でも正常動作することを検証。LINSTOR セカンダリコントローラの実験で、Region B がネットワーク分断時に自律運用できることを確認した。

**成果物**: `perc-raid` スキル、ZFS 対応のマルチリージョンセットアップ、ストレージ比較調査レポート

---

### Phase 6: スキルトレーニング & 反復検証 (4/1 - 4/4, 約20件)

**目的**: 全12スキルの操作安定性を大規模反復テストで検証し、知見をフィードバック

**経緯と成果**:

Region B の RAID 再構成・OS 再インストールから開始。14スキルを対象に6イテレーションの初期トレーニングで6件の問題を発見・修正。Region B ブリッジ未作成の問題解決後、Iteration 7-9 を完了。

6号機で DIMM P2-DIMMA1 の Uncorrectable Memory エラーが発生し、BIOS PPR (Post Package Repair) で故障メモリ行をスペア行にリマップして復旧。

最大の成果は **117イテレーション計画の包括的トレーニング** (約3時間17分):
- Phase 1-12 の全操作カテゴリを3回ずつ実施
- 成功率 100% (一部手動リカバリあり)
- ライブマイグレーション: 9回成功、平均ダウンタイム 79-82ms
- ノード障害回復: 12回成功、VM 中断ゼロ
- LINSTOR コントローラ障害でも DRBD データパスは独立継続することを確認

**成果物**: トレーニング総合レポート、スキル更新3件、スクリプトバグ修正1件

---

### Phase 7: BIOS/OS 反復テスト & 安定化 (4/4 - 4/14, 約17件)

**目的**: BIOS リセット + OS 再セットアップを各サーバ10回繰り返し、エッジケースを洗い出して安定化

**経緯と成果**:

全6台で BIOS デフォルトロード → OS セットアップの10回反復テストを実施。成功率 **90% (54/60)** で、以下の重大な問題を発見・解決した:

| 発見した問題 | 影響 | 解決策 |
|-------------|------|--------|
| iDRAC7 SOL シリアルヒストリバッファの流制御デッドロック | sol-monitor ハング | cfgSerialHistorySize=0 |
| racadm BootMode 変更で VirtualMedia エントリ消失 | ブート不能 | F3 + BIOS UI での BootMode 変更 |
| 6号機 DIMM エラーで EFI カーネル展開失敗 | インストール不可 | BIOS PPR (Hard PPR) で修復 |
| sol-monitor.py の false positive (stage 未観測) | 偽成功判定 | exit code 4 追加、/etc/machine-id mtime 検証 |
| grub-install UEFI NVRAM 枯渇 | インストール間欠失敗 | preseed early_command で Boot エントリ削除 |

特に **UEFI NVRAM 枯渇** は R320 の grub-install 間欠失敗の根本原因であり、NVRAM が蓄積された EFI Boot エントリで満杯になるという問題だった。preseed の early_command で既存エントリを削除するスクリプトを挿入し、3/3連続成功を実証した。

**成果物**: SOL monitor 修正、NVRAM 枯渇対策、VirtualMedia 復旧手順

---

## 主要な成果まとめ

### 1. 完全自動 OS セットアップ

BMC VirtualMedia 経由で preseed ISO をマウントし、SOL モニタリングで進捗を追跡、PVE インストールまでを完全自動化。Supermicro (4-6号機) と Dell R320 (7-9号機) の異種ハードウェアに対応。

- インストール時間: 30-55分 (サーバ・状態による)
- 並列3台同時セットアップ: 15/15 成功 (100%)
- BIOS リセット込み10回反復: 54/60 成功 (90%)

### 2. LINSTOR/DRBD マルチリージョン VM 運用基盤

2+1 トポロジー (リージョン内2レプリカ + リージョン間1 DR コピー) で、リージョン内ゼロダウンタイム・リージョン間 DR を実現する宣言的マルチリージョン VM 運用基盤を構築。

- リージョン内ライブマイグレーション: ダウンタイム < 100ms
- リージョン間コールドマイグレーション: 110-238秒
- ノード障害時 VM 継続: 100% (コントローラ障害含む)
- DRBD 差分同期: 15-54秒

### 3. 12の再利用可能スキル

| スキル | 用途 |
|--------|------|
| os-setup | Debian + PVE 自動インストール |
| bios-setup | Supermicro BIOS 遠隔操作 |
| ib-switch | SX6036 IB スイッチ管理 |
| linstor-migration | ライブ/コールドマイグレーション |
| linstor-bench | ストレージベンチマーク |
| linstor-node-ops | ノード離脱・復帰 |
| perc-raid | PERC H710 RAID 操作 |
| idrac7 | iDRAC7 基本管理 |
| idrac7-fw-update | iDRAC7 FW アップグレード |
| dell-fw-download | Dell FW ダウンロード |
| tftp-server | Docker TFTP サーバ |
| playwright | ブラウザ自動化 |

### 4. ストレージ構成の選定

11種の分散ストレージを調査し、LINSTOR + ZFS raidz1 を採用。容量効率 75%、ARC キャッシュによる読み取り高速化、raidz1 による書き込みホール保護を両立。

---

## 技術的な知見・教訓

### ハードウェア固有の問題

1. **4号機 POST 92 スタック**: PVE カーネルリブート後に PCI bus init でスタックする傾向。ForceOff → 20秒待機 → Power On で回復。ハードウェア固有で他号機では未発生
2. **6号機 DIMM 障害**: Uncorrectable Memory エラー。BIOS PPR (Hard PPR) でスペア行リマップにより復旧
3. **R320 UEFI NVRAM 枯渇**: grub-install が EFI Boot エントリを蓄積し NVRAM が満杯に。preseed early_command で事前削除
4. **PERC H710 Blocked ディスク**: NETAPP 製ディスクの互換性問題。RAID VD 作成不可
5. **SX6036 フラッシュ I/O エラー**: 内蔵 SM 起動失敗。FW アップデート (3.6.8008→3.6.8012) で修復

### 自動化の限界と対処

1. **BMC POST code API の stale 値**: 電源状態と無関係に 0x00/0x01 を返す。KVM スクリーンショットでの実画面確認が必須
2. **VirtualMedia の CSRF silent failure**: マウント API が成功を返すが実際にはマウントされない。Redfish verify で検出
3. **SOL モニタリングの限界**: R320 では SOL が特定フェーズで出力を返さない。VNC フォールバックで対処
4. **racadm BootMode 変更の副作用**: VirtualMedia ブートエントリが消失。BIOS UI での変更が安全

### ストレージ評価の結論

| 判断ポイント | 結論 |
|-------------|------|
| ノード間冗長化 | DRBD Protocol C (IPoIB 環境で性能影響なし) |
| ノード内ディスク冗長化 | ZFS raidz1 (容量効率 75%、書き込みホール保護あり) |
| LVM RAID10 | 運用リスク高 (カーネルバグ、minIoSize 不整合)。非推奨 |
| PERC H710 RAID5 | 書き込みホール脆弱性あり。RAID-0 + DRBD が安全 |
| LVM thin provisioning | CoW オーバーヘッドで thick-stripe 比 1.2-11.6倍遅い。非推奨 |

---

## 未解決課題

| Issue | 状態 | 内容 |
|-------|------|------|
| #36 | plan | tftp-server Docker コンテナのローカル UDP テスト不応答 |
| #37 | plan | dell-fw-download の GEO IP リダイレクト問題 |
| #42-44 | active | 8/9/5号機の BIOS リセット + OS セットアップ 10回通しテスト (残り) |
| #47 | plan | 7号機 NVRAM 枯渇の恒久対策 |
| #48 | plan | preseed 診断 visibility の改善 (UDP syslog) |
| #49 | plan | sol-monitor の grub-install modal dialog 検出 |

---

## 数値サマリ

### レポート分布

| 月 | レポート数 | 主な活動 |
|----|-----------|---------|
| 2月 (22-28) | 35件 | OS 自動化、IB/LINSTOR 評価 |
| 3月 | 49件 | Region B 構築、6台クラスタ、RAID/ZFS 評価 |
| 4月 (1-14) | 29件 | スキルトレーニング、反復テスト、安定化 |

### サーバ別 OS インストール回数 (推定)

| サーバ | インストール回数 | 特記事項 |
|--------|---------------|---------|
| 4号機 | 15-20回 | POST 92 スタック頻発 |
| 5号機 | 10-15回 | 最も安定 |
| 6号機 | 10-15回 | DIMM 障害、PXE ブートループ |
| 7号機 | 15-20回 | SOL デッドロック、UEFI/Legacy 切替 |
| 8号機 | 8-12回 | VirtualMedia 復旧、Blocked ディスク |
| 9号機 | 8-12回 | Blocked ディスク |

### 開発資産

| 種別 | 数量 |
|------|------|
| スキル (SKILL.md) | 12 |
| シェルスクリプト (scripts/) | 20+ |
| Python ツール (tools/) | 5+ |
| 運用ドキュメント (docs/) | 5+ |
| config ファイル | 7 (linstor.yml + server*.yml x6) |

---

## 総括

pvese プロジェクトは52日間で、**6台の異種ハードウェアサーバを2リージョンのマルチリージョン LINSTOR/DRBD クラスタとして構築・運用する基盤** を確立した。

最大の成果は、OS セットアップからストレージ構成、VM マイグレーション、障害回復までの一連の運用操作を **再現可能なスキルとスクリプトとして体系化** したことにある。100回以上の OS インストール、50回以上の VM マイグレーション、数十回のノード障害シミュレーションを通じて、エッジケースを洗い出し、自動化の信頼性を段階的に向上させた。

最大の困難は Dell R320 への preseed 対応 (8回連続失敗からの回復) と、ハードウェア固有の間欠障害 (POST 92 スタック、NVRAM 枯渇、DIMM 障害) であった。これらは反復テストによって初めて顕在化する類の問題であり、大規模反復テストの価値を実証した。

残る課題は限定的で、主に特定サーバの反復テスト残数と、診断ツールの改善である。基盤としてのマルチリージョン VM 運用は安定稼働状態にある。

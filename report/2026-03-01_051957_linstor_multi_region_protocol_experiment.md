# LINSTOR マルチリージョン per-connection protocol 実験レポート

- **実施日時**: 2026年3月1日 05:19
- **Issue**: #29

## 前提・目的

マルチリージョン DRBD/LINSTOR 構成において、同一リージョン内は Protocol C (同期)、異なるリージョン間は Protocol A (非同期) を per-connection で設定可能かを検証する。

- **背景**: 地理的に離れたリージョン間での DRBD レプリケーションは、WAN レイテンシにより Protocol C が非実用的。per-connection でプロトコルを使い分ける運用が求められる
- **目的**: DRBD 9 / LINSTOR 1.33.1 で per-connection protocol 設定の可否と制約を実証する
- **前提条件**: 2 ノード構成 (ayase-web-service-4, ayase-web-service-5)。実リージョン分離はないが、per-connection 設定の実証は可能

### 参照レポート

- [DRBD Protocol 比較レポート](2026-02-27_074430_drbd_protocol_comparison.md)
- [LINSTOR DRBD ベンチマーク](2026-02-26_052044_linstor_drbd_benchmark.md)

## 環境情報

| 項目 | 値 |
|------|-----|
| Node 4 | ayase-web-service-4 (10.10.10.204) |
| Node 5 | ayase-web-service-5 (10.10.10.205) |
| DRBD | 9.3.0 |
| LINSTOR | 1.33.1 |
| DRBD transport | TCP over IPoIB (192.168.100.x) |
| Resource Group | pve-rg (Protocol C, quorum=off, auto-promote=yes, allow-two-primaries=yes) |
| リソース | pm-c0401219 (550GB, InUse/Primary on N4), vm-100-cloudinit (小容量) |
| ストレージ | LVM thick stripe (4 x 500GB SATA HDD) |

## 用語解説: allow-two-primaries (デュアルプライマリモード)

### DRBD の Primary / Secondary ロール

DRBD はブロックデバイスレベルのレプリケーションを行う。各ノードは以下のいずれかのロールを持つ:

| ロール | 読み取り | 書き込み | 用途 |
|--------|---------|---------|------|
| **Primary** | 可 | 可 | VM やファイルシステムがアクティブに使用 |
| **Secondary** | 不可 | 不可 (レプリケーション受信のみ) | スタンバイ。障害時に Primary に昇格 |

通常 (`allow-two-primaries no`) は、同時に Primary になれるノードは **1 つだけ**。もう一方のノードが Primary に昇格しようとすると拒否される。

### allow-two-primaries の機能

`allow-two-primaries yes` を設定すると、**2 つのノードが同時に Primary ロール**を持つことが許可される。これは「デュアルプライマリモード」と呼ばれる。

主な用途:

1. **PVE ライブマイグレーション**: VM を停止せずに別ノードに移行する際、移行中に一時的に両ノードが DRBD デバイスを open する。`auto-promote yes` と組み合わせると、open した瞬間に自動で Primary に昇格するため、**ライブマイグレーション中は一時的にデュアルプライマリ状態**になる
2. **クラスタファイルシステム (OCFS2, GFS2)**: 分散ロックマネージャ (DLM) と組み合わせて、両ノードから同時にファイルシステムをマウント・アクセスする構成

### ライブマイグレーション時のフロー

```
時刻    Node A (移行元)         Node B (移行先)
─────  ─────────────────       ─────────────────
 t0    Primary (VM稼働中)      Secondary
 t1    Primary                 Primary に昇格 (VM メモリ受信開始)
 t2    ◄── 一時的デュアルプライマリ (VM メモリ転送中) ──►
 t3    Secondary に降格        Primary (VM稼働中)
       (VM の close で自動降格)
```

`allow-two-primaries no` の場合、t1 の時点で Node B の Primary 昇格が拒否され、ライブマイグレーションが失敗する。

### Protocol C が必須である理由

DRBD 開発者の Lars Ellenberg による説明:

> "cluster file system deals with cache coherence, DRBD has to deal with **storage coherence**. you cannot do that asynchronously."

デュアルプライマリモードでは、両ノードが同一のブロックデバイスに対して読み書きを行う可能性がある。DRBD が保証すべきは**ストレージコヒーレンシ** (両ノードのディスク上のデータが同一であること) であり、これには完全同期 (Protocol C) が必要:

| プロトコル | 書き込み完了条件 | デュアルプライマリ時の問題 |
|-----------|----------------|----------------------|
| **A** (非同期) | ローカルディスク書き込み + TCP バッファ投入 | ピアのディスクに未到達の書き込みがある → **ピアが古いデータを読む** |
| **B** (メモリ同期) | ローカルディスク書き込み + ピアメモリに到達 | ピアのメモリには到達したがディスクに未書き込み → **ピアがディスクから古いデータを読む** (インフライトデータの読み取りは未実装) |
| **C** (完全同期) | ローカルディスク書き込み + **ピアディスク書き込み** | 両ノードのディスクが常に同一 → **安全** |

### データ整合性の責任分担

DRBD デュアルプライマリは「同時に書いても安全」ではなく、「同時に Primary になれる」だけ:

| 層 | 責任 | 仕組み |
|----|------|--------|
| **DRBD (Protocol C)** | ストレージコヒーレンシ | 書き込みが両ノードのディスクに到達するまで完了しない |
| **ハイパーバイザ (PVE)** | 排他制御 | ライブマイグレーション中、移行元と移行先が同時に書き込まないよう制御 |
| **クラスタ FS (OCFS2 等)** | キャッシュコヒーレンシ | DLM でブロックレベルのロックを管理 |
| **DRBD カーネルモジュール** | 最終防衛線 | 同一ブロックへの同時書き込みを検出して `-EBUSY` を返す |

通常のファイルシステム (ext4, XFS) をデュアルプライマリで使うと**即座にファイルシステムが破壊される**。PVE 環境ではハイパーバイザが排他制御を行うため安全に動作する。

### マルチリージョン構成との関係

| 構成 | allow-two-primaries | Protocol | ライブマイグレーション |
|------|-------------------|----------|-------------------|
| リージョン内 (LAN) | yes | C (同期) | **可** |
| リージョン間 (WAN) | **no** (必須) | A (非同期) | **不可** (フェイルオーバーのみ) |

リージョン間では WAN レイテンシにより Protocol C が非実用的 → Protocol A を使用 → Protocol A は allow-two-primaries no を要求 → ライブマイグレーション不可。これは技術的必然であり、回避策はない。

リージョン間の VM 移行はコールドマイグレーション (VM 停止 → 移行先で起動) またはフェイルオーバー (障害時に DR サイトで起動) で行う。

## 実験結果

### Phase 1: 現状記録

初期状態:
- 両リソースとも Protocol C, allow-two-primaries=yes
- resource-connection / node-connection にカスタムプロパティなし
- 両ノード UpToDate

### Phase 2: node-connection Protocol A 設定 (失敗→成功)

#### 試行 1: LINSTOR node-connection drbd-peer-options --protocol A (失敗)

```sh
linstor node-connection drbd-peer-options ayase-web-service-4 ayase-web-service-5 --protocol A
```

**結果**: LINSTOR プロパティの設定は成功したが、DRBD の adjust が失敗。

```
pm-c0401219: Failure: (139) Protocol C required
Command 'drbdsetup net-options pm-c0401219 0 ... --protocol=A' terminated with exit code 10
```

**原因**: `allow-two-primaries yes` が設定されている場合、**DRBD カーネルモジュールは Protocol C を強制する**。Protocol A/B ではデュアルプライマリモードが成立しないため。

#### 試行 2: 手動 disconnect + .res ファイル編集 + connect (部分的成功)

```sh
drbdadm disconnect pm-c0401219  # 両ノード
sed -i 's/protocol C/protocol A/g' /var/lib/linstor.d/pm-c0401219.res  # 両ノード
drbdadm connect pm-c0401219  # 両ノード
```

接続は成功し UpToDate になったが、`drbdsetup show --show-defaults` で確認すると **protocol C のまま**。

**原因**: `drbdadm connect` は既存のピア設定 (カーネル内) を使って接続する。ピア設定はリソースロード時 (`drbdadm up`) に決定され、connect/disconnect では変わらない。

#### 試行 3: disconnect + del-peer + adjust (失敗)

```sh
drbdadm disconnect pm-c0401219  # 両ノード
drbdsetup del-peer pm-c0401219 1  # サーバ4
drbdsetup del-peer pm-c0401219 0  # サーバ5
drbdadm adjust pm-c0401219  # 両ノード
```

**結果**: `drbdsetup new-peer pm-c0401219 1 ... --protocol=A` が同じ error 139 で失敗。`allow-two-primaries yes` が .res ファイルのグローバル net セクションに残っているため。

#### 試行 4: disconnect + del-peer + allow-two-primaries no + adjust (成功)

.res ファイルの `allow-two-primaries` を `no` に変更してから adjust:

```sh
sed -i 's/allow-two-primaries yes/allow-two-primaries no/g' /var/lib/linstor.d/pm-c0401219.res
sed -i 's/protocol C/protocol A/g' /var/lib/linstor.d/pm-c0401219.res
drbdadm disconnect pm-c0401219
drbdsetup del-peer pm-c0401219 1
drbdadm adjust pm-c0401219
```

**結果**: 成功。`drbdsetup show --show-defaults` で `protocol A;` を確認。

### Phase 3: resource-connection Protocol A 設定 (成功)

Phase 2 の手動変更を Protocol C に復元後、LINSTOR の `resource-connection drbd-peer-options` で Protocol A + allow-two-primaries no を**同時に**設定:

```sh
linstor resource-connection drbd-peer-options \
  ayase-web-service-4 ayase-web-service-5 pm-c0401219 \
  --protocol A --allow-two-primaries no
```

**結果**: **ライブ接続上でプロトコル変更が成功！**

```
drbdsetup show --show-defaults pm-c0401219 | grep protocol
    protocol        	A;
```

同時に vm-100-cloudinit は Protocol C / allow-two-primaries=yes のまま変更なし:

```
drbdsetup show --show-defaults vm-100-cloudinit | grep protocol
    protocol        	C; # default
```

**リソースごとに異なるプロトコルが同一ノードペア間で共存することを確認。**

LINSTOR が生成した .res ファイルの connection セクション:

```
connection
{
    net
    {
        allow-two-primaries no;    # overrides value 'yes' from RD (pm-c0401219)
        protocol A;                # overrides value 'C' from RG (pve-rg)
    }
    ...
}
```

### Phase 4: Aux/site プロパティ設定 (成功)

```sh
linstor node set-property ayase-web-service-4 Aux/site region-a
linstor node set-property ayase-web-service-5 Aux/site region-b
```

**結果**: 正常に設定。ノードプロパティで確認可能。DRBD 動作に影響なし。

```
linstor node list-properties ayase-web-service-4
| Aux/site | region-a |

linstor node list-properties ayase-web-service-5
| Aux/site | region-b |
```

### Phase 5: 復元 (成功)

```sh
# Protocol C + allow-two-primaries yes に復元
linstor resource-connection drbd-peer-options \
  ayase-web-service-4 ayase-web-service-5 pm-c0401219 \
  --protocol C --allow-two-primaries yes

# resource-connection オーバーライドプロパティを削除
linstor resource-connection set-property \
  ayase-web-service-4 ayase-web-service-5 pm-c0401219 \
  DrbdOptions/Net/protocol
linstor resource-connection set-property \
  ayase-web-service-4 ayase-web-service-5 pm-c0401219 \
  DrbdOptions/Net/allow-two-primaries
```

すべての設定が初期状態に復元されたことを確認。Aux/site プロパティは残置 (害なし)。

## 発見事項

### 1. allow-two-primaries と Protocol の排他制約

**DRBD カーネルモジュールは `allow-two-primaries yes` と Protocol A/B の共存を許可しない。**

| allow-two-primaries | Protocol A | Protocol B | Protocol C |
|---------------------|-----------|-----------|-----------|
| yes | **不可** (error 139) | **不可** (error 139) | 可 |
| no | 可 | 未検証 (A と同様に可能と推測) | 可 |

**理由**: デュアルプライマリモードでは両ノードが同時に書き込みを行うため、データの一貫性を保つには同期レプリケーション (Protocol C) が必須。Protocol A/B ではレプリケーション遅延中にデータ不整合が生じる。

**マルチリージョン構成への影響**:
- リージョン間 Protocol A 接続では `allow-two-primaries no` が必須
- リージョン間のライブマイグレーションは不可 (デュアルプライマリが必要)
- リージョン間はフェイルオーバー (Secondary → Primary 昇格) のみ可能

### 2. LINSTOR per-connection protocol 変更の正しい手順

| 手順 | 結果 |
|------|------|
| `--protocol A` のみ設定 (allow-two-primaries yes のまま) | **失敗** — DRBD カーネルが拒否 |
| 手動 disconnect → connect (.res 編集) | **失敗** — connect ではプロトコル変更不可 |
| 手動 disconnect → del-peer → adjust (.res 編集、allow-two-primaries no) | **成功** — ピア再作成で適用 |
| `--protocol A --allow-two-primaries no` 同時設定 | **成功** — ライブで適用 |

**推奨手順**: LINSTOR の `resource-connection drbd-peer-options` で `--protocol` と `--allow-two-primaries` を**同時に**設定する。

```sh
# Protocol A に変更 (リージョン間接続)
linstor resource-connection drbd-peer-options <nodeA> <nodeB> <resource> \
  --protocol A --allow-two-primaries no

# Protocol C に戻す (リージョン内接続)
linstor resource-connection drbd-peer-options <nodeA> <nodeB> <resource> \
  --protocol C --allow-two-primaries yes
```

### 3. LINSTOR 設定階層とオーバーライド

LINSTOR は以下の優先順位で DRBD オプションを適用:

```
resource-connection > node-connection > resource-definition > resource-group > controller
```

`.res` ファイルにはオーバーライド元がコメントで明示される:

```
protocol A;    # overrides value 'C' from RG (pve-rg)
```

### 4. drbdadm connect vs del-peer/new-peer

| 操作 | 効果 |
|------|------|
| `drbdadm disconnect` + `drbdadm connect` | 接続を切断/再接続するが、カーネル内のピア設定は変わらない |
| `drbdsetup del-peer` + `drbdadm adjust` | ピアを削除して再作成。設定変更が反映される |
| `drbdsetup net-options` | ライブで net オプションを変更。protocol 変更は allow-two-primaries との整合性が必要 |

## マルチリージョン構成の推奨アーキテクチャ

実験結果に基づく推奨構成:

```
Region A (Tokyo)                    Region B (Osaka)
┌─────────────────────┐             ┌─────────────────────┐
│ PVE Cluster A       │             │ PVE Cluster B       │
│ ┌───────┐ ┌───────┐ │ Protocol A  │ ┌───────┐ ┌───────┐ │
│ │Node A1│─│Node A2│─│─────────────│─│Node B1│─│Node B2│ │
│ └───────┘ └───────┘ │ (async, no  │ └───────┘ └───────┘ │
│   Protocol C (sync) │  dual-pri)  │   Protocol C (sync) │
│   allow-2pri: yes   │             │   allow-2pri: yes   │
└─────────────────────┘             └─────────────────────┘
    Aux/site=region-a                   Aux/site=region-b
```

| 項目 | リージョン内 | リージョン間 |
|------|------------|------------|
| Protocol | C (同期) | A (非同期) |
| allow-two-primaries | yes | **no** |
| ライブマイグレーション | 可 | **不可** |
| フェイルオーバー | 可 | 可 (手動/自動) |
| Corosync | < 5ms RTT 推奨 | 不要 (独立クラスタ) |
| PVE 管理 | 単一クラスタ | PDM で統合管理 |

### LINSTOR 設定例 (4ノード、2リージョン)

```sh
# サイト属性設定
linstor node set-property nodeA1 Aux/site region-a
linstor node set-property nodeA2 Aux/site region-a
linstor node set-property nodeB1 Aux/site region-b
linstor node set-property nodeB2 Aux/site region-b

# リージョン間接続: Protocol A + allow-two-primaries no
# (リージョンA ↔ リージョンB の全ノードペア、各リソースに設定)
for resource in $(linstor resource list --output-version=v1 | jq -r '.[].resources[].name' | sort -u); do
  for nodeA in nodeA1 nodeA2; do
    for nodeB in nodeB1 nodeB2; do
      linstor resource-connection drbd-peer-options $nodeA $nodeB $resource \
        --protocol A --allow-two-primaries no
    done
  done
done

# リージョン内接続はデフォルト (Protocol C) のままでよい
```

## 結論

1. **DRBD 9 / LINSTOR は per-connection protocol 設定をサポートする** — 同一ノードペア間でもリソースごとに異なるプロトコルを設定可能
2. **Protocol A/B は `allow-two-primaries no` を要求する** — デュアルプライマリモードは Protocol C でのみ動作
3. **LINSTOR の `resource-connection drbd-peer-options` で `--protocol` と `--allow-two-primaries` を同時設定すればライブで変更可能** — disconnect/reconnect は不要
4. **マルチリージョン構成ではリージョン間のライブマイグレーションが不可** — フェイルオーバーのみ。これは Protocol A の本質的な制約
5. **Aux/site プロパティでノードにリージョン属性を付与可能** — 配置ルール制御に活用できる

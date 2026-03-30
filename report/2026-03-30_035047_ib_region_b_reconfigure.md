# Region B IPoIB 再設定 (8号機・9号機)

- **実施日時**: 2026年3月30日 (JST)

## 添付ファイル

なし

## 前提・目的

### 背景

ZFS raidz1 ベンチマーク (2026-03-30) で、9号機に IPoIB インターフェースが設定されておらず IB ベンチマークを実施できなかった。8号機も同様に IB 未設定。7号機は設定済みだが datagram モード (MTU 2044) で永続設定なし。

### 目的

1. 8号機・9号機の IPoIB 再設定 (connected mode, MTU 65520, 永続化)
2. 7号機の connected mode 統一 + 永続化
3. LINSTOR ノードインターフェース・PrefNic 修正
4. スクリプト・スキルへのフィードバック

## 調査結果

### 原因

| サーバ | 状態 | 原因 |
|--------|------|------|
| 7号機 | ibp10s0 UP, datagram MTU 2044, 永続設定なし | `ib-setup-remote.sh` を `--persist` なしで実行。リブート未経験のため残存 |
| 8号機 | `ib_ipoib` 未ロード, IPoIB インターフェースなし | OS 再インストール後に IB セットアップ未実施 |
| 9号機 | `ib_ipoib` 未ロード, IPoIB インターフェースなし | OS 再インストール後に IB セットアップ未実施 |

全3台とも `mlx4_core` + `mlx4_ib` はロード済み (HCA 認識済み)。IB スイッチのポート (IB1/7, IB1/9, IB1/11) も Active 40 Gbps QDR。ハードウェアは正常で、`ib_ipoib` モジュールのロードと IP 設定が欠落していた。

### `ib-setup-remote.sh` の race condition

初回 `modprobe ib_ipoib` 実行時、カーネルがインターフェースを `ib0` として作成した直後に udev が `ibp10s0` にリネームする。スクリプトの検出ループが udev リネーム前に実行されると `ib0` を検出するが、`ip link set ib0 up` 時点では既に `ibp10s0` にリネーム済みでエラーとなる。

対策: `modprobe` 後に `sleep 2` を追加。

## 実施内容

### Step 1: IPoIB セットアップ

`ib-setup-remote.sh --ip <IP>/24 --mode connected --mtu 65520 --persist` を全3台で実行:

| サーバ | IP | インターフェース | 結果 |
|--------|-----|-----------------|------|
| 7号機 | 192.168.101.7/24 | ibp10s0 | 成功 (datagram → connected 変更 + 永続化) |
| 8号機 | 192.168.101.8/24 | ibp10s0 | 成功 (初回 race condition で失敗、再実行で成功) |
| 9号機 | 192.168.101.9/24 | ibp10s0 | 成功 (初回 race condition で失敗、再実行で成功) |

### Step 2: IPoIB 疎通確認

| ペア | RTT (安定時) |
|------|-------------|
| 7→8 | 0.125 ms |
| 7→9 | 0.167 ms |
| 8→9 | 0.156 ms |

全ペア 0% パケットロス。

### Step 3: LINSTOR 設定修正

| 操作 | 対象 | 結果 |
|------|------|------|
| node interface create | 9号機 ibp10s0 192.168.101.9 | 新規登録 (7・8号機は登録済み) |
| PrefNic 設定 | 9号機 → ibp10s0 | 設定完了。DRBD リソース自動 adjust |
| PrefNic 設定 | 7号機 → ibp10s0 | 設定完了 (default → ibp10s0)。DRBD リソース自動 adjust |

PrefNic 変更により、LINSTOR が自動で `drbdadm adjust` 相当を実行し、DRBD リソース `pm-e78bd992` (7号機↔9号機) が IB 経由に切り替わった。

### Step 4: スクリプト・スキル更新

| ファイル | 変更内容 |
|---------|---------|
| `scripts/ib-setup-remote.sh` | `modprobe ib_ipoib` 後に `sleep 2` 追加 (udev リネーム race condition 対策) |
| `.claude/skills/linstor-node-ops/SKILL.md` | N7 セクション: `ib-setup-remote.sh --persist` 推奨に更新 |
| `.claude/skills/linstor-bench/SKILL.md` | 前提条件 #4 に IB 確認コマンド追記 |
| `.claude/skills/os-setup/SKILL.md` | Phase 8 に IB セットアップ手順追加 |

## 最終状態

```
LINSTOR ノード: Region B 全3台 Online
DRBD pm-e78bd992: 7号機 (InUse) ↔ 9号機 (UpToDate), Conns=Ok
PrefNic: 7号機=ibp10s0, 8号機=ibp10s0, 9号機=ibp10s0
IPoIB: 全3台 connected mode, MTU 65520, /etc/network/interfaces.d/ib0 永続化済み
```

## 教訓

1. **OS 再インストール後は IB セットアップを忘れずに実行する** — os-setup スキルに手順追加済み
2. **`--persist` を常に付ける** — リブート後の手動復旧を防止
3. **`modprobe` 後の udev リネームには時間がかかる** — `sleep 2` で安定化

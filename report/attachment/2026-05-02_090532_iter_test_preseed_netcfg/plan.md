# 残タスク対応プラン: preseed netcfg レポート (RTC 以外)

## Context

`report/2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix.md` の **残タスク** 4 項目のうち、ユーザ指示により「10号機 RTC バッテリ交換 or 起動時 NTP 強制同期」**以外**の 3 項目に着手する。

| # | 残タスク | 優先度 | 本プランで対応 |
|---|---------|--------|---------------|
| A | `config/server10.yml` 注釈の修正 (`/dev/sda` コメント) | 中 | ✅ |
| B | bios-setup スキル reference.md に LSI HBA OPROM 詳細追記 | 低 | ✅ |
| C | iter2-3 反復通しテスト (preseed 自動再現性) | 低 | ✅ |
| D | 10号機 RTC バッテリ問題 | 中 | ❌ (除外) |

3 タスクとも前任レポートの「副次発見」「継続課題」が起点。A/B は数分のドキュメント修正、C は preseed 修正の自動再現性を実機反復で検証する作業（30分/サイクル × 2 = 約 1 時間）。

## タスクA: `config/server10.yml` の disk コメント修正

### 現状 (lines 39-42)

```yaml
# Target disk - SATA SSD on the LSI/onboard controller (not NVMe).
# Verified 2026-04-30 via d-i shell: 240 GB sd 0:0:0:0 [sda].
# Nutanix NX-1065-G5 ships with SATA SSDs, NOT NVMe like the X11DPU servers.
disk: /dev/sda
```

「LSI/onboard controller」は曖昧で、誤って PCH SATA と解釈される可能性がある。実際の経路は **LSI SAS HBA 経由 (mpt3sas ドライバ)** で、PCH SATA / sSATA は BIOS Setup 上で全 "Not Installed"。

### 修正後

```yaml
# Target disk - SATA SSD behind the LSI SAS HBA (mpt3sas driver), not PCH SATA.
# Verified 2026-04-30 via d-i shell: 240 GB sd 0:0:0:0 [sda].
# Nutanix NX-1065-G5 ships with SATA SSDs, NOT NVMe like the X11DPU servers.
# NOTE: BIOS "LSI HBA OPROM" must be Enabled for Legacy disk first boot
# (see .claude/skills/bios-setup/reference.md, Issue #53).
disk: /dev/sda
```

意図:
- 「LSI SAS HBA 経由」を明記し、PCH SATA との混同を防ぐ
- LSI HBA OPROM Enabled が disk first boot に必須である事実をクロスリファレンス（タスク B / メモリ `server10_lsi_hba_oprom.md` と整合）

## タスクB: `.claude/skills/bios-setup/reference.md` に LSI HBA OPROM の Why/How 追記

### 現状 (lines 1400-1403)

```markdown
#### LSI HBA OPROM
- **オプション**: Disabled / Legacy / EFI (推定)
- **10号機の現在値**: Disabled
- **解説**: X10DRT-P 内蔵 LSI HBA Option ROM。X11DPU には見えない項目
```

問題点:
1. **「現在値: Disabled」は出荷時の初期値**。2026-05-02 に Enabled に変更済み (前任レポート 2026-04-30 / 2026-05-02_060639) で、現状の実機値と乖離
2. なぜ Enabled が必要か（OS disk が LSI HBA 配下のため、Legacy boot には Option ROM 必須）の説明がない
3. Disabled 時の症状（disk first boot 失敗、PXE フォールバック）の記述がない
4. BIOS Setup での変更手順がない

### 修正後 (同セクションを差し替え)

reference.md の LSI HBA OPROM 項目を以下の構成で書き換え:
- オプション値（Disabled / Legacy / EFI 推定）
- 出荷時 default = Disabled
- 10号機の現在値 = Enabled (2026-05-02 変更、Issue #53)
- Linux Legacy boot に Enabled 必須の理由（OS disk が LSI SAS HBA 配下、mpt3sas）
- Disabled 時の症状リスト
- BIOS Setup 変更手順 5 ステップ
- 関連 Issue / レポート / メモリへの参照

メモリ `server10_lsi_hba_oprom.md` の内容を reference.md に**追記**する形（重複は許容、reference.md は BIOS 操作の唯一参照ポイントとして自己完結させる）。

## タスクC: 反復通しテスト 2 サイクル

### 目的

タスクA/Bを適用した後、preseed 修正 (Issue #55) の自動再現性を実機で複数回確認する。前任レポートでは 1 サイクルのみ完走確認。

### 実施フロー (1 サイクル)

```sh
# 1. Phase 3-8 をリセット
./scripts/os-setup-phase.sh reset cleanup --config config/server10.yml
./scripts/os-setup-phase.sh reset pve-install --config config/server10.yml
./scripts/os-setup-phase.sh reset post-install-config --config config/server10.yml
./scripts/os-setup-phase.sh reset install-monitor --config config/server10.yml
./scripts/os-setup-phase.sh reset bmc-mount-boot --config config/server10.yml
# (個別実行: for ループはルール禁止)

# 2. preseed 再生成 (毎回確実に行う)
./scripts/generate-preseed.sh config/server10.yml preseed/preseed-generated-s10.cfg

# 3. Phase 3-6 を完走 (本命検証点: 手動介入なしで SSH 到達)
#    os-setup スキルに従い、各 Phase を順次実行
#    Phase 6 完了時に ssh-wait.sh 100秒以内で connected を期待

# 4. ネットワーク状態を検証
ssh -F ssh/config root@10.10.10.210 ip -br a
# → eno1=IP なし / eno1.1083=10.10.10.210/8 / eno1.1120=DHCP

# 5. Phase 7 (pve-install) は時刻同期手当を含めて完走
#    sync-time-s10.sh で epoch 同期 (RTC タスクは別なので手動許容)

# 6. Phase 8 (cleanup) で vmbr0/vmbr1 を VLAN-aware bridge 化
```

### 検証ポイント (各サイクル)

| ポイント | 期待値 |
|---------|--------|
| Phase 6 SSH 到達 | 手動介入なし、`ssh-wait.sh` で 100-150 秒以内 connected |
| `/etc/network/interfaces` 内容 | `eno1 inet manual` + `eno1.1083 inet static` + `eno1.1120 inet dhcp` の 3 ブロック (4-9号機向け append が混じらない) |
| `ip -br a` | `eno1` に IP 無し、`eno1.1083 = 10.10.10.210/8`、`eno1.1120 = 192.168.120.x/24` |
| default route | `default via 192.168.120.1 dev eno1.1120` (10.10.10.1 ではない) |
| 1サイクル所要時間 | 30 分 ± 5 分 |

### 既知の caveats (反復テスト中)

- **RTC バッテリ切れ**: Phase 7 開始前に毎回 `date -s @<epoch>` 同期が必要 (タスクD除外、手動許容)
  - 実測: 直近インストール時に systemd-timesyncd が NTP 同期 → hwclock --systohc で RTC 更新済みの場合、再起動後も時刻が保持される。今回 2 サイクルとも手動 sync 不要
- **LINSTOR セットアップ失敗**: 10号機 LINSTOR 未参加なので無視 (前任レポートと同じ)
- **POST code stale 値**: 起動時の POST code API が `0x00`/`0x01` を返すことがあるため SOL ログを併用
- **KVM screenshot canvas stale**: BMC KVM screenshot が古いフレームを返すことあり。実進行は SOL log で確認

### 反復回数: **2 サイクル**

理由:
- 1 サイクル=30分。3 サイクルだと約 1.5h で時間/価値の釣り合いが微妙
- 2 サイクルで基本的な再現性は立証可能。3 サイクル目は将来必要になったら別タスクで実施

## 修正対象ファイル一覧

| ファイル | 変更内容 |
|---------|----------|
| `config/server10.yml` | lines 39-42 の `disk:` コメント修正 (タスクA) |
| `.claude/skills/bios-setup/reference.md` | lines 1400-1403 の LSI HBA OPROM 項目を Why/How 追加で書き換え (タスクB) |
| `state/os-setup/server10/*` | Phase reset で再生成 (タスクC、最終状態は同一) |
| `report/<新規>.md` | 完了後にレポート作成 (REPORT.md ルール) |
| `report/attachment/<新規>/` | 反復テストの SOL ログ等を保存 |

## 検証 (タスク完了判定)

1. **タスクA**: `config/server10.yml` 編集後、`./scripts/generate-preseed.sh` が同じ preseed を生成（コメントは `disk:` の値に影響しない）
2. **タスクB**: `.claude/skills/bios-setup/reference.md` の LSI HBA OPROM 項目に「Enabled」「Why」「How」が追加されている
3. **タスクC**: 2 サイクル両方で:
   - `./scripts/os-setup-phase.sh status --config config/server10.yml` が全 Phase done
   - 検証ポイント表の全項目を満たす
   - SOL ログを `report/attachment/.../sol-iter<N>.log` として保存
4. **総合**: REPORT.md ルールに従いレポート作成、Issue 状態更新

## 既存資産の再利用

- `scripts/generate-preseed.sh` (前回修正済の VLAN 上書き分岐をそのまま活用)
- `scripts/os-setup-phase.sh` (Phase reset / status)
- `os-setup` スキル (Phase 1-8 のフロー)
- `bios-setup` スキル (将来 BIOS 値検証時)
- メモリ `server10_lsi_hba_oprom.md` (タスクB の本文ソース)

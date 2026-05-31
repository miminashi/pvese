# training-tx1320 VirtualMedia (NFS) 経由 OS インストール再挑戦

## Context

これまでの作業で training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4) への OS
インストールは **PXE/netboot 経由で完遂** した (Phase 19, 10-run robustness 100%)。
PXE に pivot した理由は、VirtualMedia (iRMC OEM USB redirector) が deploy ごとに
**累積劣化 → BIOS POST 99 stuck** を起こし、Phase 16-18 で復旧不能になったため。

ユーザ要望は「VirtualMedia 経由で再度インストールできないか」。当時から状況が変わって
いる可能性がある:

1. **FW が 9.69F に更新済み** (Phase 18)。`irmc-virtualmedia.sh` は既に
   `FTSVirtualMediaAction` (9.69F 必須の OEM パラメータ名) に対応済み。
2. **Phase 18 (2026-05-23) から約1週間経過** + その間 PXE で多数の電源サイクルが
   回っており、USB redirector の状態が自然リセットされている可能性。
3. **唯一未検証の回復レバー = 長時間 PSU 切断 (5分以上、F8b)** が残されている
   (Phase 17-18 では 30-60秒 のみ試行)。ユーザ確認済みで実施可能。

インフラは全て実装済み (新規コード不要):
- `scripts/tx1320-raid10-orchestrate.sh` — build/deploy/monitor を統括。deploy() は
  NFS config → connect-cd → mount → **105s pad** → boot-override Cd UEFI → power-on。
- `scripts/irmc-virtualmedia.sh` — NFS ShareType + ConnectCD + FTSVirtualMediaAction 対応。
- `scripts/remaster-debian-iso.sh` — cdrom-detect pvese-patch v1 (`/dev/sr1` 優先) を
  `PVESE_PATCH_CDROM_DETECT=1` で適用。storcli64 binary inject、console=tty0 削除済み。
- `scripts/sol-monitor.py` / `scripts/irmc-oem-screenshot.sh` — 観測手段。
- `config/training_tx1320.yml` — `virtual_media_type: nfs` / NFS `10.1.6.6:/var/samba/public`。

**ゴール**: VirtualMedia で Debian + HW RAID10 をフル install 完遂し、SSH 到達まで。
現在の PXE 版 OS は RAID10 再フォーマットで上書きされる (ユーザ承認済み)。

## 方針

「最も安価な経路 (リセットなし) でまず試し、POST 99 stuck が出たら段階的に回復策を
エスカレート」する。新規コードは原則書かず、既存スクリプトを運用する。スクリプトに
バグ/非互換が見つかった場合のみ最小修正する。

## 手順

### Phase 0: プリフライト (全て read-only / 非破壊)
- **env の扱い**: `bmc-power.sh` は vendor-agnostic で env 5変数を要求するため、
  standalone 呼び出しは必ず `tmp/<sid>/` のラッパースクリプト (env export 込み) 経由で実行する
  (`BMC_SCHEME=https`, `BMC_CURL_OPTS=--ciphers DEFAULT@SECLEVEL=0`, `POWER_ON_RESET_TYPE=On`,
  `BMC_PATCH_REQUIRES_ETAG=1`, `BMC_BOOT_OVERRIDE_NO_DISABLED=1`)。一方 `irmc-virtualmedia.sh` /
  `irmc-fw-update.sh` は iRMC 専用で `--ciphers` 等を内蔵しており env 不要。
- iRMC 到達性・電源状態: `bmc-power.sh status` (上記ラッパー経由)。
- FW level 確認 (9.69F であること): `./scripts/irmc-fw-update.sh version 10.254.254.9 claude Claude123`
- VirtualMedia OEM endpoint 応答確認: `./scripts/irmc-virtualmedia.sh status 10.254.254.9 claude Claude123`
- NFS サーバ 10.1.6.6 到達性 + ISO 配置確認。

### Phase 1: ISO build + NFS 同期
- `./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml`
  - storcli64.deb fetch → binary 抽出 → preseed 生成 → cdrom-detect patch 込み ISO remaster →
    Phase 4.5 で 10.1.6.6:/var/samba/public へ scp 同期。

### Phase 2: Attempt 1 — リセットなし deploy
- `./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml`
- SOL monitor + OEM screenshot で観測。SOL ログを一次情報とする。

### Phase 3: Attempt 2 — 長時間 PSU 切断後の deploy (POST 99 stuck 再発時のみ)
- ユーザに AC 電源を 5分以上抜くよう依頼 → 再 deploy。

### Phase 4: 完遂確認
- phonehome GET + SSH 到達 + lsblk RAID10 の3点で確定。

> 注: 実際にはプランの想定 (full-ISO VirtualMedia boot) を実行した結果、GRUB 2.12 →
> 6.12 kernel の EFI ハンドオフが当 firmware で不可と判明し、ユーザ提案の「VirtualMedia
> から iPXE を起動して PXE 相当」に方針転換して完遂した。詳細は本レポート本文を参照。

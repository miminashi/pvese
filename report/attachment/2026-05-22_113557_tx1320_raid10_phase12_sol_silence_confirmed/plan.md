# Phase 12: SOL silence を打破して kernel boot 後 reset の真因を観測

## Context

[Phase 11 (2026-05-22 phase11-084821)](report/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed.md) で **Phase 10「installer boot 成功」判定が誤りだった事が発覚**。`vga=normal nomodeset` 削除で GRUB stage triple-fault は治ったが、kernel boot 後の別の reset 原因が残存し、`Booting 'Automated Install'` が SOL log に 51-99 回出現 (cycle 周期 ~5-17s) する reset loop が継続中。

cmdline 末尾の `quiet` が SOL に kernel printk を出さなくし、panic / oops / 初期化失敗の原因を観測不可能にしている。Phase 12 は **SOL silence を打破し、kernel printk を強制出力させて真因を観測する** ことが最優先目標。最終的には preseed 完走 + RAID10 install + SSH login まで到達したい。

主要な制約・前提:
- iRMC KVM canvas は framebuffer mode 変更後 artifact (黒画) を返す → boot 失敗の証拠として使えない (Phase 7-8 で確定)
- iRMC OEM Screenshot (`scripts/irmc-oem-screenshot.sh`) は **真の VGA capture** で artifact を回避できる (Phase 8 発見)
- D3373 BIOS は SOL UART bridge が UEFI runtime services で機能しない可能性がある (Phase 6 GRUB shell 経路で類似事例) — 観測 fallback として OEM Screenshot を併用
- training-tx1320 は現在 PowerState=Off、Virtual Media detached (parallel Explore で確認済み)
- 本番 ISO は `/var/samba/public/debian-training-tx1320-raid10.iso` (800 MB, Phase 11 build 物が残存) → 本 Phase で再 build して上書き

ユーザ確認済みの判断:
- `earlyprintk` は `ttyS${SERIAL_UNIT}` (= ttyS1) を使う (BMC SOL bridge と一致)
- sol-monitor.py 判定ロジックは Phase 12 では触らず、観測に集中 (Booting 回数は手動 grep で確認)

## アプローチ

### 変更対象は 1 ファイルのみ: `scripts/remaster-debian-iso.sh`

cmdline 末尾の `--- quiet` を `--- earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel` に置き換える。4 箇所:

| 行 | 場所 | 役割 |
|----|------|------|
| L124 | grub.cfg の `Automated Install` menuentry | UEFI 経路の auto boot (training-tx1320 の primary path) |
| L134 | isolinux txt.cfg の `auto` label | BIOS 経路の auto boot (training-tx1320 では未使用) |
| L138 | isolinux txt.cfg の `install` label | BIOS 手動 install (training-tx1320 では未使用、整合性のため変更) |
| L197 | grub-mkstandalone embed.cfg の `Automated Install` menuentry | Option B (efi.img rebuild) で使われる UEFI cmdline |

それぞれの末尾 `${EXTRA_CMDLINE} --- quiet` を `${EXTRA_CMDLINE} earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ---` に置換 (`---` は debian-installer の separator なので残す)。

note: `quiet` は Linux kernel の console verbosity を抑制する flag。これを削除すると loglevel default が KERN_INFO になるが、`ignore_loglevel` で確実に **すべての printk が console に出る** よう強制。

### Build → Deploy → Observe フロー

1. **edit**: `scripts/remaster-debian-iso.sh` の 4 箇所を上記の通り置換
2. **build**: `./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml`
   - 出力: `/var/samba/public/debian-training-tx1320-raid10.iso` (上書き)
   - SKIP_STORCLI_FETCH=1 を設定して既存 storcli64.deb を再利用 (時間短縮)
3. **deploy**: `./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml`
   - NFS Virtual Media config → ConnectCD → boot-override Cd UEFI → ForceOff + sleep 8 + On
4. **observe** (並列):
   - SOL monitor: `./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml --timeout 600 --log tmp/<sid>/sol.log`
   - syslog-receiver: `.venv/bin/python scripts/syslog-receiver.py --listen 10.1.6.1:5514` を background で起動 (preseed early_command 経由の log 受信)
   - OEM screenshot loop: `t=60s, 120s, 180s, 240s, 300s` で `./scripts/irmc-oem-screenshot.sh` を実行し VGA を timeline 取得
5. **analyze**: SOL log を grep して以下を判定:
   - `Booting 'Automated Install'` 回数 (1 回 + 長時間継続 = kernel 進行 / 5 回以上 = reset loop 継続)
   - `Kernel panic` / `BUG:` / `Oops:` の存在 → root cause 特定
   - `INSTALLER_STAGES` 到達数 → preseed 進行確認
   - early stage の kernel printk (例: `Linux version`, `BIOS-e820:`, `ACPI:`, `PCI:`) の有無

### 判定の decision tree

```
SOL に kernel printk が出る?
├─ Yes → panic / oops / init failure 等の message を確認
│       ├─ panic message あり → root cause 特定 → fix (cmdline 追加 flag, BIOS 設定, etc.) → Phase 13
│       └─ printk あるが progress 停止 → 該当時点での kernel state を分析
│
└─ No → OEM Screenshot を確認
        ├─ VGA に kernel console output あり → D3373 SOL UART bridge dead 確定
        │   → 観測経路を OEM Screenshot に切替 → Phase 13 で screenshot 中心の観測 plan
        │
        └─ VGA も silent (BIOS POST → GRUB → 黒画のループ)
            → kernel が console 出力前に panic
            → fallback: console=earlyprintk only, console=tty0 削除, console=ttyS1 keep でもう一度
            → それでも silent: Debian 12 (bookworm) ISO で base 互換性検証 (Phase 11 引継ぎ事項 #3)
```

## 関連ファイル (read-only で参照、編集は remaster-debian-iso.sh のみ)

- `scripts/remaster-debian-iso.sh` — **編集対象**。L124/L134/L138/L197 の cmdline 置換
- `scripts/tx1320-raid10-orchestrate.sh` — build/deploy/monitor entrypoint (再利用、編集不要)
- `scripts/sol-monitor.py` — INSTALLER_STAGES 9 stage の正規表現マッチ (ユーザ確認により編集せず)
- `scripts/irmc-oem-screenshot.sh` — 真の VGA capture (fallback 観測手段)
- `scripts/irmc-virtualmedia.sh` — NFS attach/detach
- `scripts/syslog-receiver.py` — preseed early_command 経由の log 受信
- `config/training_tx1320.yml` — SERIAL_UNIT=1, NFS host=10.1.6.6 export=/var/samba/public

## 終了基準と次 Phase への引き継ぎ

**Phase 12 完了条件**: 以下のいずれか

1. ✅ **kernel printk 観測成功** + 真因特定 → 引き継ぎレポートに具体的な panic / fault message + 推定根本原因を記載 → Phase 13 で fix
2. ✅ **OEM Screenshot で VGA kernel console 観測成功** → D3373 SOL UART bridge dead 確定 → Phase 13 を OEM Screenshot 中心の観測ストラテジに切替
3. ⚠️ **両方 silent** → Phase 11 引継ぎ事項 #2 (stock 13.3.0 ISO で baseline) または #3 (Debian 12 ISO で互換性検証) に進む

**最終目標** (Phase 12 + 後続): preseed 完走 + RAID10 install + SSH login (`config/training_tx1320.yml` に書かれた DHCP IP に SSH 接続できる)。

## Verification

実行中:
- SOL log を tail (`monitor` バックグラウンド中に並列 read で確認可能)
- iRMC PowerState を `curl https://10.254.254.9/redfish/v1/Systems/0` で 30 秒毎に確認 (warm-reset loop だと `On` 継続)

完了時 (Phase 12 内 success path):
- `grep -c "Booting 'Automated Install'" sol.log` → 1 (kernel boot 後の reset なし)
- `grep "Linux version" sol.log` → 1 (kernel printk が出ている確証)
- `grep "Kernel panic\|BUG:\|Oops:" sol.log` → panic がなければ空、あれば root cause

完了時 (最終目標 = preseed 完走):
- `ssh -F ssh/config -i ssh/id_ed25519 root@<DHCP IP>` で SSH 成功
- `ssh ... lsblk` で RAID10 VD が見える (`/dev/sdb` 等)
- `ssh ... cat /proc/mdstat` / storcli64 show で RAID 状態確認

## レポート作成

Phase 12 完了時、`report/2026-05-22_<HHMMSS>_tx1320_raid10_phase12_<outcome>.md` に作業ログを残す:
- 観測した kernel printk / panic / screenshot summary
- 真因の特定 (もし出来たら) と対応策
- Phase 13 への引き継ぎ事項

# OS セットアップスキル テスト実行 #3（中断）

- **実施日時**: 2026年2月22日 14:48〜17:10 (UTC)
- **参照**: [テスト #2 レポート](2026-02-22_144800_os_setup_skill_test2.md)

## 前提・目的

テスト #1, #2 で発見・修正した全問題を含む最終検証。Phase 1〜8 を実行し、安定性を確認する。

## 環境情報

- サーバ: Supermicro SYS-6019U-TN4R4T (X11DPU)
- BMC IP: 10.10.10.24
- 既存 OS: Debian 13.3 + PVE 9.1.5（テスト #2 で構築済み）

## 結果

**中断**: POST code 92 スタックにより、OS インストールの前段階でサーバが起動不能になった。

## 発見した問題

### 問題 11: Boot0011 が BootOptions に存在しない（POST 通過前）

- **症状**: VirtualMedia マウント後、サーバ On の状態で `boot-next Boot0011` を実行するとエラー
- **原因**: Boot0011 は UEFI POST で VirtualMedia デバイスを列挙した後にのみ出現する。VirtualMedia をマウントした時点ではまだ BootOptions に反映されない
- **正しい手順**: VirtualMedia マウント → パワーサイクル（POST 通過）→ Boot0011 が出現 → boot-next 設定 → 再度パワーサイクル
- **修正**: SKILL.md Phase 4 を更新

### 問題 12: `ipmitool chassis bootdev cdrom options=efiboot` が VirtualMedia CD で動作しない

- **症状**: IPMI で CDROM ブートを設定し power cycle してもディスクから起動する
- **原因**: Supermicro UEFI が IPMI bootdev cdrom を VirtualMedia CDROM にマッチしない
- **結論**: VirtualMedia からのブートには Redfish `boot-next` が唯一の信頼できる方法

### 問題 13: Redfish `boot-override Cd UEFI` が VirtualMedia CD で動作しない（再確認）

- **症状**: テスト #1 と同様、Cd override 設定後もディスクから起動
- **結論**: テスト #1 の知見を再確認。boot-override Cd は VirtualMedia にマッチしない

### 問題 14（致命的）: efibootmgr で作成した不正ブートエントリが POST code 92 を引き起こす

- **症状**: efibootmgr -c -d /dev/sr0 でブートエントリ（Boot0000）を作成後、サーバが POST code 92 で永久スタック
- **原因**: efibootmgr が Virtual CDROM に対して `HD(1,MBR,...)` デバイスパスでブートエントリを作成。このエントリの MBR パーティション UUID は VirtualMedia の一時的な ISO に依存し、リブート後に無効になる。UEFI BDS フェーズがこの無効なエントリを処理しようとしてスタック
- **影響**:
  - POST code 92 が繰り返し発生（ForceOff → 長時間待機 → On でも解消せず）
  - BIOS リセット（`ipmitool raw 0x3c 0x40`）を実行したが解消せず
  - BMC リセットにより全ユーザアカウントが削除される副作用あり
- **回復**: 物理コンソールまたは BMC KVM で BIOS Setup に入り、不正なブートエントリを削除する必要がある
- **教訓**: **efibootmgr -c を VirtualMedia デバイスに対して絶対に使用しないこと**
- **修正**: SKILL.md Phase 4 と reference.md に警告を追記

### 問題 15: `ipmitool raw 0x3c 0x40` が BMC をファクトリーリセットする

- **症状**: BIOS リセットを意図して実行したが、BMC 全設定がリセットされた
- **影響**: claude ユーザアカウント消失。ADMIN/ADMIN に戻った
- **回復**: `ipmitool -U ADMIN -P ADMIN user set name 3 claude` 等で再作成済み
- **修正**: reference.md に警告を追記

## 修正ファイル一覧

| ファイル | 修正内容 |
|---------|---------|
| `.claude/skills/os-setup/SKILL.md` | Phase 4: パワーサイクル手順修正、efibootmgr 禁止注記、BootOptions 確認ステップ追加 |
| `.claude/skills/os-setup/reference.md` | POST code 92 セクション更新、IPMI raw リセット警告追記、UefiBootNext 要件追記 |

## 現在のサーバ状態

- PowerState: On（POST code 92 スタック中）
- Health: Critical
- BMC ユーザ: claude（再作成済み）
- VirtualMedia: アンマウント済み
- **復旧には物理的なアクセスが必要**

## Phase 4 の正しい手順（3回のテストで確立）

1. VirtualMedia config + mount
2. パワーサイクル（ForceOff → 20秒 → On）— POST で VirtualMedia が列挙される
3. OS ブート待ち（3分）
4. BootOptions 確認 — Boot0011 の存在を確認
5. `boot-next Boot0011` 設定
6. パワーサイクル — VirtualMedia CD からブート
7. **禁止事項**: efibootmgr -c, ipmitool chassis bootdev cdrom, boot-override Cd UEFI はいずれも VirtualMedia では動作しない

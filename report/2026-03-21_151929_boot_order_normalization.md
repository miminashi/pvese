# 4,5,6号機 UEFI ブートオーダー正規化レポート

- **実施日時**: 2026年3月22日 00:19 (JST)
- **対象**: 4号機 (10.10.10.204), 5号機 (10.10.10.205), 6号機 (10.10.10.206)

## 前提・目的

先行作業（BIOS 時刻確認・Boot Option #1 変更）でブートオーダーに部分的な変更が入ったため、3台の UEFI ブートオーダーを統一的に正規化する。

- **背景**: BIOS GUI (AMI Aptio) での Boot Option 操作は、ダイアログのラップ挙動やドロップダウンリスト内での値スワップにより、意図しない変更が発生しやすい
- **目的**: debian (OS) のみを UEFI BootOrder に設定し、不要なブートエントリ（Network, EFI Shell, Legacy HDD 等）をブート順序から除外する

## 環境情報

| サーバ | ホスト名 | BMC IP | 静的 IP | OS |
|--------|----------|--------|---------|-----|
| 4号機 | ayase-web-service-4 | 10.10.10.24 | 10.10.10.204 | Debian 13.3 + PVE 9.1.6 |
| 5号機 | ayase-web-service-5 | 10.10.10.25 | 10.10.10.205 | 同上 |
| 6号機 | ayase-web-service-6 | 10.10.10.26 | 10.10.10.206 | 同上 |

マザーボード: Supermicro X11DPU / BIOS: AMI Aptio v4.0

## 作業内容

### 初期アプローチ: BIOS GUI 操作

当初は KVM スクリーンショット + キーストロークで BIOS Boot タブの Boot Option を個別に Disabled に設定する方針だった。

**発生した問題**:

1. **ドロップダウンリストのラップ**: Boot Option のドロップダウンは 18 項目のリストで ArrowDown/ArrowUp がラップ（先頭↔末尾で循環）するため、ブラインドのキー操作で "Disabled" に到達するのが困難
2. **バッチ操作の失敗**: 複数の Boot Option を一括で変更しようとした際、Boot mode select が意図せず UEFI → DUAL に変更され、Boot タブのレイアウトが変化
3. **値のスワップ**: Minus キーで値を変更すると、他の Boot Option と値が自動スワップされ、予測不能な状態になる
4. **KVM セッション間の状態不整合**: 各 KVM 接続は新しいセッションとなるため、ダイアログの状態がセッション間で失われる

### 最終アプローチ: efibootmgr

BIOS GUI の操作困難を受け、OS レベルで `efibootmgr` を使用する方式に切り替えた。

**変更前の状態** (3台共通):
```
BootOrder: 0004,0002,0001,0003
Boot0001* Hard Drive      (SATA HDD - legacy)
Boot0002* Network Card    (IBA 40-10G / FlexBoot)
Boot0003* UEFI: Built-in EFI Shell
Boot0004* debian          (EFI\debian\shimx64.efi)
```

**実行コマンド**:
```sh
ssh -F ssh/config pve4 efibootmgr -o 0004
ssh -F ssh/config pve5 efibootmgr -o 0004
ssh -F ssh/config pve6 efibootmgr -o 0004
```

**変更後の状態** (3台共通):
```
BootOrder: 0004
Boot0001* Hard Drive      (存在するがブート順序外)
Boot0002* Network Card    (存在するがブート順序外)
Boot0003* UEFI: Built-in EFI Shell (存在するがブート順序外)
Boot0004* debian          (唯一のブート対象)
```

### 4号機の BIOS 変更について

4号機では BIOS GUI 操作を試行した際、以下の変更が Save & Exit で永続化された:

- Boot Option #3: Disabled (USB CD/DVD → Disabled)
- Boot Option #4: Disabled (Network:IBA → Disabled)
- Boot Option #2: USB CD/DVD に変更 (UEFI USB CD/DVD からのスワップ)

これらは BIOS レベルの Boot Option 設定であり、EFI BootOrder (efibootmgr) とは独立。efibootmgr で BootOrder を debian のみに設定したため、BIOS Boot Option の設定は実質的に無効化されている。

## 検証

3台とも `efibootmgr` で BootOrder: 0004 (debian) を確認:

```
# 全3台で確認
ssh -F ssh/config pve4 efibootmgr  # BootOrder: 0004
ssh -F ssh/config pve5 efibootmgr  # BootOrder: 0004
ssh -F ssh/config pve6 efibootmgr  # BootOrder: 0004
```

OS は正常に起動中 (SSH 接続確認済み)。

## VirtualMedia ブートについて

UEFI USB CD/DVD (BMC VirtualMedia) は EFI の永続エントリではなく、BMC VirtualMedia がマウントされた時に動的に作成される。OS 再インストール時は以下の方法でブート可能:

1. VirtualMedia を BMC 経由でマウント
2. `efibootmgr -n XXXX` で次回ブートデバイスを一時指定
3. または BIOS Setup の "Save & Exit" タブから Boot Override で一時ブート

## 教訓

| 項目 | BIOS GUI 操作 | efibootmgr |
|------|--------------|------------|
| 信頼性 | 低 (ラップ、スワップ、タイミング問題) | 高 (直接 EFI 変数を操作) |
| 速度 | 遅い (KVM 接続 ~8秒/回、キー操作にスクリーンショット確認必要) | 瞬時 (SSH コマンド1行) |
| リスク | Boot mode 誤変更等の副作用あり | BootOrder 変数のみ変更、副作用なし |
| 再現性 | 低 (ダイアログ状態がセッション間で不整合) | 高 (コマンド1行で再現可能) |

**結論**: Supermicro X11DPU の AMI BIOS Boot Option は、BIOS GUI よりも `efibootmgr` で管理するのが効率的かつ安全。Boot Option #1 の設定 (前回セッションで実施済み) も `efibootmgr -o` で代替可能だった。

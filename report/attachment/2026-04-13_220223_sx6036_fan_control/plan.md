# SX6036 IB スイッチ ファン制御調査計画

## Context

Mellanox SX6036 (MLNX-OS 3.6.8012) の IB スイッチのファン制御方法を調査する。現状ファンは ~9400 RPM (メイン) / ~11300 RPM (PS) で常時動作しており、速度制御の可否を確認したい。

Web 調査の結果、MLNX-OS にはファン速度制御コマンドの公式ドキュメントが見当たらなかった。NVIDIA フォーラムでも「ファン速度の変更方法はない」という回答が多い。ただし MLNX-OS 3.6 のコマンドヘルプには `fan`, `system`, `debug` 等のサブコマンドがあり、未文書化の制御コマンドが存在する可能性がある。実機で網羅的に確認する。

## 手順

1. 現状ベースライン取得 (show fan/temperature/power)
2. show コマンドで追加情報収集 (system, module, voltage, leds)
3. enable モードで追加コマンド探索 (running-config, chassis, environment, health)
4. configure モードでファン制御コマンド探索 (fsc, fan-speed, fan, system fan-speed, health fan)
5. SNMP 経由のファン情報確認
6. レポート作成

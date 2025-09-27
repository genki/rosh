# roshセッションがクラッシュする件 調査メモ (2025-09-26)

## 事象
- roshで `vagrant grav` に接続中、セッションが突然落ち、以下の標準出力を確認。
  - `can't find session: grav`
  - `bind [127.0.0.1]:3131: Address already in use`
  - `Warning: remote port forwarding failed for listen port 8082`
- rosh は再接続を試みるが、最終的に `[exited]` してしまい復旧しない。

## 原因の整理
- rosh は初期化時に `~/.ssh/config` から対象ホストの `LocalForward` と `RemoteForward` をそのまま `ssh` オプションとして引き継ぐ。（`lib/rosh.rb:32-37`）
- 対象ホスト設定に `LocalForward 3131 ...` および `RemoteForward 8082 ...` が含まれているため、接続のたびにローカル127.0.0.1:3131とリモート8082/tcpの占有を試みる。
- セッションが異常終了した直後や、別ターミナルで同じホストに接続したままの場合、既存の `ssh` プロセスがこれらのポートを掴んでおり、新しい `ssh` が `bind ... Address already in use` を返して失敗する。
- `ssh` が失敗すると rosh の `system cmd` 呼び出しが偽を返し、再接続ループ中に `tmux` セッション作成も失敗扱いとなって rosh 本体が終了する。（`lib/rosh.rb:55-90`）
- 冒頭の `can't find session: grav` は、リモート tmux セッションが異常終了したか、まだ存在しないことを示しており、ポート前提の再接続をより不安定にしている。

## 確認ポイント
- `lsof -iTCP:3131 -sTCP:LISTEN` でローカルの占有プロセスを特定。
- `ps aux | grep ssh.*3131` で rosh/vagrant 由来の既存 SSH プロセスが残っていないか確認。
- リモートホスト側で `ss -tnlp | grep 8082` などを実行し、8082/tcp を掴んでいるプロセスの有無を確認。
- `.ssh/config` の該当 Host 節を確認し、前述の Local/RemoteForward が設定されていることを記録。

## 対策案
### 応急対応
- 残留している SSH プロセスを終了し、ローカル3131/tcpを解放する（例: `pkill -f 'ssh.*3131'`）。その後 rosh を再実行。
- 必要に応じてリモートで `tmux new-session -s grav -d` を手動実行し、セッションを復旧。

### 恒久対応候補
1. rosh 専用の Host エイリアスを `.ssh/config` に用意し、Local/RemoteForward を外す。通常の `ssh`/`vagrant` 用と分離してポート競合を防ぐ。
2. Forward のポート番号を見直し、常に空いている番号に変更するか、ローカル側だけでも `LocalForward 0 ...` で OS 任せの空きポートを採用し、アプリ側には `SSH_CONNECTION` などから割当ポートを伝える。
3. rosh を改修し、`bind ... Address already in use` を検知した場合は次のリトライまで `sleep` する、または Forward をスキップできるオプションを追加する（要検討）。
4. `.ssh/config` に `ExitOnForwardFailure yes` を追加しておくと、Forward が確立できない接続を早期に失敗させられるため、原因の切り分けが容易になる。

## 改修方針（Forward衝突時はスキップ）
- 目的: 同一ホストに対して複数の rosh セッションを開いた際に Forward が衝突する場合、Forward を諦めて tmux 再接続のみ継続させる。
- 想定フロー
  1. `local_forwards` / `remote_forwards` の戻り値をもとに `@ssh_opts` を組み立てる処理にフックし、ポートの事前占有チェックを追加。
  2. ローカル Forward については `Socket.tcp_server_sockets`、`Addrinfo#getnameinfo` 等を利用して事前に bind 可否を確認し、失敗した場合は該当ポートの `-L` オプションを除外する。
  3. リモート Forward の衝突は事前検知が難しいため、`ssh` 実行時の標準エラー出力をパイプで受け取り、`bind ... Address already in use`／`remote port forwarding failed` を検知した時点で `-R` オプションを除外して再試行する（Forward なしバージョンで再接続）。
  4. Forward を全て除外した再接続が成功した場合は警告ログを出力し、恒常的に Forward を使わないモードへ遷移（セッション終了まで）。
  5. ユーザが Forward を強制したいケース向けに、`--require-forward` のようなフラグを導入し、オプトインで従来動作を維持できるようにする案も検討。
- 実装時に考慮する点
  - `OptionParser` や既存引数との後方互換性を確保する。
  - `system cmd` を直接使っているため、エラーメッセージ捕捉のために `Open3.capture3` への置き換えや、`IO.popen` を導入する必要がある。
  - Forward をスキップした場合でも再接続ループが破綻しないよう、`@first_try` フラグや `@ssh_opts` の再構築タイミングを整理する。

## 実装済みの改善点 (2025-09-26)
- Forward の衝突を検知して `-L/-R` を除去し、警告だけを出して tmux 再接続を継続する挙動を実装。
- `rosh -V` 実行時は、`ssh` コマンドの終了ステータスと tmux セッション存否をログ出力し、突然 `[exited]` した際の原因切り分けを支援する。
- `tmux attach` が `SIGKILL`/exit137 で終了した場合は OOM Kill の可能性を常時警告するようにし、`-V` 指定の有無に関わらず検知できるようにした。
- バージョンを `0.9.2` に更新。

## 追加したテスト
- `test/rosh_forwarding_test.rb`: `.ssh/config` に記載した `LocalForward`/`RemoteForward` が `@ssh_opts` に反映されること、ポート衝突を検知した場合は Forward オプションが取り除かれることを検証する Minitest。現状の Forward 振る舞いを固定化し、今後の改修時に明示的に意図を更新できるようにする。

## メモ
- 調査日: 2025-09-26
- 関連ソース: `lib/rosh.rb:32-37`, `lib/rosh.rb:55-90`, `lib/rosh.rb:133-166`
- Forward 設定が必要なワークロードの場合は、他クライアントとポート割当が被らないよう利用時間帯や利用者単位で整理すること。

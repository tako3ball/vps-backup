# VPS Backup Guide

## このガイドについて

このガイドは **VPS が完全に死んだ時にゼロから復旧するための手順書** です。

**VPS が生きている間は** バックアップは自動実行されるので、普段は何もする必要はありません。
healthchecks.io からの通知が来た時だけ「トラブルシューティング」セクションを見てください。

**VPS が死んだら** 「復旧手順」セクションに従ってください。

### ガイドの保管

このガイドファイル自体もバックアップ対象（`/home/tako4ball/` 配下）なので pCloud に保存されています。
しかし VPS が死んだ時にはこのガイドを読めないため、**事前に印刷または別端末に保存しておいてください**。

保存先: `~/.local/share/vps-backup/guide.md`

---

## このバックアップシステムがやっていること

毎日深夜3時（JST）に、VPS の `/home/tako4ball/` 配下の全ファイルを **暗号化して pCloud にコピー** します。
さらに毎週日曜4時に**週次スナップショット**（変更前のファイルのコピー）を4世代分保存します。

**暗号化** により、pCloud 側からはファイル名も中身も読めない安全な状態で保存されます。
復元するには「パスワード」と「salt」の2つが必要です。

### 使っている技術（初心者向け説明）

| 用語 | 意味 |
|------|------|
| **pCloud** | スイス拠点のクラウドストレージサービス。買い切りプランあり。 |
| **rclone** | ファイルをクラウドにコピーする無料ツール。`rsync` のクラウド版。 |
| **rclone crypt** | rclone の暗号化機能。ファイルを暗号化してからアップロードし、ダウンロード時に自動復号する。 |
| **systemd** | Ubuntu の標準機能。バックアップを決まった時間に自動実行するタイマー機能を提供。 |
| **healthchecks.io** | 外部の監視サービス（無料）。「バックアップが指定時間内に実行されたか」を監視し、実行されなければ通知する。 |
| **dead man's switch** | healthchecks.io の仕組み。バックアップが「成功しました」と定期報告を送る前提で、報告が途絶えたら「何かがおかしい」と検知する。 |
| **salt** | 暗号化を強化するための2つ目のパスワード。password と salt の**両方がないと復号できない**。 |

---

## 概要

| 項目 | 内容 |
|------|------|
| 対象 | `/home/tako4ball/` 配下の全ファイル |
| 暗号化 | rclone crypt（AES-256。ファイル名・内容とも暗号化） |
| 転送方式 | `rclone copy`（変更があったファイルだけ転送。削除されたファイルはpCloudに残る） |
| 日次バックアップ | 毎日 3:00 JST |
| 週次スナップショット | 毎週日曜 4:00 JST、4世代保持（古いものは自動削除） |
| 監視 | healthchecks.io（指定時間内にバックアップが実行されなければ通知） |
| 保存先 | pCloud 上の `vps-backup/` フォルダ内（暗号化済み） |

---

## 依存ソフトウェア

- **rclone**: `sudo apt install rclone` でインストール
- **systemd**: Ubuntu 24.04 に標準搭載（他のOSではこのガイドは使えない）
- **healthchecks.io 無料アカウント**: https://healthchecks.io でメールアドレスのみで登録可能

---

## ファイル構成

実際のファイルの置き場所:

```
~/.local/share/vps-backup/          # ソースファイル置き場（バックアップ対象に含まれる）
  guide.md                           # このガイド
  backup.log                         # バックアップ実行列
  vps-backup.sh                      # 日次スクリプト（ソース）
  vps-backup-weekly.sh               # 週次スクリプト（ソース）
  vps-backup.service                 # 日次systemdサービス定義
  vps-backup.timer                   # 日次systemdタイマー定義
  vps-backup-weekly.service          # 週次systemdサービス定義
  vps-backup-weekly.timer            # 週次systemdタイマー定義

/usr/local/bin/                      # スクリプトの実行場所
  vps-backup.sh
  vps-backup-weekly.sh

/etc/systemd/system/                 # systemd の設定場所
  vps-backup.service
  vps-backup.timer
  vps-backup-weekly.service
  vps-backup-weekly.timer

~/.config/rclone/rclone.conf         # rclone 設定ファイル（暗号化パスワードを含むため厳重管理）
```

---

## 新規セットアップ手順

**前提**: この手順は **VPS が正常に動作していて、これから初めてバックアップを設定する場合** のものです。
すでに設定済みの場合は「通常運用」セクションに進んでください。
VPS が死んで復旧する場合は「復旧手順」セクションに進んでください。

### 0. 事前確認

以下が揃っていることを確認:

- [ ] VPS に SSH でログインできる
- [ ] pCloud アカウントを持っている（メールアドレスとパスワードが分かる）
- [ ] パスワードマネージャーを開ける状態
- [ ] 手元の PC にブラウザがある（rclone のログイン認証で使う）

### 1. rclone インストール

```bash
sudo apt update && sudo apt install -y rclone
```

確認:
```bash
rclone version
# → バージョン番号が表示されればOK
```

### 2. rclone 設定（pCloud 接続）

```bash
rclone config
```

対話式の設定が始まる。画面に表示される **プロンプト（入力を促す記号）** に対して以下を入力する。
「何も入力せずEnter」と書かれていない項目は、必ず指示通りの値を入力すること。

#### 2a. pCloud リモートの作成

| 画面に表示されるプロンプト | 入力内容 | 理由 |
|---------------------------|---------|------|
| `n/r/c/s/q>` | `n` | 新規作成（new） |
| `name>` | `pcloud` | このリモートの名前（任意だが、変更すると後続の設定も変える必要がある） |
| `Storage>` | `pcloud` | 接続先のサービス（番号で選んでも、文字列入力でも可） |
| `client_id>` | 何も入力せずEnter | rclone 組み込みのIDを使う |
| `client_secret>` | 何も入力せずEnter | rclone 組み込みのIDを使う |
| `Edit advanced config? y/n>` | **`y`** | EUリージョン設定のため**必ず y** |
| `hostname>` | **`2`** | EU サーバー（`eapi.pcloud.com`）を選択。日本から登録したpCloudアカウントはEUリージョン扱い |
| 以降の `auth_url>` `token_url>` `root_folder_id>` `username>` `encoding>` | すべて何も入力せずEnter | デフォルト値で問題なし |
| `Use web browser to automatically authenticate? y/n>` | `y` | ブラウザでpCloudにログインする |
| → ここでURLが表示される | **URLをブラウザで開く** | pCloud にログインして rclone のアクセスを承認 |
| `y/e/d>` | `y` | 設定を保存 |

> **VPSにブラウザがない場合（ヘッドレス環境）**: URL は `http://127.0.0.1:53682/auth?...` という形式で表示される。これはVPS上のlocalhostなので、手元のPCから直接は開けない。以下の手順が必要:
> 1. 今のSSH接続を `exit` で切断
> 2. **ポート転送付き** で再接続: `ssh -L 53682:localhost:53682 tako4ball@<VPSのIP>`
> 3. `rclone config` を再実行して同じ手順を進める
> 4. 表示された `http://127.0.0.1:53682/auth?...` を**手元のPCのブラウザ**で開く
> 5. pCloud にログインし rclone を承認

#### 2b. crypt リモートの作成（暗号化レイヤー）

同じ `rclone config` の中で続ける:

| 画面に表示されるプロンプト | 入力内容 | 理由 |
|---------------------------|---------|------|
| `n/r/c/s/q>` | `n` | 続けて新規作成 |
| `name>` | `pcloud_crypt` | 暗号化リモートの名前 |
| `Storage>` | `crypt` | 暗号化レイヤーを選択 |
| `remote>` | `pcloud:vps-backup` | pCloud 上の保存先フォルダ |
| `filename_encryption>` | 何も入力せずEnter | 標準設定（ファイル名も暗号化） |
| `directory_name_encryption>` | **`true`** | フォルダ名も暗号化 |
| `password>` | **自分で決めたパスワードを入力** | このパスワードがないと復号できない |
| `password again>` | 同じパスワードを再入力 | 確認 |
| `salt>` | **password とは別のパスワードを入力** | 暗号化を強化する2つ目の鍵 |
| `salt again>` | 同じ salt を再入力 | 確認 |
| `Edit advanced config? y/n>` | 何も入力せずEnter | デフォルトでOK |
| `y/e/d>` | `y` | 設定を保存 |
| `n/r/c/s/q>` | `q` | 設定を終了 |

> **パスワードとsaltの作り方**:
> - 両方とも**ランダムで長い文字列**（20文字以上推奨）が安全
> - パスワードマネージャーの「パスワード生成」機能を使うのが最も簡単で安全
> - 自分で考える場合は、**推測されにくい無関係な文字列**にする（例: `honoo-miru-yama-2024!` と `kawa-ni-sakana-ooki#X`）
> - **password と salt は必ず違う文字列にすること**
> - **両方ともパスワードマネージャーに必ず記録すること。一方でも失うと全データが永久に復元できなくなる**

動作確認:
```bash
rclone lsd pcloud_crypt:
# → エラーが出なければ成功。"directory not found" と出たら以下を実行:
rclone mkdir pcloud:vps-backup
```

### 3. healthchecks.io 設定（バックアップ失敗の通知）

healthchecks.io は、バックアップが正常に実行されたかを外部から監視する無料サービスです。
「指定時間内にバックアップが動いた」という通知（ping）が届かないと、メールなどで異常を知らせてくれます。

1. 手元のブラウザで https://healthchecks.io を開き、メールアドレスでアカウント作成（無料、クレカ不要）
2. ログイン後、**Add Check** をクリック
3. 以下を設定:

| 項目 | 値 | 理由 |
|------|-----|------|
| Name | `vps-backup` | バックアップの監視であることが分かる名前 |
| Schedule | Simple / Period: 1 day | 「1日以内に最低1回は実行されるはず」という設定 |
| Grace Time | 1 hour | 1時間程度の遅延は許容 |

4. 作成後、表示される **Ping URL** を確認（`https://hc-ping.com/` で始まるURL）
5. URL の末尾の **UUID**（`https://hc-ping.com/` の後ろの英数字の羅列）をメモする
   - 例: URL が `https://hc-ping.com/abc123-def456-789` → UUID は `abc123-def456-789`

### 4. スクリプトに UUID を設定

ソースファイルは `~/.local/share/vps-backup/` にある。
両方のスクリプトの `HEALTHCHECK_ID="YOUR-UUID"` を作成したUUIDに書き換える:

```bash
nano ~/.local/share/vps-backup/vps-backup.sh
# → HEALTHCHECK_ID="YOUR-UUID" を HEALTHCHECK_ID="<実際のUUID>" に変更
```

```bash
nano ~/.local/share/vps-backup/vps-backup-weekly.sh
# → 同じくUUIDを書き換え
```

### 5. スクリプトとsystemdユニットをシステムに配置

```bash
# スクリプトを /usr/local/bin/ にコピー
sudo cp ~/.local/share/vps-backup/vps-backup.sh /usr/local/bin/
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/vps-backup.sh /usr/local/bin/vps-backup-weekly.sh

# systemd ユニットを /etc/systemd/system/ にコピー
sudo cp ~/.local/share/vps-backup/vps-backup.service /etc/systemd/system/
sudo cp ~/.local/share/vps-backup/vps-backup.timer /etc/systemd/system/
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.service /etc/systemd/system/
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.timer /etc/systemd/system/

# systemd に設定を再読込
sudo systemctl daemon-reload

# タイマーを有効化（今すぐスケジュールを開始）
sudo systemctl enable --now vps-backup.timer
# → "Created symlink ..." と表示されればOK

sudo systemctl enable --now vps-backup-weekly.timer
# → "Created symlink ..." と表示されればOK
```

### 6. 初回バックアップ実行と動作確認

```bash
# 手動でバックアップを開始（初回は全ファイルなので数時間かかる）
sudo systemctl start vps-backup.service

# 進行状況をリアルタイムで確認（Ctrl+C で中断）
tail -f ~/.local/share/vps-backup/backup.log

# タイマーが正しく設定されたか確認
systemctl list-timers vps-backup*
# → 日次と週次のタイマーが表示されればOK
```

初回バックアップが完了したら、pCloud 上のデータ量を確認:

```bash
rclone size pcloud_crypt:vps-backup/latest
```

---

## 通常運用

**普段はバックアップは自動実行されます。何もする必要はありません。**

healthchecks.io から通知が来た場合のみ、以下を確認してください。

### 状態確認コマンド

```bash
# タイマーが有効か確認（次回実行予定が表示される）
systemctl list-timers vps-backup*

# 最新のバックアップログを確認
tail -20 ~/.local/share/vps-backup/backup.log

# pCloud 上のバックアップサイズ
rclone size pcloud_crypt:vps-backup/latest

# 週次スナップショットの一覧
rclone lsf --dirs-only pcloud_crypt:vps-backup/weekly
```

### 手動でバックアップを実行したい場合

```bash
# 日次バックアップ（増分）
sudo systemctl start vps-backup.service

# 週次スナップショット
sudo systemctl start vps-backup-weekly.service

# 進行状況（Ctrl+C で中断）
tail -f ~/.local/share/vps-backup/backup.log
```

### バックアップを一時停止したい場合

```bash
sudo systemctl stop vps-backup.timer vps-backup-weekly.timer
sudo systemctl disable vps-backup.timer vps-backup-weekly.timer

# 再開
sudo systemctl enable --now vps-backup.timer vps-backup-weekly.timer
```

---

## スナップショットから特定のファイルを復元

週次スナップショットには変更前のファイルが日付フォルダに保存されている。

```bash
# スナップショット一覧
rclone lsf --dirs-only pcloud_crypt:vps-backup/weekly

# 特定日時のファイルを復元（例: 2026-06-04 の .bashrc を /tmp/ に取り出す）
rclone copy pcloud_crypt:vps-backup/weekly/2026-06-04/home/tako4ball/.bashrc /tmp/

# スナップショットを手動削除
rclone purge pcloud_crypt:vps-backup/weekly/2026-05-01
```

---

## トラブルシューティング

### バックアップが失敗する

```bash
# systemd のエラーを確認
sudo journalctl -u vps-backup.service --no-pager -n 50

# バックアップログを確認
cat ~/.local/share/vps-backup/backup.log
```

### 「ロックファイルが残っている」というエラー

前回のバックアップが異常終了した場合、ロックファイルが残って次回実行をブロックすることがある:

```bash
sudo rm /tmp/vps-backup.lock /tmp/vps-backup-weekly.lock
sudo systemctl start vps-backup.service
```

### rclone の認証が切れた

```bash
rclone config reconnect pcloud:
# → ブラウザで再認証（SSHポート転送が必要な場合は上記の手順を参照）
```

### 手動テスト

```bash
# rclone の接続確認
rclone lsd pcloud_crypt:

# pCloud に直接接続できるか確認
rclone lsd pcloud:

# スクリプトを1行ずつ実行してデバッグ
bash -x /usr/local/bin/vps-backup.sh
```

---

## 復旧手順（VPS が完全に死んだ場合）

### 前提条件

この手順は以下の状態から開始する:

- VPS 会社で **新しい VPS を契約済み**
- OS は **Ubuntu 24.04 LTS** がプリインストールされている
- **root ユーザーのパスワード** が設定済み
- `ssh root@<新しいVPSのIP>` で **root としてSSHログインできる**
- 新しい VPS の **IP アドレスを把握している**
- VPS が **インターネットに接続されている**（`apt update` が通る）
- ディスク容量が **30GB 以上**（データ復元に最低限必要）
- **手元の PC にブラウザがある**（rclone OAuth 認証で使う）
- **パスワードマネージャーが開ける**状態
- **このガイドを読める**状態（事前に印刷または別端末に保存しておくこと）

### ユーザー名について

このバックアップシステムは **すべてのデータが `/home/tako4ball/` 配下にあること** を前提に作られている。
スクリプト、systemdユニット、rclone設定のすべてが `tako4ball` ユーザー用に書かれている。

復旧時も **同じユーザー名 `tako4ball`** で作成すること。変えたい場合はすべての設定ファイルを書き換える必要があり非推奨。

### 事前準備

パスワードマネージャーを開き、以下の情報を手元に用意する:

| 必要な情報 | どこにあるか | 補足 |
|-----------|-------------|------|
| pCloud メールアドレス | パスワードマネージャー | pCloud ログインに使う |
| pCloud パスワード | パスワードマネージャー | pCloud ログインに使う |
| rclone crypt password（1つ目） | パスワードマネージャー | バックアップ作成時に自分で設定した文字列 |
| rclone crypt salt（2つ目） | パスワードマネージャー | バックアップ作成時に自分で設定した文字列 |
| healthchecks.io UUID | `943c3111-2789-44dd-8d1a-3c27e8e1033b` | 監視の再有効化に使う |

---

### Step 1: ユーザー作成

**root で新しい VPS に SSH ログイン**し、以下を1行ずつ実行:

```bash
useradd -m -s /bin/bash tako4ball
```
（`-m`: ホームディレクトリを作成、`-s`: ログインシェルをbashに設定）

```bash
passwd tako4ball
```
→ パスワードを入力（2回）。このパスワードは新しいVPSのログイン用なので、パスワードマネージャーに記録すること。

```bash
usermod -aG sudo tako4ball
```
（tako4ball に sudo 権限を付与）

```bash
su - tako4ball
```
→ 以降の作業はすべて tako4ball ユーザーで行う

---

### Step 2: rclone インストール

```bash
sudo apt update && sudo apt install -y rclone
```
→ 数十秒で完了

確認:
```bash
rclone version
```
→ バージョン番号が表示されればOK

---

### Step 3: rclone 設定（pCloud リモート）

```bash
rclone config
```

**ここで SSH ポート転送が必要。** 現在 `ssh root@<IP>` で接続している場合:
1. `exit` を2回実行してSSHを切断
2. **ポート転送付き**で再接続: `ssh -L 53682:localhost:53682 root@<新しいVPSのIP>`
3. `su - tako4ball` でユーザー切り替え
4. `rclone config` を実行

| プロンプト | 入力 | 
|-----------|------|
| `n/r/c/s/q>` | `n` |
| `name>` | `pcloud` |
| `Storage>` | `pcloud` |
| `client_id>` | Enter（空欄） |
| `client_secret>` | Enter（空欄） |
| `Edit advanced config? y/n>` | **`y`** |
| `hostname>` | **`2`**（EUリージョン） |
| `auth_url>` `token_url>` `root_folder_id>` `username>` `encoding>` | すべてEnter（空欄） |
| `Use web browser to automatically authenticate? y/n>` | `y` |
| → 表示された `http://127.0.0.1:53682/auth?...` を手元のブラウザで開く | |
| → pCloud にログインし rclone を承認 | |
| `y/e/d>` | `y` |

---

### Step 4: rclone 設定（crypt リモート）

同じ `rclone config` の中で続ける:

| プロンプト | 入力 |
|-----------|------|
| `n/r/c/s/q>` | `n` |
| `name>` | `pcloud_crypt` |
| `Storage>` | `crypt` |
| `remote>` | `pcloud:vps-backup` |
| `filename_encryption>` | Enter（標準） |
| `directory_name_encryption>` | **`true`** |
| `password>` | **事前に用意した password を入力** |
| `password again>` | 同じpasswordを再入力 |
| `salt>` | **事前に用意した salt を入力** |
| `salt again>` | 同じsaltを再入力 |
| `Edit advanced config? y/n>` | Enter（n） |
| `y/e/d>` | `y` |
| `n/r/c/s/q>` | `q` |

確認:
```bash
rclone lsd pcloud_crypt:
# → エラーが出なければOK
```

---

### Step 5: データ復元

```bash
rclone copy pcloud_crypt:vps-backup/latest /home/tako4ball
```

約13GBのデータをダウンロードするため **1〜数時間かかる**。
途中で接続が切れても、**同じコマンドを再実行すれば続きから再開**されるので安心してよい。

途中経過の確認（別のSSH接続で）:
```bash
ls /home/tako4ball          # 復元されたフォルダを確認
du -sh /home/tako4ball      # 復元済みサイズを確認
```

完了したら所有権を設定:
```bash
sudo chown -R tako4ball:tako4ball /home/tako4ball
```

確認:
```bash
ls /home/tako4ball
# → .bashrc, dev/, .config/, .local/ などのフォルダが表示されれば復元成功
```

---

### Step 6: バックアップ機構の再展開

復元されたデータには `~/.local/share/vps-backup/` 配下にスクリプトとsystemdユニットのソースが含まれている。
これらをシステムに配置する:

```bash
sudo cp ~/.local/share/vps-backup/vps-backup.sh /usr/local/bin/
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/vps-backup.sh /usr/local/bin/vps-backup-weekly.sh
sudo cp ~/.local/share/vps-backup/vps-backup.service /etc/systemd/system/
sudo cp ~/.local/share/vps-backup/vps-backup.timer /etc/systemd/system/
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.service /etc/systemd/system/
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vps-backup.timer
sudo systemctl enable --now vps-backup-weekly.timer
```

---

### Step 7: 最終確認

```bash
systemctl list-timers vps-backup*
# → 日次（NEXT: 翌日03:00）と週次（NEXT: 翌日曜04:00）が表示される

sudo systemctl start vps-backup.service
# → バックアップが実行される（データはすでに揃っているので差分のみ、数分で完了）

tail ~/.local/share/vps-backup/backup.log
# → "Starting daily backup" と表示されれば全復旧完了
```

---

### Step 8: その他（必要に応じて）

```bash
# Tailscale（VPN）
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# → 表示されたURLをブラウザで開いて認証

# tmux
sudo apt install -y tmux

# SSH鍵（秘密鍵をパスワードマネージャーから復元）
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# 秘密鍵を ~/.ssh/id_ed25519 に配置
chmod 600 ~/.ssh/id_ed25519
```

---

### 復旧に必要なもの（紛失すると復旧不可）

| 項目 | 保管場所 |
|------|----------|
| pCloud メールアドレスとパスワード | パスワードマネージャー |
| rclone crypt password（1つ目） | パスワードマネージャー |
| rclone crypt salt（2つ目） | パスワードマネージャー |
| healthchecks.io UUID | `943c3111-2789-44dd-8d1a-3c27e8e1033b` |
| このガイド | 印刷または別端末に保存 |

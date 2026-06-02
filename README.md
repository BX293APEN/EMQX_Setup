# EMQX Setup — Docker on Ubuntu

Ubuntu コンテナ上で **EMQX Enterprise** をソースビルドして起動するプロジェクトです。
QUIC / TLS / MQTT-over-WebSocket など主要プロトコルに対応した自己証明書環境を手軽に構築できます。

---

## ディレクトリ構成

```
EMQX_Setup/
├── .env                        # 環境変数の一元管理（ここを編集して使う）
├── .gitignore
├── docker-compose.yml          # コンテナ定義
├── Dockerfile                  # Ubuntu 25.04 イメージ＋ビルド依存パッケージ
├── start.sh                    # コンテナ起動時エントリーポイント
└── linux_data/                 # ホスト⇔コンテナ間マウントディレクトリ
    ├── cert/
    │   ├── createcert.py       # 自己証明書生成スクリプト
    │   ├── ca_cert.crt         # CA 証明書（生成済みサンプル）
    │   ├── ca_private.key      # CA 秘密鍵
    │   ├── certificate.crt     # サーバ証明書
    │   └── private.key         # サーバ秘密鍵
    └── config/
        └── base.hocon          # EMQX 設定ファイル（base.hocon）
```

> `linux_data/` はコンテナ内の `/home/PEN/WS/` にマウントされます。
> 証明書・設定の変更はホスト側で行うだけで反映されます。

---

## 前提条件

- Docker Engine 24.0 以上
- Docker Compose v2
- インターネット接続（初回ビルド時に Erlang/OTP・EMQX のソースを取得します）

---

## クイックスタート

### 1. 証明書の準備

コンテナを立ち上げる前に、`linux_data/cert/` 内の証明書を用意します。

**対話モード（推奨）**

```bash
cd linux_data/cert
python createcert.py
```

各パラメータを質問されます。Enter を押すとデフォルト値が使われます。

```
============================================================
  自己証明書 対話生成モード
  ※ Enterでデフォルト値を使用します
============================================================

[出力ファイル名]
  サーバ証明書ファイル名 [certificate.crt]:
  サーバ秘密鍵ファイル名 [private.key]:
  CA証明書ファイル名     [ca_cert.crt]:
  CA秘密鍵ファイル名     [ca_private.key]:

[証明書の属性]
  国コード (2文字)  [JP]:
  都道府県          [Aichi]:
  ...
```

**非対話モード（デフォルト設定のままで即生成）**

```bash
python createcert.py --default
```

> `cryptography` ライブラリが必要です。
> `pip install cryptography` でインストールしてください。

---

### 2. `.env` の設定確認

```bash
# 主要な変更箇所のみ抜粋
COMPOSE_PROJECT_NAME=project1    # プロジェクト名（全て小文字）
CONTAINER_NAME=Docker_Linux      # コンテナ名

USER_NAME=PEN                    # コンテナ内ユーザー名
PASSWORD=password                # ← 本番環境では必ず変更してください

VERSION=Default                  # EMQX バージョン指定（後述）
```

---

### 3. コンテナのビルド＆起動

```bash
docker compose up -d --build
```

初回は Erlang/OTP のコンパイルと EMQX のビルドが走るため **30〜60 分程度** かかります。
2 回目以降はビルド済みディレクトリが残っていればスキップされます。

**ログの確認**

```bash
docker logs -f Docker_Linux
```

`==> EMQX_VERSION=Default  resolved=Default` のような行が表示された後、EMQX が起動します。

---

## VERSION 指定

`.env` の `VERSION` で使用する EMQX のビルドソースを切り替えられます。

| 値 | 動作 |
|---|---|
| `Default`（省略時も同じ） | フォーク版リポジトリ (`BX293APEN/emqx`) をそのままビルド。動作確認済みの構成が維持されます |
| `Latest` | 公式リポジトリの最新タグを GitHub から取得してビルド |
| `5.8.0` など `X.Y.Z` 形式 | 指定バージョンの公式タグが存在すれば使用。存在しない場合は `Default` にフォールバック（警告ログあり） |

```dotenv
# 例: 公式の最新版でビルドする
VERSION=Latest

# 例: 特定バージョンを指定
VERSION=5.8.0
```

> `Latest` や `X.Y.Z` を指定した場合、OTP バージョンの整合性は保証されません。
> ビルドエラーが出た場合は `Default` に戻してください。

---

## 公開ポート

| ホスト側ポート | コンテナ側ポート | プロトコル | 用途 |
|---|---|---|---|
| 1883 | 1883 | TCP | MQTT |
| 8083 | 8083 | TCP | MQTT over WebSocket |
| 8084 | 8084 | TCP | MQTT over WebSocket (TLS) |
| 8883 | 8883 | TCP | MQTT over TLS |
| 18083 | 18083 | TCP | EMQX 管理ダッシュボード (HTTP) |
| 18084 | 18084 | TCP | EMQX 管理ダッシュボード (HTTPS) |
| 19080 | 19080 | **UDP** | MQTT over QUIC |

ダッシュボードへは `http://localhost:18083` でアクセスできます。
初期ログイン: `admin` / `public`

---

## EMQX 設定 (base.hocon)

`linux_data/config/base.hocon` がコンテナ起動時に EMQX の設定ディレクトリへコピーされます。
編集後にコンテナを再起動すると反映されます。

```bash
docker compose restart
```

設定の優先順位（低 → 高）:

```
base.hocon  <  cluster.hocon  <  emqx.conf  <  環境変数
```

現在の主な設定内容:

- **QUIC リスナー** (`listeners.quic.default`): ポート 19080、TLS 1.3、最大接続数 1,024,000
- 証明書パス: `/home/PEN/WS/cert/` 以下（マウント経由でホストから差し替え可能）

---

## ネットワーク構成

コンテナはカスタムブリッジネットワーク `ethd` に接続されます。
`.env` でサブネット・ゲートウェイを変更できます。

```dotenv
NETWORK_NAME=ethd
IP_SUBNET_ADDR=192.168.1.0
IP_PREFIX=24
IP_GATEWAY_ADDR=192.168.1.1
```

コンテナの IP アドレスを確認するには:

```bash
docker inspect --format="{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" Docker_Linux
```

---

## コンテナの操作

```bash
# 起動
docker compose up -d

# 停止
docker compose down

# シェルに入る
docker exec -it Docker_Linux bash

# EMQX の状態確認（コンテナ内で実行）
/home/PEN/WS/Programs/emqx/_build/emqx-enterprise/rel/emqx/bin/emqx status
```

---

## ファイル詳細

### `.env`

すべての可変パラメータをここで管理します。`docker-compose.yml` と `Dockerfile` は直接編集不要です。

| 変数 | デフォルト | 説明 |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `project1` | Docker Compose プロジェクト名（小文字） |
| `CONTAINER_NAME` | `Docker_Linux` | コンテナ名 |
| `USER_NAME` | `PEN` | コンテナ内ユーザー名 |
| `PASSWORD` | `password` | root・ユーザー共通パスワード |
| `TIME_ZONE` | `Asia/Tokyo` | タイムゾーン |
| `NETWORK_NAME` | `ethd` | ブリッジネットワーク名 |
| `VERSION` | `Default` | EMQX ビルドバージョン指定 |

### `start.sh`（エントリーポイント）

コンテナ起動時に以下の順で処理します。

1. `VERSION` の解釈（`Default` / `Latest` / `X.Y.Z`）
2. unixODBC 2.3.12 のビルド・インストール
3. Erlang/OTP 27.2.3 のビルド・インストール
4. EMQX のクローン・ビルド（`BUILD_WITH_QUIC=1`、`gcc-12` 使用）
5. `base.hocon` のコピー
6. EMQX 起動 → `sleep 1000` ループでコンテナを維持

各ステップはディレクトリの存在チェックにより冪等（再実行しても重複しない）に動作します。

### `createcert.py`

ECDSA (SECP256R1) による自己 CA 証明書とサーバ証明書を生成します。

| パラメータ | デフォルト | 説明 |
|---|---|---|
| `certFile` | `certificate.crt` | サーバ証明書の出力ファイル名 |
| `privateFile` | `private.key` | サーバ秘密鍵の出力ファイル名 |
| `caCertFile` | `ca_cert.crt` | CA 証明書の出力ファイル名 |
| `caprivateKeyFile` | `ca_private.key` | CA 秘密鍵の出力ファイル名 |
| `host` | `127.0.0.1` | SAN (SubjectAlternativeName) に登録する IP |
| `caHost` | `BX293A_PEN` | CA の CommonName |
| `expire` | `10` | 有効期限（年） |
| `overwrite` | `False` | 既存ファイルを上書きするか |

---

## 注意事項

- `PASSWORD=password` はデフォルト値です。**本番・共有環境では必ず変更してください。**
- 生成される自己証明書はローカル開発・検証用です。本番環境では正式な証明書を使用してください。
- `VERSION=Latest` または `X.Y.Z` 指定時、OTP バージョンの互換性は保証されません。ビルドが失敗する場合は `Default` に戻してください。
- QUIC (UDP 19080) を使用する場合、ファイアウォールで UDP ポートの開放が必要です。

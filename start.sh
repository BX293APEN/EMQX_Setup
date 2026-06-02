#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# EMQX エントリーポイント
#
# EMQX_VERSION 変数の挙動:
#   Default (未設定含む) : フォーク版リポジトリをソースからビルド
#                          OTP 27.2.3 + unixODBC 2.3.12 で動作確認済み構成
#
#   Latest               : GitHub から最新タグを取得し
#                          ソースビルドでインストール
#
#   X.Y.Z                : 指定バージョンをソースビルドでインストール
#                          タグが存在しない場合は近似バージョンにフォールバック
# ================================================================

PROGRAMS_DIR="/home/PEN/WS/Programs"
EMQX_OFFICIAL_REPO="https://github.com/emqx/emqx.git"
EMQX_FORK_REPO="https://github.com/BX293APEN/emqx.git"

# ================================================================
# ユーティリティ
# ================================================================
log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

not_exist_directory() {
    [ ! -d "$1" ]
}

make_and_move_working_directory() {
    mkdir -p "${PROGRAMS_DIR}"
    cd "${PROGRAMS_DIR}"
}

# ================================================================
# バージョン解決
#
# タグ形式の変遷:
#   EMQX 5.x (open source)  : v5.8.9  (v プレフィックスあり)
#   EMQX 5.x (enterprise)   : e5.8.9  (e プレフィックスあり)
#   EMQX 6.x                : 6.1.1   (プレフィックスなし)
#
# Latest 取得ロジック:
#   全タグから上記3形式の X.Y.Z 部分を抽出し semver 比較で最大値を返す。
#
# X.Y.Z 指定時のフォールバック:
#   指定バージョンが見つからない場合、同じメジャー・マイナーの中で
#   最も近い（最大の）パッチバージョンを検索する。
#   同一マイナーも存在しない場合は同一メジャーの最新バージョンを使用する。
# ================================================================

# リモートから全バージョン番号(X.Y.Z形式)をソートして取得する共通関数
fetch_all_versions() {
    git ls-remote --tags "${EMQX_OFFICIAL_REPO}" \
        | grep -oP 'refs/tags/(v|e)?\K[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | uniq
}

resolve_version() {
    local ver="${EMQX_VERSION:-Default}"

    if [ "${ver}" = "Default" ] || [ -z "${ver}" ]; then
        echo "Default"
        return
    fi

    if [ "${ver}" = "Latest" ]; then
        local latest
        latest=$(fetch_all_versions | tail -1)
        if [ -z "${latest}" ]; then
            log_err "最新バージョンの取得に失敗しました。Default にフォールバックします。"
            echo "Default"
        else
            log "Latest バージョン解決: ${latest}"
            echo "${latest}"
        fi
        return
    fi

    # X.Y.Z 形式チェック
    if echo "${ver}" | grep -qP '^\d+\.\d+\.\d+$'; then
        # v / e / プレフィックスなし の3パターンを検索
        local tag_exists
        tag_exists=$(git ls-remote --tags "${EMQX_OFFICIAL_REPO}" \
                     "refs/tags/v${ver}" \
                     "refs/tags/e${ver}" \
                     "refs/tags/${ver}" \
                     | wc -l)
        if [ "${tag_exists}" -gt 0 ]; then
            echo "${ver}"
            return
        fi

        # ---- バージョンが見つからない: 近似バージョンを探す ----
        log_err "バージョン ${ver} のタグが見つかりません。近似バージョンを検索します..."

        local req_major req_minor req_patch
        req_major=$(echo "${ver}" | cut -d. -f1)
        req_minor=$(echo "${ver}" | cut -d. -f2)
        req_patch=$(echo "${ver}" | cut -d. -f3)

        local all_versions
        all_versions=$(fetch_all_versions)

        # 1) 同一メジャー・マイナーで最も近いパッチ(>=指定, なければ直前)を探す
        local same_minor_versions
        same_minor_versions=$(echo "${all_versions}" \
            | grep -P "^${req_major}\.${req_minor}\.")

        local closest=""
        if [ -n "${same_minor_versions}" ]; then
            # 指定パッチ以上で最小のもの(切り上げ)を優先
            closest=$(echo "${same_minor_versions}" \
                | awk -F. -v p="${req_patch}" '$3 >= p' \
                | head -1)
            # なければ同一マイナー内の最大パッチ(切り捨て)
            if [ -z "${closest}" ]; then
                closest=$(echo "${same_minor_versions}" | tail -1)
            fi
        fi

        # 2) 同一マイナーも存在しない: 同一メジャーの最新バージョンを使用
        if [ -z "${closest}" ]; then
            closest=$(echo "${all_versions}" \
                | grep -P "^${req_major}\." \
                | tail -1)
        fi

        if [ -n "${closest}" ]; then
            log_err "  -> ${ver} の近似バージョン ${closest} を使用します。"
            echo "${closest}"
        else
            log_err "  -> 近似バージョンも見つかりません。Default にフォールバックします。"
            echo "Default"
        fi
        return
    fi

    log_err "VERSION='${ver}' は認識できません。Default にフォールバックします。"
    echo "Default"
}

# ================================================================
# env.sh から OTP / Elixir バージョンを取得する
#
# EMQX 5.8 以降はリポジトリに env.sh が存在し正確なバージョンが記載される。
# env.sh が存在しない (5.7以前) 場合は静的対応表にフォールバックする。
#
# env.sh の OTP_VSN は "26.2.5.14-1" のようなビルド番号付き形式のため、
# ハイフン以降を除去して純粋な OTP バージョン番号として扱う。
# ================================================================
get_build_versions_for_emqx() {
    local emqx_ver="$1"
    local major minor
    major=$(echo "${emqx_ver}" | cut -d. -f1)
    minor=$(echo "${emqx_ver}" | cut -d. -f2)

    local git_tag
    git_tag=$(get_git_tag "${emqx_ver}")

    # env.sh からの取得を試みる
    local env_sh_url="https://raw.githubusercontent.com/emqx/emqx/${git_tag}/env.sh"
    local env_content
    env_content=$(curl -sf "${env_sh_url}" 2>/dev/null || true)

    if [ -n "${env_content}" ]; then
        # OTP_VSN: "28.4.1-1" → "28.4.1"
        local otp_raw elixir_raw
        otp_raw=$(echo "${env_content}" | grep -oP 'OTP_VSN=\K[^\s]+' | head -1 | cut -d- -f1)
        elixir_raw=$(echo "${env_content}" | grep -oP 'ELIXIR_VSN=\K[^\s]+' | head -1)

        if [ -n "${otp_raw}" ] && [ -n "${elixir_raw}" ]; then
            log "env.sh から取得: OTP=${otp_raw}, Elixir=${elixir_raw}"
            echo "${otp_raw} ${elixir_raw}"
            return
        fi
    fi

    # env.sh が存在しない / 取得失敗 → 静的対応表にフォールバック
    log_err "env.sh の取得失敗。静的対応表を使用します (EMQX ${emqx_ver})"

    local otp_ver elixir_ver
    if [ "${major}" -eq 5 ]; then
        if   [ "${minor}" -le 1 ]; then otp_ver="24.3.4.17";  elixir_ver=""
        elif [ "${minor}" -le 3 ]; then otp_ver="25.3.2.20";  elixir_ver=""
        elif [ "${minor}" -le 7 ]; then otp_ver="26.2.5.2";   elixir_ver="1.15.7"
        else                            otp_ver="26.2.5.14";  elixir_ver="1.15.7"
        fi
    elif [ "${major}" -eq 6 ]; then
        if   [ "${minor}" -eq 0 ]; then otp_ver="27.3.4.2";   elixir_ver="1.18.3"
        elif [ "${minor}" -eq 1 ]; then otp_ver="28.2";       elixir_ver="1.19.1"
        else                            otp_ver="28.4.1";     elixir_ver="1.19.1"
        fi
    else
        log_err "未知のメジャーバージョン ${major}。OTP 28.4.1 / Elixir 1.19.1 を使用します。"
        otp_ver="28.4.1"
        elixir_ver="1.19.1"
    fi

    echo "${otp_ver} ${elixir_ver}"
}

# ================================================================
# git clone で使うタグ名を返す
#   $1: EMQX バージョン (X.Y.Z)
#
# タグ形式の変遷:
#   5.x  : "v5.8.9" (v プレフィックスあり)
#   6.x+ : "6.1.1"  (プレフィックスなし)
# ================================================================
get_git_tag() {
    local emqx_ver="$1"
    local major
    major=$(echo "${emqx_ver}" | cut -d. -f1)

    if [ "${major}" -ge 6 ]; then
        echo "${emqx_ver}"
    else
        echo "v${emqx_ver}"
    fi
}

# ================================================================
# unixODBC ソースビルド  ※ ソースビルドルート専用
#   $1: unixODBC バージョン
#
# OTP の ODBC アプリケーションを有効化するために必要。
# OTP configure が unixODBC を参照するため、build_otp より先に呼ぶこと。
# ================================================================
build_unixodbc() {
    local unixodbc_ver="$1"
    log "=== unixODBC ${unixodbc_ver} のビルド ==="
    cd "${PROGRAMS_DIR}"

    local src_dir="${PROGRAMS_DIR}/unixODBC-${unixodbc_ver}"

    if not_exist_directory "${src_dir}"; then
        wget -q "https://www.unixodbc.org/unixODBC-${unixodbc_ver}.tar.gz"
        tar -xzf "unixODBC-${unixodbc_ver}.tar.gz"
    fi

    cd "${src_dir}"
    ./configure --quiet
    make -s
    make install
    log "unixODBC ${unixodbc_ver} インストール完了"
}

# ================================================================
# OTP ソースビルド  ※ ソースビルドルート専用
#   $1: OTP バージョン (例: 27.3.4.2)
#
# build_unixodbc() の後に呼ぶこと (--enable-odbc が unixODBC を参照するため)。
# ================================================================
build_otp() {
    local otp_ver="$1"
    log "=== Erlang/OTP ${otp_ver} のビルド ==="
    cd "${PROGRAMS_DIR}"

    local src_dir="${PROGRAMS_DIR}/otp_src_${otp_ver}"

    if not_exist_directory "${src_dir}"; then
        wget -q "https://github.com/erlang/otp/releases/download/OTP-${otp_ver}/otp_src_${otp_ver}.tar.gz"
        tar -xzf "otp_src_${otp_ver}.tar.gz"
    fi

    cd "${src_dir}"
    # --enable-odbc: build_unixodbc() でインストールした unixODBC を使用する
    ./configure --prefix=/usr \
        --enable-kernel-poll \
        --enable-dirty-schedulers \
        --enable-jit \
        --enable-odbc \
        --with-ssl \
        > /tmp/otp_configure.log 2>&1
    make -s -j"$(nproc)"
    make install
    erl -noshell -eval "application:load(odbc), application:start(odbc), halt()."
    log "Erlang/OTP ${otp_ver} インストール完了"
}

# ================================================================
# Elixir インストール  ※ ソースビルドルート専用
#   $1: Elixir バージョン (例: 1.19.1)
#
# EMQX のビルドシステムが mix を使うため必須。
# build_otp() の後に呼ぶこと (Elixir は OTP に依存するため)。
#
# インストール方法:
#   GitHub リリースから precompiled バイナリ (elixir-otp-XX.zip) を取得。
#   OTP メジャーバージョンに対応した zip を選択する。
#   /usr/local/elixir に展開し PATH に追加する。
# ================================================================
install_elixir() {
    local elixir_ver="$1"
    local otp_ver="$2"

    log "=== Elixir ${elixir_ver} のインストール ==="

    # OTP メジャーバージョン (例: 28.4.1 → 28)
    local otp_major
    otp_major=$(echo "${otp_ver}" | cut -d. -f1)

    local elixir_zip="elixir-otp-${otp_major}.zip"
    local elixir_url="https://github.com/elixir-lang/elixir/releases/download/v${elixir_ver}/${elixir_zip}"
    local install_dir="/usr/local/elixir"

    cd "${PROGRAMS_DIR}"

    if not_exist_directory "${install_dir}"; then
        log "Elixir ${elixir_ver} (OTP ${otp_major} 向け) をダウンロード中..."
        wget -q "${elixir_url}" -O "${elixir_zip}"
        mkdir -p "${install_dir}"
        unzip -q "${elixir_zip}" -d "${install_dir}"
        rm -f "${elixir_zip}"
    fi

    # PATH に追加 (既に追加済みでも冪等)
    export PATH="${install_dir}/bin:${PATH}"

    # 確認
    local installed_ver
    installed_ver=$(elixir --version 2>&1 | grep -oP 'Elixir \K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    log "Elixir ${installed_ver} インストール完了 (PATH: ${install_dir}/bin)"
}

# ================================================================
# Default: フォーク版 EMQX をソースビルド  ※ 動作を一切変更しない
#
# OTP 27.2.3 + unixODBC 2.3.12 + BX293APEN フォークの組み合わせが
# 動作確認済みのため、汎用化せずこの構成を固定で維持する。
# ================================================================
# Default ビルド専用の固定バージョン
DEFAULT_OTP_VERSION="27.2.3"
DEFAULT_UNIXODBC_VERSION="2.3.12"

default_install() {
    log "=== Default インストール開始 (フォーク版 EMQX ソースビルド) ==="

    # unixODBC → OTP の順でビルド (OTP configure が unixODBC を参照するため)
    build_unixodbc "${DEFAULT_UNIXODBC_VERSION}"
    build_otp "${DEFAULT_OTP_VERSION}"

    cd "${PROGRAMS_DIR}"
    if not_exist_directory "${PROGRAMS_DIR}/emqx"; then
        log "EMQX フォーク版をクローン中..."
        git clone "${EMQX_FORK_REPO}"
        cd emqx
        export BUILD_WITH_QUIC=1
        CC=gcc-12 CXX=g++-12 make
        cd _build/emqx-enterprise/rel/emqx
        sudo chmod -R 777 data/*
    fi

    setup_config_and_certs \
        "/home/PEN/WS/Programs/emqx/_build/emqx-enterprise/rel/emqx"

    log "EMQX 起動中..."
    /home/PEN/WS/Programs/emqx/_build/emqx-enterprise/rel/emqx/bin/emqx start
    log "=== Default インストール完了 ==="
}

# ================================================================
# ソースビルドインストール (バージョン指定)
#   $1: EMQX バージョン (X.Y.Z)
#
# Latest / X.Y.Z 指定時のビルド先。
# get_build_versions_for_emqx で指定 EMQX に対応する OTP / Elixir を決定し
# 公式リポジトリからソースをビルドする。
#
# Elixir について:
#   EMQX 5.8 以降はビルドシステムに mix が必要。
#   env.sh から ELIXIR_VSN を取得し、OTP ビルド後にインストールする。
#   ELIXIR_VSN が空の場合 (5.0–5.3) は Elixir インストールをスキップする。
#
# ensure-rebar3.sh について:
#   EMQX 5.4 以降はリポジトリ内に scripts/ensure-rebar3.sh が含まれており、
#   これを使って EMQX 専用バージョンの rebar3 を取得する必要がある。
#   システムの rebar3 を使うと依存プラグインのバージョン互換性エラーが発生する。
#   5.0–5.3 では ensure-rebar3.sh が存在しないため、この処理はスキップされる。
# ================================================================
source_build_install() {
    local emqx_ver="$1"

    # OTP / Elixir バージョンを取得 (スペース区切り: "OTP_VER ELIXIR_VER")
    local build_versions
    build_versions=$(get_build_versions_for_emqx "${emqx_ver}")
    local otp_ver elixir_ver
    otp_ver=$(echo "${build_versions}" | cut -d' ' -f1)
    elixir_ver=$(echo "${build_versions}" | cut -d' ' -f2)

    log "=== ソースビルド: EMQX ${emqx_ver} / OTP ${otp_ver} / Elixir ${elixir_ver:-なし} ==="

    # unixODBC → OTP → Elixir の順でビルド/インストール
    build_unixodbc "${DEFAULT_UNIXODBC_VERSION}"
    build_otp "${otp_ver}"

    # Elixir が必要な場合のみインストール (5.4 以降)
    if [ -n "${elixir_ver}" ]; then
        install_elixir "${elixir_ver}" "${otp_ver}"
    fi

    cd "${PROGRAMS_DIR}"
    local src_dir="${PROGRAMS_DIR}/emqx-src-${emqx_ver}"

    if not_exist_directory "${src_dir}"; then
        log "EMQX v${emqx_ver} をクローン中..."
        local git_tag
        git_tag=$(get_git_tag "${emqx_ver}")
        git clone --depth 1 --branch "${git_tag}" "${EMQX_OFFICIAL_REPO}" "${src_dir}"
        cd "${src_dir}"

        # ensure-rebar3.sh が存在する場合は専用 rebar3 を取得してから make する
        # (EMQX 5.4 以降に含まれる。存在しない場合は apt インストール済みを使用)
        if [ -f "scripts/ensure-rebar3.sh" ]; then
            log "ensure-rebar3.sh を実行して専用 rebar3 を取得します..."
            bash scripts/ensure-rebar3.sh
        fi

        export BUILD_WITH_QUIC=1
        CC=gcc-12 CXX=g++-12 make
        chmod -R 777 _build/emqx-enterprise/rel/emqx/data/
    fi

    local emqx_root="${src_dir}/_build/emqx-enterprise/rel/emqx"
    setup_config_and_certs "${emqx_root}"

    log "EMQX ${emqx_ver} 起動中..."
    "${emqx_root}/bin/emqx" start
    log "=== ソースビルド完了 ==="
}

# ================================================================
# 証明書・設定ファイルのセットアップ
#   $1: EMQX インストールディレクトリ
# ================================================================
setup_config_and_certs() {
    local emqx_root="$1"

    mkdir -p /home/PEN/WS/cert

    # マウントされた設定ファイルが存在すればコピー、
    # なければスクリプト内に埋め込んだデフォルト設定を書き込む
    if [ -f "/home/PEN/WS/config/base.hocon" ]; then
        cp /home/PEN/WS/config/base.hocon "${emqx_root}/etc/base.hocon"
        log "base.hocon をコピーしました: ${emqx_root}/etc/base.hocon"
    else
        log "base.hocon が見つかりません。デフォルト設定を書き込みます: ${emqx_root}/etc/base.hocon"
        mkdir -p "${emqx_root}/etc"
        cat > "${emqx_root}/etc/base.hocon" << 'HOCON_EOF'
## Define configurations that can later be overridden through UI/API/CLI.
##
## Config precedence order:
##   etc/base.hocon < cluster.hocon < emqx.conf < environment variables

## Logging configs
log {
    file {
        # level = warning
    }
    console {
        # level = warning
    }
}

listeners.quic.default {
    enabled = true
    bind = "0.0.0.0:19080"
    max_connections = 1024000
    ssl_options {
        keyfile = "/home/PEN/WS/cert/private.key"
        certfile = "/home/PEN/WS/cert/certificate.crt"
        # keypassword = "your_key_password" # 秘密鍵にパスワードがある場合
        versions = [tlsv1.3]
        verify = verify_none
        ciphers = "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256"
    }
}
HOCON_EOF
        log "デフォルト base.hocon を書き込みました"
    fi
}

# ================================================================
# メイン処理
# ================================================================
make_and_move_working_directory

RESOLVED_VERSION=$(resolve_version)
log "==> EMQX_VERSION=${EMQX_VERSION:-Default}  resolved=${RESOLVED_VERSION}"

if [ "${RESOLVED_VERSION}" = "Default" ]; then
    default_install
else
    source_build_install "${RESOLVED_VERSION}"
fi

# コンテナをフォアグラウンドで維持
while true; do
    sleep 1000
done
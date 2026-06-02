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
#                          公式ビルド済みパッケージをインストール
#
#   X.Y.Z                : 指定バージョンの公式パッケージをインストール
#                          タグが存在しない場合は Default にフォールバック
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
# ================================================================
resolve_version() {
    local ver="${EMQX_VERSION:-Default}"

    if [ "${ver}" = "Default" ] || [ -z "${ver}" ]; then
        echo "Default"
        return
    fi

    if [ "${ver}" = "Latest" ]; then
        local latest
        latest=$(git ls-remote --tags --sort="-v:refname" "${EMQX_OFFICIAL_REPO}" \
                 | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
                 | head -1)
        if [ -z "${latest}" ]; then
            log_err "最新バージョンの取得に失敗しました。Default にフォールバックします。"
            echo "Default"
        else
            echo "${latest}"
        fi
        return
    fi

    # X.Y.Z 形式チェック
    if echo "${ver}" | grep -qP '^\d+\.\d+\.\d+$'; then
        local tag_exists
        tag_exists=$(git ls-remote --tags "${EMQX_OFFICIAL_REPO}" "refs/tags/v${ver}" \
                     | wc -l)
        if [ "${tag_exists}" -gt 0 ]; then
            echo "${ver}"
        else
            log_err "バージョン ${ver} は見つかりませんでした。Default にフォールバックします。"
            echo "Default"
        fi
        return
    fi

    log_err "VERSION='${ver}' は認識できません。Default にフォールバックします。"
    echo "Default"
}

# ================================================================
# EMQX バージョンに対応する OTP バージョンを返す
#
# 対応表:
#   5.0–5.1  : OTP 24.x  → 24.3.4.17
#   5.2–5.3  : OTP 25.x  → 25.3.2.20
#   5.4–5.10 : OTP 26.x  → 26.2.5.14
#   6.0      : OTP 27.x  → 27.3.4
#   6.1+     : OTP 28.x  → 28.0
#
# 公式パッケージは OTP を同梱するためこの関数は使わない。
# ソースビルド時 (default_install / source_build_install) に使用する。
# ================================================================
get_otp_version_for_emqx() {
    local emqx_ver="$1"
    local major minor
    major=$(echo "${emqx_ver}" | cut -d. -f1)
    minor=$(echo "${emqx_ver}" | cut -d. -f2)

    if [ "${major}" -eq 5 ]; then
        if   [ "${minor}" -le 1 ]; then echo "24.3.4.17"
        elif [ "${minor}" -le 3 ]; then echo "25.3.2.20"
        else                            echo "26.2.5.14"
        fi
    elif [ "${major}" -eq 6 ]; then
        if [ "${minor}" -eq 0 ]; then echo "27.3.4"
        else                          echo "28.0"
        fi
    else
        # 未知のメジャーバージョンは最新の確認済み OTP を使う
        log_err "未知のメジャーバージョン ${major}。OTP 28.0 を使用します。"
        echo "28.0"
    fi
}

# ================================================================
# unixODBC ソースビルド  ※ ソースビルドルート専用
#   $1: unixODBC バージョン
#
# OTP の ODBC アプリケーションを有効化するために必要。
# OTP configure が unixODBC を参照するため、build_otp より先に呼ぶこと。
# unixODBC の API (SQLAllocHandle 等) は 2.3.x 系で安定しており
# OTP の要求するインターフェースとの互換性に問題はない。
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
#   $1: OTP バージョン (例: 27.2.3)
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
# Default: フォーク版 EMQX をソースビルド
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
# 公式パッケージインストール
#   $1: EMQX バージョン (X.Y.Z)
#
# 公式リリースは OTP を同梱した tar.gz パッケージを提供しているため
# OTP・unixODBC のソースビルドは不要。
# パッケージが見つからない場合は source_build_install にフォールバックする。
#
# URL 形式:
#   https://github.com/emqx/emqx/releases/download/vX.Y.Z/
#     emqx-enterprise-X.Y.Z-ubuntu{distro}-amd64.tar.gz
# Ubuntu 25.04 向けビルドが存在しない場合は 24.04 → 22.04 へフォールバック。
# ================================================================
install_official_package() {
    local emqx_ver="$1"
    log "=== 公式パッケージインストール: EMQX ${emqx_ver} ==="

    cd "${PROGRAMS_DIR}"

    local install_dir="${PROGRAMS_DIR}/emqx-${emqx_ver}"

    if not_exist_directory "${install_dir}"; then
        local pkg_file=""
        local dl_url=""

        for distro in "ubuntu25.04" "ubuntu24.04" "ubuntu22.04"; do
            local candidate_file="emqx-enterprise-${emqx_ver}-${distro}-amd64.tar.gz"
            local candidate_url="https://github.com/emqx/emqx/releases/download/v${emqx_ver}/${candidate_file}"
            log "パッケージ URL を確認中: ${candidate_url}"
            if wget -q --spider "${candidate_url}" 2>/dev/null; then
                pkg_file="${candidate_file}"
                dl_url="${candidate_url}"
                log "利用可能: ${candidate_url}"
                break
            fi
        done

        if [ -z "${dl_url}" ]; then
            log_err "EMQX ${emqx_ver} の Ubuntu パッケージが見つかりませんでした。ソースビルドにフォールバックします。"
            # パッケージが存在しないバージョンはソースビルドで対応する。
            # default_install (フォーク固定) ではなく、指定バージョンに合わせた
            # OTP を選択してソースビルドする。
            source_build_install "${emqx_ver}"
            return
        fi

        log "ダウンロード中: ${dl_url}"
        wget -q "${dl_url}" -O "${pkg_file}"
        mkdir -p "${install_dir}"
        tar -xzf "${pkg_file}" -C "${install_dir}" --strip-components=1
        rm -f "${pkg_file}"
    fi

    setup_config_and_certs "${install_dir}"

    log "EMQX ${emqx_ver} 起動中..."
    "${install_dir}/bin/emqx" start
    log "=== 公式パッケージインストール完了 ==="
}

# ================================================================
# ソースビルドインストール (バージョン指定)
#   $1: EMQX バージョン (X.Y.Z)
#
# install_official_package のフォールバック先。
# get_otp_version_for_emqx で指定 EMQX に対応する OTP を選択し
# 公式リポジトリからソースをビルドする。
# unixODBC は OTP の ODBC アプリが要求するインターフェースが
# 2.3.x 系で安定しているため、バージョンに関わらず 2.3.12 を使用する。
# ================================================================
source_build_install() {
    local emqx_ver="$1"
    local otp_ver
    otp_ver=$(get_otp_version_for_emqx "${emqx_ver}")

    log "=== ソースビルド: EMQX ${emqx_ver} / OTP ${otp_ver} ==="

    # unixODBC → OTP の順でビルド
    build_unixodbc "${DEFAULT_UNIXODBC_VERSION}"
    build_otp "${otp_ver}"

    cd "${PROGRAMS_DIR}"
    local src_dir="${PROGRAMS_DIR}/emqx-src-${emqx_ver}"

    if not_exist_directory "${src_dir}"; then
        log "EMQX v${emqx_ver} をクローン中..."
        git clone --depth 1 --branch "v${emqx_ver}" "${EMQX_OFFICIAL_REPO}" "${src_dir}"
        cd "${src_dir}"
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
## EMQX provides support for two primary log handlers: `file` and `console`,
## with an additional `audit` handler specifically designed to always direct logs to files.
## The system's default log handling behavior can be configured via the environment
## variable `EMQX_DEFAULT_LOG_HANDLER`, which accepts the following settings:
##  - `file`: Directs log output exclusively to files.
##  - `console`: Channels log output solely to the console.
## It's noteworthy that `EMQX_DEFAULT_LOG_HANDLER` is set to `file`
## when EMQX is initiated via systemd `emqx.service` file.
## In scenarios outside systemd initiation, `console` serves as the default log handler.
## Read more about configs here: https://docs.emqx.com/en/enterprise/latest/configuration/logs.html
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
    install_official_package "${RESOLVED_VERSION}"
fi

# コンテナをフォアグラウンドで維持
while true; do
    sleep 1000
done

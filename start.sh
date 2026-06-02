#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# EMQX エントリーポイント
#
# VERSION 変数の挙動:
#   Default (未設定含む) : フォーク版リポジトリをソースからビルド
#                          OTP 27.2.3 + unixODBC 2.3.12 で動作確認済み構成
#
#   Latest               : GitHub から最新タグを取得し
#                          公式ビルド済みパッケージをインストール
#
#   X.Y.Z                : 指定バージョンの公式パッケージをインストール
#                          タグが存在しない場合は Default にフォールバック
#
# ================================================================
# ----------------------------------------------------------------
# OTP / rebar3 / unixODBC のバージョン対応
#
#   EMQX 5.0–5.1 : OTP 24.x / rebar3 ≥3.18 / unixODBC: apt で十分
#   EMQX 5.2–5.3 : OTP 25.x / rebar3 ≥3.20 / unixODBC: apt で十分
#   EMQX 5.4–5.10: OTP 26.2.x / rebar3 ≥3.22 / unixODBC: apt で十分
#                  (EMQX はビルド時に rebar3 を自前でダウンロードするため
#                   システムの rebar3 は参照されない)
#   EMQX 6.0     : OTP 27.x / rebar3 ≥3.23 / unixODBC: apt で十分
#   EMQX 6.1+    : OTP 28.x / rebar3 ≥3.23 / unixODBC: apt で十分
#                  (v6.1.0 リリースノートで OTP27→OTP28 への移行が記載)
#
#   Default ビルド(BX293APEN フォーク):
#     動作確認済み構成を維持するため OTP/unixODBC をソースビルドする。
#     公式パッケージインストール時は OTP が同梱されるため不要。
# ----------------------------------------------------------------

PROGRAMS_DIR="/home/PEN/WS/Programs"
EMQX_OFFICIAL_REPO="https://github.com/emqx/emqx.git"
EMQX_FORK_REPO="https://github.com/BX293APEN/emqx.git"

UNIXODBC_VERSION="2.3.12"
OTP_VERSION="27.2.3"

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
# メジャーバージョン取得 (X.Y.Z → X)
# ================================================================
get_major_version() {
    echo "$1" | cut -d. -f1
}

# ================================================================
# バージョンに応じた OTP バージョンを返す
#   EMQX 5.0–5.1 → 24   (OTP24 系の最新安定: 24.3.4.17)
#   EMQX 5.2–5.3 → 25   (OTP25 系の最新安定: 25.3.2.20)
#   EMQX 5.4–5.10→ 26   (OTP26 系の最新安定: 26.2.5.14)
#   EMQX 6.0     → 27   (OTP27 系の最新安定: 27.3.4)
#   EMQX 6.1+    → 28   (OTP28 系の最新安定: 28.0)
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
        # 未知のメジャーバージョンはデフォルト OTP を使う
        echo "27.3.4"
    fi
}

# ================================================================
# unixODBC ソースビルド
#   引数なし: UNIXODBC_VERSION を使用
# ================================================================
build_unixodbc() {
    log "=== unixODBC ${UNIXODBC_VERSION} のビルド ==="
    cd "${PROGRAMS_DIR}"

    local src_dir="${PROGRAMS_DIR}/unixODBC-${UNIXODBC_VERSION}"

    if not_exist_directory "${src_dir}"; then
        wget -q "https://www.unixodbc.org/unixODBC-${UNIXODBC_VERSION}.tar.gz"
        tar -xzf "unixODBC-${UNIXODBC_VERSION}.tar.gz"
    fi

    cd "${src_dir}"
    ./configure --quiet
    make -s
    make install
    log "unixODBC ${UNIXODBC_VERSION} インストール完了"
}

# ================================================================
# OTP ソースビルド
#   $1: OTP バージョン (例: 27.2.3)
# ================================================================
build_otp() {
    local otp_ver="${1:-${OTP_VERSION}}"
    log "=== Erlang/OTP ${otp_ver} のビルド ==="
    cd "${PROGRAMS_DIR}"

    local src_dir="${PROGRAMS_DIR}/otp_src_${otp_ver}"

    if not_exist_directory "${src_dir}"; then
        wget -q "https://github.com/erlang/otp/releases/download/OTP-${otp_ver}/otp_src_${otp_ver}.tar.gz"
        tar -xzf "otp_src_${otp_ver}.tar.gz"
    fi

    cd "${src_dir}"
    # --enable-odbc: unixODBC がインストール済みであること
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
#   OTP 27.2.3 + unixODBC 2.3.12 の動作確認済み組み合わせを維持
# ================================================================
default_install() {
    log "=== Default インストール開始 (フォーク版 EMQX ソースビルド) ==="

    build_unixodbc
    build_otp "${OTP_VERSION}"

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

    setup_config_and_certs

    log "EMQX 起動中..."
    /home/PEN/WS/Programs/emqx/_build/emqx-enterprise/rel/emqx/bin/emqx start
    log "=== Default インストール完了 ==="
}

# ================================================================
# 公式パッケージインストール
#   $1: EMQX バージョン (X.Y.Z)
#
#   公式リリースは OTP を同梱した tar.gz パッケージを提供しているため
#   OTP・unixODBC のソースビルドは不要。
#
#   URL 形式:
#     v5.9.0 以降 (OSS/Enterprise 統合):
#       https://github.com/emqx/emqx/releases/download/vX.Y.Z/
#         emqx-enterprise-X.Y.Z-ubuntu{distro}-amd64.tar.gz
#     v5.8.x 以前 (Enterprise):
#       https://github.com/emqx/emqx/releases/download/vX.Y.Z/
#         emqx-enterprise-X.Y.Z-ubuntu{distro}-amd64.tar.gz
#
#   Ubuntu 25.04 向けビルドが存在しない場合は ubuntu24.04 にフォールバック。
# ================================================================
install_official_package() {
    local emqx_ver="$1"
    log "=== 公式パッケージインストール: EMQX ${emqx_ver} ==="

    cd "${PROGRAMS_DIR}"

    local install_dir="${PROGRAMS_DIR}/emqx-${emqx_ver}"

    if not_exist_directory "${install_dir}"; then
        local pkg_file=""
        local dl_url=""

        # Ubuntu バージョン: 25.04 向けを試し、なければ 24.04 にフォールバック
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
            log_err "EMQX ${emqx_ver} の Ubuntu パッケージが見つかりませんでした。Default にフォールバックします。"
            default_install
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
# 証明書・設定ファイルのセットアップ
#   $1: EMQX インストールディレクトリ (省略時は Default ビルドのパス)
# ================================================================
setup_config_and_certs() {
    local emqx_root="${1:-/home/PEN/WS/Programs/emqx/_build/emqx-enterprise/rel/emqx}"

    # 証明書ディレクトリ
    mkdir -p /home/PEN/WS/cert

    # base.hocon のコピー
    if [ -f "/home/PEN/WS/config/base.hocon" ]; then
        cp /home/PEN/WS/config/base.hocon "${emqx_root}/etc/base.hocon"
        log "base.hocon をコピーしました: ${emqx_root}/etc/base.hocon"
    else
        log_err "base.hocon が見つかりません: /home/PEN/WS/config/base.hocon (スキップします)"
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

#!/usr/bin/env bash

# コメントは整理すること

# ----------------------------------------------------------------
# バージョン解決
# ----------------------------------------------------------------
# ================================================================
# EMQX_VERSION の解釈
#
#   Default (未設定含む) : フォーク版リポジトリをソースからビルド
#                          (動作確認済みの構成をそのまま維持)
#
#   Latest               : GitHub から最新タグを取得し、
#                          公式ビルド済みパッケージをインストール
#
#   X.Y.Z                : 指定バージョンの公式パッケージをインストール
#                          タグが存在しない場合は Default にフォールバック
#
# ================================================================
resolve_version() {
    local ver="${EMQX_VERSION:-Default}"

    if [ "${ver}" = "Default" ] || [ -z "${ver}" ]; then
        echo "Default"
        return
    fi

    if [ "${ver}" = "Latest" ]; then
        local latest
        latest=$(git ls-remote --tags --sort="-v:refname" "${EMQX_REPO_OFFICIAL}" \
                 | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
                 | head -1)
        if [ -z "${latest}" ]; then
            echo "※ 最新バージョンの取得に失敗しました。Defaultにフォールバックします。" >&2
            echo "Default"
        else
            echo "${latest}"
        fi
        return
    fi

    # X.Y.Z 形式チェック
    if echo "${ver}" | grep -qP '^\d+\.\d+\.\d+$'; then
        local tag_exists
        tag_exists=$(git ls-remote --tags "${EMQX_REPO_OFFICIAL}" "refs/tags/v${ver}" \
                     | wc -l)
        if [ "${tag_exists}" -gt 0 ]; then
            echo "${ver}"
        else
            echo "※ バージョン ${ver} は見つかりませんでした。Defaultにフォールバックします。" >&2
            echo "Default"
        fi
        return
    fi

    echo "※ VERSION='${ver}' は認識できません。Defaultにフォールバックします。" >&2
    echo "Default"
}


make_and_move_working_directory(){
    mkdir -p /home/PEN/WS/Programs
    cd /home/PEN/WS/Programs
}

not_exist_directory() {
    [ ! -d "$1" ]
}


# ----------------------------------------------------------------
# Default : 動作確認済み環境(OTP/rebar3/unixODBC 込みのソースビルド)
#           OTP/rebar3/unixODBC のバージョンや依存関係が確認済みのため
#           ソースビルドを維持する。これらはバージョンごとに異なるため
#           汎用的なソースビルドは危険。
# ----------------------------------------------------------------
default_install(){
    if not_exist_directory "/home/PEN/WS/Programs/unixODBC-2.3.12"; then
        wget https://www.unixodbc.org/unixODBC-2.3.12.tar.gz
        tar -xzf unixODBC-2.3.12.tar.gz
        cd unixODBC-2.3.12
        ./configure 
        make
    fi
    cd /home/PEN/WS/Programs/unixODBC-2.3.12
    make install

    cd /home/PEN/WS/Programs
    if not_exist_directory "/home/PEN/WS/Programs/otp_src_27.2.3"; then
        wget https://github.com/erlang/otp/releases/download/OTP-27.2.3/otp_src_27.2.3.tar.gz
        tar -xzf otp_src_27.2.3.tar.gz
        cd otp_src_27.2.3
        ./configure --prefix=/usr --enable-kernel-poll --enable-dirty-schedulers --enable-jit --enable-odbc --with-ssl
        make
    fi
    cd /home/PEN/WS/Programs/otp_src_27.2.3
    make install
    erl -noshell -eval "application:load(odbc), application:start(odbc), halt()."

    cd /home/PEN/WS/Programs
    if not_exist_directory "/home/PEN/WS/Programs/emqx"; then
        git clone https://github.com/BX293APEN/emqx.git
        cd emqx
        export BUILD_WITH_QUIC=1
        CC=gcc-12 CXX=g++-12 make
        cd _build/emqx-enterprise/rel/emqx
        sudo chmod -R 777 data/*
    fi

    cd /home/PEN/WS/
    mkdir -p /home/PEN/WS/cert

    if [ -f "/home/PEN/WS/config/base.hocon" ]; then
        cp /home/PEN/WS/config/base.hocon /home/PEN/WS/Programs/emqx/_build/emqx-enterprise/rel/emqx/etc/base.hocon
    fi

    cd /home/PEN/WS/
    /home/PEN/WS/Programs/emqx/_build/emqx-enterprise/rel/emqx/bin/emqx start
}

# ================================================================
# arg1  : EMQXのバージョン
# EMQXのバージョンから使用するOTP/rebar3/unixODBCのバージョンを取得
# ================================================================
get_modules_version(){
    
}

# ================================================================
#   Latest               :  GitHub から最新タグを取得し、
#                           ソースコードをDLしてビルド   ← アーキテクチャ非依存になる
#                           OTP は EMQX バイナリに同梱されているため互換問題なし。 ←AI生成の文章なので怪しい 本当か実際に確認してほしい
#                           URL形式: https://github.com/emqx/emqx/releases/download/
#                                   vX.Y.Z/emqx-enterprise-X.Y.Z-ubuntu{distro}-amd64.tar.gz
#                           エンタープライズ向けとオープンソース向けが統合された可能性ありURLは要確認
#
#   X.Y.Z                : 指定バージョンのソースコードをDLしてビルド   ← アーキテクチャ非依存になる
#                          タグが存在しない場合は Default にフォールバック

# ================================================================
install_official_package() {
    # 作成中
    # 2026年6月現在のEMQX最新バージョンは6.2.0です
    # 詳細 : https://github.com/emqx/emqx
    # get_modules_version $1
}

make_and_move_working_directory

RESOLVED_VERSION=$(resolve_version)
if [ "${RESOLVED_VERSION}" = "Default" ]; then
    default_install
else
    install_official_package
fi

while true; do
    sleep 1000 
done
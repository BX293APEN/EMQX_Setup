#!/usr/bin/env bash

if [ ! -d "/home/PEN/WS/Programs" ]; then
    mkdir -p /home/PEN/WS/Programs
fi

cd /home/PEN/WS/Programs
if [ ! -d "/home/PEN/WS/Programs/unixODBC-2.3.12" ]; then
    wget https://www.unixodbc.org/unixODBC-2.3.12.tar.gz
    tar -xzf unixODBC-2.3.12.tar.gz
    cd unixODBC-2.3.12
    ./configure 
    make
fi
cd /home/PEN/WS/Programs/unixODBC-2.3.12
make install

cd /home/PEN/WS/Programs
if [ ! -d "/home/PEN/WS/Programs/otp_src_27.2.3" ]; then
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
if [ ! -d "/home/PEN/WS/Programs/emqx" ]; then
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

while true; do
    sleep 1000 
done
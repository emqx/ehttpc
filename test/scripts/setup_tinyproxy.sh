#!/usr/bin/env bash

set -exuo pipefail

VERSION=1.11.2
URL="https://github.com/tinyproxy/tinyproxy/releases/download/${VERSION}/tinyproxy-${VERSION}.tar.bz2"

cd /tmp
wget -O tinyproxy.tar.bz2 "${URL}"
tar -xf tinyproxy.tar.bz2
cd tinyproxy-*
./configure
make
make install

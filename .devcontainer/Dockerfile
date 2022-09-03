FROM mcr.microsoft.com/vscode/devcontainers/javascript-node:18-bullseye

# We need Lua 5.0.2, and it must be 32-bit.
RUN apt-get update && apt-get install -y gcc-multilib && rm -rf /var/lib/apt/lists/* \
    && (curl https://www.lua.org/ftp/lua-5.0.2.tar.gz | tar xz -C /tmp) \
    && cd /tmp/lua* \
    && sed -i -e 's$INSTALL_ROOT= /usr/local$INSTALL_ROOT= /usr$' -e 's$MYCFLAGS= -O2$MYCFLAGS= -O2 -m32$' -e 's$#MYLDFLAGS=$MYLDFLAGS= -m32$' config \
    && ./configure && make all install \
    && cd /tmp && rm -rf lua*
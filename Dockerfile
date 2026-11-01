FROM    alpine:3.20

# if omitted, the versions are determined from the git tags
ARG     tor_version
ARG     torsocks_version

ENV     HOME /var/lib/tor

RUN     apk add --no-cache git bind-tools cargo libevent-dev openssl-dev gnupg gcc make automake ca-certificates autoconf musl-dev coreutils zlib-dev && \
    mkdir -p /usr/local/src/ /var/lib/tor/ && \
    git clone https://gitlab.torproject.org/tpo/core/tor.git /usr/local/src/tor && \
    cd /usr/local/src/tor && \
    TOR_VERSION=${tor_version=$(git tag | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)} && \
    git checkout tor-$TOR_VERSION && \
    ./autogen.sh && \
    ./configure \
    --disable-asciidoc \
    --sysconfdir=/etc \
    --disable-unittests && \
    make && make install && \
    cd .. && \
    rm -rf tor && \
    apk del git libevent-dev openssl-dev gnupg cargo make automake autoconf musl-dev coreutils && \
    apk add --no-cache libevent openssl zlib bash su-exec

RUN    apk add --no-cache git gcc make automake autoconf musl-dev libtool && \
    git clone https://gitlab.torproject.org/tpo/core/torsocks.git /usr/local/src/torsocks && \
    cd /usr/local/src/torsocks && \
    TORSOCKS_VERSION=${torsocks_version=$(git tag | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)} && \
    git checkout $TORSOCKS_VERSION && \
    ./autogen.sh && \
    ./configure && \
    make && make install && \
    cd .. && \
    rm -rf torsocks && \
    apk del git gcc make automake autoconf musl-dev libtool

RUN     mkdir -p /etc/tor/

COPY    bin/onions bin/docker-entrypoint /usr/local/bin/

RUN     mkdir -p ${HOME}/.tor && \
    addgroup -S -g 107 tor && \
    adduser -S -G tor -u 104 -H -h ${HOME} tor

VOLUME  ["/var/lib/tor/hidden_service/"]

ENTRYPOINT ["docker-entrypoint"]

CMD     ["tor"]

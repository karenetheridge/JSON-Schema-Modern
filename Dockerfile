FROM alpine:latest

RUN apk update && apk upgrade && apk add --no-cache \
    build-base \
    curl \
    gcc \
    make \
    openssl \
    openssl-dev \
    tar \
    wget \
    zlib \
    zlib-dev \
    perl \
  && rm -rf /var/cache/apk/*

# this is https://metacpan.org/pod/App::cpanminus
RUN curl -L http://xrl.us/cpanm > /bin/cpanm \
  && chmod +x /bin/cpanm

WORKDIR /usr
RUN cpanm install JSON::Schema::Modern \
  && cpanm --reinstall --with-recommends --with-suggests JSON::Schema::Modern

CMD ["perl", "bowtie-json-schema-modern"]

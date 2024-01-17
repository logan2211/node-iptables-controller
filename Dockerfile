FROM debian:latest

ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

COPY --from=lachlanevenson/k8s-kubectl:latest /usr/local/bin/kubectl /usr/local/bin/kubectl

RUN apt-get update && \
    apt-get install -y coreutils iptables && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY iptables-sync.sh /app/

CMD ["/app/iptables-sync.sh"]

FROM alpine:latest

RUN apk add --no-cache bash curl jq && \
    mkdir -p /metrics && chown 65534:65534 /metrics

COPY scrape.sh /usr/local/bin/scrape.sh

USER 65534:65534
ENTRYPOINT ["/usr/local/bin/scrape.sh"]

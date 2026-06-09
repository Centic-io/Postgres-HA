FROM postgres:15-alpine

RUN apk add --no-cache \
    python3 \
    py3-pip \
    curl \
    bash \
  && pip3 install \
    patroni[etcd3] \
    psycopg2-binary \
    --break-system-packages

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Chạy entrypoint với root để fix permission, sau đó su sang postgres
ENTRYPOINT ["/entrypoint.sh"]
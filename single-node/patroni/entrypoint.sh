#!/bin/bash
mkdir -p "$PATRONI_DATA_DIR"
chown -R postgres:postgres "$PATRONI_DATA_DIR"
chmod 0750 "$PATRONI_DATA_DIR"
exec su-exec postgres patroni /etc/patroni/patroni.yml

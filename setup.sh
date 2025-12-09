#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo " EDGE VM BOOTSTRAP: Traefik + Authentik + Vaultwarden + Semaphore UI "
echo "=============================================="

# -----------------------------
# Helper functions
# -----------------------------
gen_secret() {
  openssl rand -hex 32
}

prompt() {
  read -rp "$1: " val
  echo "$val"
}

# -----------------------------
# Create directories
# -----------------------------
BASE_DIR=$(pwd)/nodes/edge-sec-cloud
mkdir -p $BASE_DIR/config
mkdir -p $BASE_DIR/data/{postgres,redis,authentik,vaultwarden,semaphore,acme}

# -----------------------------
# Collect user input
# -----------------------------
DOMAIN=$(prompt "Enter your domain (e.g., homelab.example.com)")
LETSENCRYPT_EMAIL=$(prompt "Enter your Let's Encrypt email")
SEMAPHORE_ADMIN_PASSWORD=$(prompt "Enter Semaphore UI admin password")

# -----------------------------
# Generate secrets
# -----------------------------
AUTHENTIK_SECRET_KEY=$(gen_secret)
AUTHENTIK_DB_PASS=$(gen_secret)
AUTHENTIK_OUTPOST_TOKEN=$(gen_secret)
VAULTWARDEN_ADMIN_TOKEN=$(gen_secret)

# -----------------------------
# Write .env
# -----------------------------
cat > $BASE_DIR/.env <<EOF
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}

AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY}
AUTHENTIK_DB_PASS=${AUTHENTIK_DB_PASS}
AUTHENTIK_OUTPOST_TOKEN=${AUTHENTIK_OUTPOST_TOKEN}

VAULTWARDEN_ADMIN_TOKEN=${VAULTWARDEN_ADMIN_TOKEN}
SEMAPHORE_ADMIN_PASSWORD=${SEMAPHORE_ADMIN_PASSWORD}
EOF

echo "[+] .env file created"

# -----------------------------
# Traefik static config
# -----------------------------
cat > $BASE_DIR/config/traefik.yml <<EOF
log:
  level: INFO
  format: common

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    filename: "/etc/traefik/dynamic.yml"
    watch: true

certificatesResolvers:
  le:
    acme:
      email: "\${LETSENCRYPT_EMAIL}"
      storage: "/acme/acme.json"
      tlsChallenge: true
EOF

echo "[+] Traefik static config created"

# -----------------------------
# Traefik dynamic config
# -----------------------------
cat > $BASE_DIR/config/dynamic.yml <<EOF
http:
  middlewares:
    authentik-forwardauth:
      forwardAuth:
        address: "http://ak-outpost:9000/outpost.goauthentik.io/auth/traefik"
        trustForwardHeader: true
        authResponseHeaders:
          - "Set-Cookie"
          - "Authentication-Info"

  routers:
    traefik-dashboard:
      rule: "Host(\`traefik.\${DOMAIN}\`)"
      service: api@internal
      entryPoints:
        - websecure
      tls: true
      middlewares:
        - authentik-forwardauth
EOF

echo "[+] Traefik dynamic config created"

# -----------------------------
# Docker Compose file
# -----------------------------
cat > $BASE_DIR/docker-compose.yml <<'EOF'
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    command:
      - --log.level=INFO
      - --api.dashboard=true
      - --providers.file.filename=/etc/traefik/dynamic.yml
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.tlschallenge=true
      - --certificatesresolvers.le.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./config/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./config/dynamic.yml:/etc/traefik/dynamic.yml:ro
      - ./data/acme:/acme
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - web

  postgres:
    image: postgres:15-alpine
    container_name: authentik-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: authentik
      POSTGRES_USER: authentik
      POSTGRES_PASSWORD: ${AUTHENTIK_DB_PASS}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - web

  redis:
    image: redis:7-alpine
    container_name: authentik-redis
    restart: unless-stopped
    volumes:
      - ./data/redis:/data
    networks:
      - web

  authentik:
    image: ghcr.io/goauthentik/server:latest
    container_name: authentik
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
    environment:
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
      DATABASE_URL: postgresql://authentik:${AUTHENTIK_DB_PASS}@postgres:5432/authentik
      REDIS_URL: redis://redis:6379/0
      SERVER_HOSTNAME: auth.${DOMAIN}
    volumes:
      - ./data/authentik:/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.auth.rule=Host(`auth.${DOMAIN}`)"
      - "traefik.http.routers.auth.entrypoints=websecure"
      - "traefik.http.routers.auth.tls=true"
      - "traefik.http.routers.auth.tls.certresolver=le"
    networks:
      - web

  ak-outpost:
    image: ghcr.io/goauthentik/proxy:latest
    container_name: ak-outpost
    restart: unless-stopped
    environment:
      AUTHENTIK_HOST: http://auth.${DOMAIN}
      AUTHENTIK_TOKEN: ${AUTHENTIK_OUTPOST_TOKEN}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ak-outpost.rule=Host(`outpost.${DOMAIN}`)"
      - "traefik.http.routers.ak-outpost.entrypoints=websecure"
      - "traefik.http.routers.ak-outpost.tls=true"
      - "traefik.http.routers.ak-outpost.tls.certresolver=le"
    networks:
      - web

  vaultwarden:
    image: vaultwarden/server:1.29.0
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - ./data/vaultwarden:/data
    environment:
      - ADMIN_TOKEN=${VAULTWARDEN_ADMIN_TOKEN}
      - WEBSOCKET_ENABLED=true
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.vaultwarden.rule=Host(`vault.${DOMAIN}`)"
      - "traefik.http.routers.vaultwarden.entrypoints=websecure"
      - "traefik.http.routers.vaultwarden.tls=true"
      - "traefik.http.routers.vaultwarden.tls.certresolver=le"
      - "traefik.http.routers.vaultwarden.middlewares=authentik-forwardauth@file"
    networks:
      - web

  semaphore:
    image: semaphoreui/semaphore:latest
    container_name: semaphore
    restart: unless-stopped
    volumes:
      - ./data/semaphore:/etc/semaphore
    environment:
      SEMAPHORE_DB_DIALECT: bolt
      SEMAPHORE_ADMIN: admin
      SEMAPHORE_ADMIN_NAME: Admin
      SEMAPHORE_ADMIN_EMAIL: admin@${DOMAIN}
      SEMAPHORE_ADMIN_PASSWORD: ${SEMAPHORE_ADMIN_PASSWORD}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.semaphore.rule=Host(`semaphore.${DOMAIN}`)"
      - "traefik.http.routers.semaphore.entrypoints=websecure"
      - "traefik.http.routers.semaphore.tls=true"
      - "traefik.http.routers.semaphore.tls.certresolver=le"
      - "traefik.http.routers.semaphore.middlewares=authentik-forwardauth@file"
    networks:
      - web

networks:
  web:
    external: false
EOF

echo "[+] docker-compose.yml created"

# -----------------------------
# Fix permissions for Semaphore to prevent restart loop
# -----------------------------
chmod -R 700 $BASE_DIR/data/semaphore
chown -R 1000:1000 $BASE_DIR/data/semaphore
echo "[+] Semaphore volume permissions set"

echo ""
echo "=============================================="
echo "[+] Bootstrap complete!"
echo "[+] Next steps:"
echo "    1. cd $BASE_DIR"
echo "    2. docker compose pull"
echo "    3. docker compose up -d"
echo "    4. Visit https://auth.${DOMAIN} to finish Authentik setup"
echo "    5. Visit https://semaphore.${DOMAIN} — protected by Authentik SSO"
echo "    6. Visit https://vault.${DOMAIN} to access Vaultwarden"
echo "=============================================="

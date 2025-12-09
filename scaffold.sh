#!/usr/bin/env bash
# scaffold.sh — Interactive scaffold for your 6-node homelab + cloud stack
# Creates folder structure, sample docker-compose files & config, and stagger-downloads images.
# Usage: chmod +x scaffold.sh && ./scaffold.sh

set -euo pipefail
IFS=$'\n\t'

# ---------------
# Defaults/customization (edit or answer prompts)
# ---------------
DEFAULT_DOMAIN="example.com"
DEFAULT_LOKI_TS_IP="100.64.0.10:3100"   # Observability node Tailscale IP:Port
DEFAULT_TAILSCALE_AUTH_KEY=""           # leave empty -> fill later
PULL_DELAY_SECONDS=6                    # seconds between docker pulls (stagger)
PULL_RETRIES=2

# ---------------
# Helpers
# ---------------
info(){ printf "\e[1;34m[INFO]\e[0m %s\n" "$*"; }
warn(){ printf "\e[1;33m[WARN]\e[0m %s\n" "$*"; }
err(){ printf "\e[1;31m[ERR]\e[0m %s\n" "$*"; exit 1; }

ask_default(){
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "$prompt [$default] > " var
  if [[ -z "$var" ]]; then echo "$default"; else echo "$var"; fi
}

# ---------------
# Gather minimal inputs
# ---------------
info "Interactive scaffold for your 6-node stack. You can press ENTER to accept defaults."
DOMAIN=$(ask_default "Primary root domain for Traefik/Authentik (e.g. homelab.$DEFAULT_DOMAIN)" "homelab.$DEFAULT_DOMAIN")
LOKI_TS_IP=$(ask_default "Observability node Tailscale IP and Loki port (ip:port)" "$DEFAULT_LOKI_TS_IP")
read -r -p "Set pull delay in seconds between docker image downloads (default ${PULL_DELAY_SECONDS}s): " input_delay
if [[ -n "$input_delay" ]]; then PULL_DELAY_SECONDS="$input_delay"; fi

# ---------------
# Directory layout
# ---------------
ROOT_DIR="$(pwd)/homelab-scaffold"
info "Creating scaffold in $ROOT_DIR"
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

NODES=(edge-sec-cloud automation-devops personal-apps media-core observability backup-core)

for n in "${NODES[@]}"; do
  mkdir -p "nodes/$n/config"
  mkdir -p "nodes/$n/data"
done

mkdir -p tooling/semaphore
mkdir -p tooling/docs

# ---------------
# Small helper to write .env.example files
# ---------------
write_env_example(){
  local node="$1"
  cat > "nodes/$node/.env.example" <<EOF
# .env.example for $node
# Copy to .env and fill secrets / adjust as required.

COMPOSE_PROJECT_NAME=${node}
DOMAIN=${DOMAIN}
TZ=Europe/London

# Database creds (if used)
DB_USER=changeme
DB_PASS=changeme

# Tailscale (paste your key here)
TAILSCALE_AUTHKEY=${DEFAULT_TAILSCALE_AUTH_KEY}

# Loki target for Promtail on this node (observability node Tailscale IP)
LOKI_TARGET=${LOKI_TS_IP}

# Traefik labels / cert resolver placeholder
TRAEFIK_CERT_RESOLVER=le
EOF
}

# ---------------
# Write minimal docker-compose files per node
# Each compose is intentionally compact — you'll expand them.
# ---------------
write_compose_edge(){
cat > nodes/edge-sec-cloud/docker-compose.yml <<'YML'
version: "3.8"
services:
  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: unless-stopped
    networks: ["web"]
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./config/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./config/acme:/acme
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"

  authentik:
    image: authentik/authentik
    container_name: authentik
    restart: unless-stopped
    volumes:
      - ./data:/data
    environment:
      - DATABASE_URL=postgresql://authentik:changeme@postgres/authentik
    depends_on: []
    labels:
      - "traefik.enable=true"

  tailscale:
    image: tailscale/tailscale
    container_name: tailscale
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    volumes:
      - ./config/tailscale:/var/lib/tailscale
    environment:
      - TS_AUTHKEY=${TAILSCALE_AUTHKEY:-}
    command: tailscaled
YML
}

write_compose_automation(){
cat > nodes/automation-devops/docker-compose.yml <<'YML'
version: "3.8"
services:
  forgejo:
    image: forgejo/gitea:1.19
    container_name: forgejo
    restart: unless-stopped
    volumes:
      - ./data:/data
    environment:
      - USER_UID=1000
      - USER_GID=1000
    labels:
      - "traefik.enable=true"

  semaphore:
    image: semaphoreci/semaphore:latest
    container_name: semaphore
    restart: unless-stopped
    volumes:
      - ./data:/var/lib/semaphore
    labels:
      - "traefik.enable=true"

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    labels:
      - "traefik.enable=true"

  promtail:
    image: grafana/promtail:2.9.1
    container_name: promtail
    restart: unless-stopped
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./config/promtail.yaml:/etc/promtail/promtail.yaml:ro
YML
}

write_compose_personal(){
cat > nodes/personal-apps/docker-compose.yml <<'YML'
version: "3.8"
services:
  vaultwarden:
    image: vaultwarden/server:1.29.0
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - ./data:/data
    environment:
      - ADMIN_TOKEN=changeme
    labels:
      - "traefik.enable=true"

  homeassistant:
    image: homeassistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    volumes:
      - ./config:/config
    labels:
      - "traefik.enable=false"

  tandoor:
    image: akshaynagpal/tandoor-recipes:latest
    container_name: tandoor
    restart: unless-stopped
    volumes:
      - ./data:/data
    labels:
      - "traefik.enable=true"

  promtail:
    image: grafana/promtail:2.9.1
    container_name: promtail_personal
    restart: unless-stopped
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./config/promtail.yaml:/etc/promtail/promtail.yaml:ro
YML
}

write_compose_media(){
cat > nodes/media-core/docker-compose.yml <<'YML'
version: "3.8"
services:
  plex:
    image: linuxserver/plex:latest
    container_name: plex
    restart: unless-stopped
    volumes:
      - ./config:/config
      - ./media:/media
    labels:
      - "traefik.enable=false"

  sonarr:
    image: linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    volumes:
      - ./config:/config
      - ./tv:/tv
    labels:
      - "traefik.enable=true"

  radarr:
    image: linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    volumes:
      - ./config:/config
      - ./movies:/movies
    labels:
      - "traefik.enable=true"

  prowlarr:
    image: prowlarr/prowlarr:develop
    container_name: prowlarr
    restart: unless-stopped
    volumes:
      - ./config:/config
    labels:
      - "traefik.enable=true"

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    labels:
      - "traefik.enable=false"

  promtail:
    image: grafana/promtail:2.9.1
    container_name: promtail_media
    restart: unless-stopped
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./config/promtail.yaml:/etc/promtail/promtail.yaml:ro
YML
}

write_compose_observability(){
cat > nodes/observability/docker-compose.yml <<'YML'
version: "3.8"
services:
  loki:
    image: grafana/loki:2.9.1
    container_name: loki
    restart: unless-stopped
    volumes:
      - ./data:/loki
      - ./config:/etc/loki
    ports:
      - "3100:3100"

  grafana:
    image: grafana/grafana:9.0
    container_name: grafana
    restart: unless-stopped
    volumes:
      - ./data:/var/lib/grafana
    ports:
      - "3000:3000"

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "9090:9090"

  promtail:
    image: grafana/promtail:2.9.1
    container_name: promtail_observability
    restart: unless-stopped
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./config/promtail.yaml:/etc/promtail/promtail.yaml:ro
YML
}

write_compose_backup(){
cat > nodes/backup-core/docker-compose.yml <<'YML'
version: "3.8"
services:
  minio:
    image: minio/minio:RELEASE.2024-03-15T00-00-00Z
    container_name: minio
    environment:
      - MINIO_ROOT_USER=minio
      - MINIO_ROOT_PASSWORD=minio123
    command: server /data
    volumes:
      - ./data:/data
    ports:
      - "9000:9000"

  restic-srv:
    image: alpine:3.18
    container_name: restic_svc
    command: ["sh", "-c", "sleep infinity"]
    volumes:
      - ./repo:/repo
YML
}

# Write node docker-compose files
write_env_example edge-sec-cloud
write_env_example automation-devops
write_env_example personal-apps
write_env_example media-core
write_env_example observability
write_env_example backup-core

write_compose_edge
write_compose_automation
write_compose_personal
write_compose_media
write_compose_observability
write_compose_backup

# ---------------
# Promtail example config (per-node)
# ---------------
promtail_config_common(){
  local node="$1"
  cat > "nodes/$node/config/promtail.yaml" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions_${node}.yaml

clients:
  - url: http://${LOKI_TS_IP}/loki/api/v1/push

scrape_configs:
  - job_name: docker
    pipeline_stages:
      - docker: {}
    static_configs:
      - targets: ["localhost"]
        labels:
          job: docker
          node: "${node}"
          __path__: /var/lib/docker/containers/*/*.log
YAML
}

for n in "${NODES[@]}"; do
  promtail_config_common "$n"
done

# ---------------
# Prometheus config (observability)
# ---------------
cat > nodes/observability/config/prometheus.yml <<'YML'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
# Add node exporters & service exporters below
YML

# ---------------
# Loki basic config directory (observability)
# ---------------
mkdir -p nodes/observability/config
cat > nodes/observability/config/loki-config.yml <<'YML'
auth_enabled: false
server:
  http_listen_port: 3100
storage_config:
  boltdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/cache
    shared_store: filesystem
  filesystem:
    directory: /loki/chunks
schema_config:
  configs:
    - from: 2023-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v12
      index:
        prefix: index_
YML

# ---------------
# semaphore pipeline (example)
# ---------------
cat > tooling/semaphore/semaphore-pipeline.yml <<'YML'
# Example Semaphore pipeline - adapt runner/targets to your environment
version: v1
name: "Homelab deploy - docker compose up (example)"
agent:
  machine:
    type: e1-standard-2
blocks:
  - name: "Deploy all nodes"
    tasks:
      - name: "Deploy nodes via docker compose"
        commands:
          - echo "This job expects access (ssh/runner) to the deployment host(s)."
          - |
            for node in edge-sec-cloud automation-devops personal-apps media-core observability backup-core; do
              echo "Deploying $node ..."
              # Adjust: replace /srv/homelab with your deployment path on the target runner
              docker compose -f /srv/homelab/nodes/$node/docker-compose.yml up -d
            done
YML

# ---------------
# Collect images from all docker-compose files and stagger-pull them
# ---------------
info "Collecting images from generated docker-compose files..."
images=()
while IFS= read -r line; do
  # trim
  line="$(echo "$line" | tr -d '[:space:]')"
  if [[ "$line" == image:* ]]; then
    img="${line#image:}"
    # strip quotes
    img="${img%\"}"
    img="${img#\"}"
    images+=("$img")
  fi
done < <(grep -R --line-number "image:" -h nodes/*/docker-compose.yml || true)

# dedupe keeping order
declare -A seen
uniq_images=()
for i in "${images[@]}"; do
  if [[ -n "$i" ]] && [[ -z "${seen[$i]:-}" ]]; then
    uniq_images+=("$i")
    seen[$i]=1
  fi
done

info "Found ${#uniq_images[@]} unique images to pre-pull."
if [[ "${#uniq_images[@]}" -eq 0 ]]; then warn "No images found; check generated compose files."; fi

read -r -p "Proceed to pull these images now with ${PULL_DELAY_SECONDS}s stagger? [Y/n] " resp
resp="${resp:-Y}"
if [[ "$resp" =~ ^([yY]|)$ ]]; then
  for img in "${uniq_images[@]}"; do
    attempt=0
    pulled=false
    while [[ $attempt -lt $PULL_RETRIES ]]; do
      attempt=$((attempt+1))
      info "Pulling image: $img (attempt $attempt)..."
      if docker pull "$img"; then
        pulled=true
        break
      else
        warn "Pull failed for $img (attempt $attempt). Retrying in 3s..."
        sleep 3
      fi
    done
    if [[ "$pulled" != true ]]; then warn "Failed to pull $img after ${PULL_RETRIES} retries — continue to next image."; fi
    info "Sleeping $PULL_DELAY_SECONDS seconds before next pull..."
    sleep "$PULL_DELAY_SECONDS"
  done
else
  info "Skipping image pulls (you can pre-pull later with ./scaffold.sh --pull or with Semaphore)."
fi

# ---------------
# Final README and next steps
# ---------------
cat > README.md <<'TXT'
Homelab Scaffold
================

This repo was generated by scaffold.sh and contains a basic layout for your 6-node homelab + cloud stack.

IMPORTANT:
 - Fill in secrets: copy each nodes/<node>/.env.example -> nodes/<node>/.env and set TAILSCALE_AUTHKEY, DB passwords, etc.
 - Tailscale: install tailscale on hosts and connect them into same machine account or use auth keys.
 - Traefik/Authentik: the edge is intended for cloud; configure DNS to your cloud VM.
 - Promtail: edit nodes/*/config/promtail.yaml to set exact Loki Tailscale IP if different.
 - Semaphore: adapt tooling/semaphore/semaphore-pipeline.yml to your Semaphore runner.

To deploy (example local deployment):
  cd nodes/edge-sec-cloud && docker compose up -d
  cd ../automation-devops && docker compose up -d
  ...
Or use Semaphore to run the included pipeline.

If you want me to:
 - expand any docker-compose with more env var details,
 - create production-ready Traefik & Authentik configurations,
 - generate Terraform/Ansible playbooks to provision VMs & DNS,
 - create Prometheus exporters & Grafana dashboards

tell me which and I'll produce them next.
TXT

info "Scaffold complete. Files created under: $ROOT_DIR"
info "Next steps:"
echo "  1) Edit each nodes/*/.env.example -> .env and fill secrets."
echo "  2) Put Tailscale auth key and start tailscaled on each host (or use tailscale up with your auth key)."
echo "  3) Adapt tooling/semaphore/semaphore-pipeline.yml to your environment (runner path to /srv/homelab)."
echo "  4) Use Semaphore to run the pipeline OR run 'docker compose up -d' in each nodes/<node> folder."

exit 0

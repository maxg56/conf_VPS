#!/usr/bin/env bash
#
# setup.sh — Configuration de base d'un VPS Arch Linux
#   1. Sécurisation (SSH, firewall, fail2ban, utilisateur sudo)
#   2. Installation de Docker & Docker Compose
#   3. Installation de Dokploy (PaaS)
#   4. Reverse proxy Nginx (HTTP + /dev → Dokploy)
#   5. Lancement de tous les docker-compose dans ./docker/
#
# Usage : curl … | bash        (ou)  bash setup.sh
# Doit être exécuté en root.

set -euo pipefail

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; }

# ─── Vérifications ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Ce script doit être exécuté en root."
    exit 1
fi

# ─── Configuration (modifiable) ─────────────────────────────────────────────
NEW_USER="${NEW_USER:-admin}"
SSH_PORT="${SSH_PORT:-2222}"
DOCKER_DIR="${DOCKER_DIR:-$(cd "$(dirname "$0")" && pwd)/docker}"

# ═══════════════════════════════════════════════════════════════════════════════
#  1.  MISE À JOUR DU SYSTÈME
# ═══════════════════════════════════════════════════════════════════════════════
log "Mise à jour complète du système…"
pacman -Syu --noconfirm

# ═══════════════════════════════════════════════════════════════════════════════
#  2.  CRÉATION D'UN UTILISATEUR SUDO
# ═══════════════════════════════════════════════════════════════════════════════
if ! id "$NEW_USER" &>/dev/null; then
    log "Création de l'utilisateur '$NEW_USER'…"
    useradd -m -G wheel -s /bin/bash "$NEW_USER"
    warn "Pensez à définir un mot de passe : passwd $NEW_USER"
else
    log "L'utilisateur '$NEW_USER' existe déjà."
    usermod -aG wheel "$NEW_USER"
fi

# Autoriser le groupe wheel à utiliser sudo
if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
    log "Activation de sudo pour le groupe wheel…"
    echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  3.  SÉCURISATION SSH
# ═══════════════════════════════════════════════════════════════════════════════
log "Sécurisation de la configuration SSH…"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

apply_sshd_option() {
    local key="$1" value="$2"
    if grep -qE "^#?${key}\b" "$SSHD_CONFIG"; then
        sed -i "s|^#*${key}.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

apply_sshd_option "Port"                  "$SSH_PORT"
apply_sshd_option "PermitRootLogin"       "no"
apply_sshd_option "PasswordAuthentication" "no"
apply_sshd_option "PubkeyAuthentication"  "yes"
apply_sshd_option "X11Forwarding"         "no"
apply_sshd_option "MaxAuthTries"          "3"
apply_sshd_option "ClientAliveInterval"   "300"
apply_sshd_option "ClientAliveCountMax"   "2"

# Copier les clés SSH existantes vers le nouvel utilisateur
if [[ -d /root/.ssh ]]; then
    USER_HOME=$(eval echo "~$NEW_USER")
    mkdir -p "$USER_HOME/.ssh"
    cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys" 2>/dev/null || true
    chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys" 2>/dev/null || true
fi

systemctl restart sshd

# ═══════════════════════════════════════════════════════════════════════════════
#  4.  FIREWALL (nftables)
# ═══════════════════════════════════════════════════════════════════════════════
log "Configuration du firewall nftables…"
pacman -S --noconfirm --needed nftables

cat > /etc/nftables.conf << EOF
#!/usr/bin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback
        iif "lo" accept

        # Connexions établies
        ct state established,related accept

        # ICMP (ping)
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # SSH
        tcp dport $SSH_PORT ct state new accept

        # HTTP / HTTPS
        tcp dport { 80, 443 } ct state new accept

        # Log + drop le reste
        log prefix "[nftables drop] " drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        # Docker gère ses propres règles forward
        ct state established,related accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

systemctl enable --now nftables

# ═══════════════════════════════════════════════════════════════════════════════
#  5.  FAIL2BAN
# ═══════════════════════════════════════════════════════════════════════════════
log "Installation et configuration de fail2ban…"
pacman -S --noconfirm --needed fail2ban

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = $SSH_PORT
EOF

systemctl enable --now fail2ban

# ═══════════════════════════════════════════════════════════════════════════════
#  6.  DURCISSEMENT DIVERS
# ═══════════════════════════════════════════════════════════════════════════════
log "Durcissement sysctl…"

cat > /etc/sysctl.d/99-security.conf << 'EOF'
# Désactiver le routage IP
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Protection SYN flood
net.ipv4.tcp_syncookies = 1

# Ignorer les redirections ICMP
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Ignorer les paquets source-routed
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log des paquets martiens
net.ipv4.conf.all.log_martians = 1

# Protection contre le spoofing
net.ipv4.conf.all.rp_filter = 1
EOF

sysctl --system > /dev/null

# ═══════════════════════════════════════════════════════════════════════════════
#  7.  INSTALLATION DE DOCKER
# ═══════════════════════════════════════════════════════════════════════════════
log "Installation de Docker…"
pacman -S --noconfirm --needed docker docker-compose nginx

# Ajouter l'utilisateur au groupe docker
usermod -aG docker "$NEW_USER"

# Activer ip_forward pour Docker (écrase la valeur sysctl précédente)
cat > /etc/sysctl.d/99-docker.conf << 'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system > /dev/null

systemctl enable --now docker

log "Attente du démarrage de Docker…"
until docker info &>/dev/null; do
    sleep 1
done

# ═══════════════════════════════════════════════════════════════════════════════
#  8.  INSTALLATION DE DOKPLOY
# ═══════════════════════════════════════════════════════════════════════════════
log "Installation de Dokploy…"

if docker ps --format '{{.Names}}' | grep -q dokploy; then
    log "Dokploy est déjà en cours d'exécution."
else
    docker swarm init || true

    docker network create --driver overlay --attachable dokploy-network 2>/dev/null || true

    mkdir -p /etc/dokploy

    docker service create \
        --name dokploy \
        --replicas 1 \
        --network dokploy-network \
        --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
        --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
        --publish published=3000,target=3000 \
        --update-parallelism 1 \
        --update-order stop-first \
        --constraint 'node.role == manager' \
        dokploy/dokploy:latest

    log "Attente du démarrage de Dokploy…"
    for i in $(seq 1 30); do
        if curl -sf http://localhost:3000 > /dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    log "Dokploy est accessible sur le port 3000."
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  9.  REVERSE PROXY NGINX
# ═══════════════════════════════════════════════════════════════════════════════
log "Configuration du reverse proxy Nginx…"

cat > /etc/nginx/nginx.conf << 'NGINXEOF'
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;

    # Sécurité headers
    add_header X-Frame-Options       "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection      "1; mode=block" always;

    # Taille max upload (utile pour Dokploy)
    client_max_body_size 100m;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;

        # /dev → Dokploy dashboard (port 3000)
        location /dev/ {
            proxy_pass         http://127.0.0.1:3000/;
            proxy_http_version 1.1;
            proxy_set_header   Upgrade $http_upgrade;
            proxy_set_header   Connection "upgrade";
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }

        # Racine par défaut — page d'accueil ou 404
        location / {
            return 404 '{"status":"not found"}\n';
            add_header Content-Type application/json;
        }
    }
}
NGINXEOF

# Vérifier la config avant de démarrer
nginx -t

systemctl enable --now nginx
log "Nginx actif : /dev → Dokploy."

# ═══════════════════════════════════════════════════════════════════════════════
#  10.  LANCEMENT DES DOCKER-COMPOSE
# ═══════════════════════════════════════════════════════════════════════════════
launch_compose() {
    local dir="$1"
    local name
    name=$(basename "$dir")

    log "Lancement du stack '$name'…"
    if docker compose -f "$dir/docker-compose.yml" up -d; then
        log "Stack '$name' démarré avec succès."
    else
        err "Échec du démarrage du stack '$name'."
    fi
}

if [[ -d "$DOCKER_DIR" ]]; then
    log "Recherche des docker-compose dans $DOCKER_DIR…"

    found=0

    # Fichier docker-compose.yml directement dans le dossier docker/
    if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
        launch_compose "$DOCKER_DIR"
        found=1
    fi

    # Sous-dossiers contenant un docker-compose.yml
    for dir in "$DOCKER_DIR"/*/; do
        [[ -f "$dir/docker-compose.yml" ]] || continue
        launch_compose "$dir"
        found=1
    done

    if [[ $found -eq 0 ]]; then
        warn "Aucun fichier docker-compose.yml trouvé dans $DOCKER_DIR."
    fi
else
    warn "Le dossier $DOCKER_DIR n'existe pas. Créez-le et ajoutez vos docker-compose.yml."
    mkdir -p "$DOCKER_DIR"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════════════════
cat << EOF

${GREEN}═══════════════════════════════════════════════════${NC}
  Configuration terminée !
${GREEN}═══════════════════════════════════════════════════${NC}

  Utilisateur sudo  : $NEW_USER
  Port SSH          : $SSH_PORT
  Firewall          : nftables (actif)
  Fail2ban          : actif
  Docker            : actif
  Dokploy           : http://<ip>:3000 (direct)
  Reverse proxy     : http://<ip>/dev → Dokploy
  Stacks docker     : $DOCKER_DIR

  ${YELLOW}Actions requises :${NC}
  1. Définir un mot de passe : passwd $NEW_USER
  2. Ajouter votre clé SSH dans ~${NEW_USER}/.ssh/authorized_keys
  3. Tester la connexion SSH AVANT de fermer cette session :
     ssh -p $SSH_PORT $NEW_USER@<ip-du-serveur>
  4. Accéder à Dokploy : http://<ip>/dev
  5. Placer vos docker-compose.yml dans $DOCKER_DIR/<nom>/

EOF

# conf_VPS

Script d'installation et de sécurisation automatique d'un VPS **Arch Linux**. En une seule exécution, le serveur est durci, conteneurisé et prêt à héberger des applications via [Dokploy](https://dokploy.com/).

## Fonctionnalités

- **Utilisateur sudo** : création d'un compte non-root avec accès `wheel`
- **SSH durci** : port personnalisé, authentification par clé uniquement, login root désactivé
- **Firewall nftables** : politique DROP par défaut, seuls SSH / HTTP / HTTPS ouverts
- **Fail2ban** : bannissement automatique après tentatives de connexion échouées
- **Durcissement kernel** : protections sysctl (SYN flood, spoofing, redirections ICMP…)
- **Docker & Docker Compose** : installés et configurés
- **Dokploy** : PaaS déployé via Docker Swarm, accessible sur `/dev`
- **Caddy** : reverse proxy avec HTTPS automatique (Let's Encrypt)
- **Stacks Docker** : lancement automatique des `docker-compose.yml` trouvés dans `./docker/`

## Prérequis

- Un VPS sous **Arch Linux**
- Accès **root** (ou via `sudo`)
- Une clé SSH déjà configurée dans `~root/.ssh/authorized_keys`
- Un nom de domaine pointant vers l'IP du serveur (pour le HTTPS automatique)

## Installation

```bash
git clone https://github.com/maxg56/conf_VPS.git
cd conf_VPS
bash setup.sh
```

### Variables d'environnement

Le script est configurable via des variables d'environnement :

| Variable     | Défaut         | Description                          |
|--------------|----------------|--------------------------------------|
| `NEW_USER`   | `admin`        | Nom de l'utilisateur sudo à créer    |
| `SSH_PORT`   | `2222`         | Port SSH personnalisé                |
| `DOMAIN`     | `mgendrot.pro` | Domaine pour Caddy (HTTPS)           |
| `DOCKER_DIR` | `./docker`     | Répertoire des stacks Docker Compose |

Exemple :

```bash
NEW_USER=deploy SSH_PORT=2200 DOMAIN=example.com bash setup.sh
```

## Étapes du script

| #  | Étape                        | Description                                                   |
|----|------------------------------|---------------------------------------------------------------|
| 1  | Mise à jour système          | `pacman -Syu`                                                 |
| 2  | Utilisateur sudo             | Création du compte, ajout au groupe `wheel`                   |
| 3  | Sécurisation SSH             | Port custom, clé uniquement, root désactivé, copie des clés   |
| 4  | Firewall nftables            | Politique DROP, ouverture SSH/HTTP/HTTPS                      |
| 5  | Fail2ban                     | Ban 1h après 5 échecs en 10 min                               |
| 6  | Durcissement sysctl          | SYN cookies, anti-spoofing, pas de redirections ICMP          |
| 7  | Docker                       | Installation Docker + Compose + Caddy, IP forwarding activé   |
| 8  | Dokploy                      | Swarm init, réseau overlay, service Dokploy sur le port 3000  |
| 9  | Reverse proxy Caddy          | HTTPS auto, `/dev/*` → Dokploy, headers de sécurité           |
| 10 | Stacks Docker Compose        | Lancement auto des `docker-compose.yml` dans `./docker/`      |

## Architecture

```
Internet (80/443)
       │
       ▼
   Caddy (HTTPS / Let's Encrypt)
       │
       ├── /dev/*  →  Dokploy (port 3000)
       └── /*      →  404
       │
       ▼
   Docker Swarm
       │
       ▼
   Stacks Docker Compose (./docker/)
```

## Actions post-installation

1. Définir un mot de passe pour l'utilisateur : `passwd admin`
2. Vérifier/ajouter votre clé SSH dans `~admin/.ssh/authorized_keys`
3. S'assurer que le DNS du domaine pointe vers l'IP du serveur
4. Tester la connexion SSH **avant de fermer la session** :
   ```bash
   ssh -p 2222 admin@votre-domaine.com
   ```
5. Accéder au dashboard Dokploy : `https://votre-domaine.com/dev`
6. Ajouter vos applications dans `./docker/<nom>/docker-compose.yml`

## Structure du projet

```
conf_VPS/
├── setup.sh          # Script principal d'installation
├── docker/           # Répertoire des stacks Docker Compose
│   └── .gitkeep
└── README.md
```

## Fichiers générés sur le serveur

| Fichier                          | Rôle                              |
|----------------------------------|-----------------------------------|
| `/etc/ssh/sshd_config`          | Configuration SSH durcie          |
| `/etc/nftables.conf`            | Règles firewall                   |
| `/etc/fail2ban/jail.local`      | Configuration fail2ban            |
| `/etc/sysctl.d/99-security.conf`| Durcissement kernel               |
| `/etc/sysctl.d/99-docker.conf`  | IP forwarding pour Docker         |
| `/etc/caddy/Caddyfile`          | Configuration reverse proxy       |
| `/etc/dokploy/`                 | Données Dokploy                   |

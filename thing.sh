
#!/usr/bin/env bash
set -Eeuo pipefail

# XRay VLESS + WebSocket + Nginx + Let's Encrypt
# Ubuntu 22.04 / 24.04 — installation sur serveur vierge uniquement.

LOG="/var/log/install-xray.log"
exec > >(tee -a "$LOG") 2>&1

trap 'echo "ERREUR : installation interrompue à la ligne $LINENO. Consulte $LOG."' ERR

echo "=========================================="
echo " Installation XRay VLESS + WebSocket"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    echo "Lance ce script en root : sudo bash install-xray.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "Distribution Linux non reconnue."
    exit 1
fi

source /etc/os-release

if [[ "$ID" != "ubuntu" || ! "$VERSION_ID" =~ ^(22\.04|24\.04)$ ]]; then
    echo "Ce script nécessite Ubuntu 22.04 ou 24.04."
    exit 1
fi

# Ne jamais écraser une installation existante.
if command -v nginx >/dev/null 2>&1 ||
   command -v xray >/dev/null 2>&1 ||
   systemctl list-unit-files 2>/dev/null | grep -qE '^(nginx|xray)\.service'; then
    echo "ERREUR : Nginx ou XRay semble déjà installé."
    echo "Pour protéger la configuration existante, arrêt du script."
    exit 1
fi

if [[ -e /usr/local/etc/xray/config.json ]]; then
    echo "ERREUR : une configuration XRay existe déjà."
    exit 1
fi

if ss -lnt 2>/dev/null | grep -Eq ':(80|443)[[:space:]]'; then
    echo "ERREUR : le port 80 ou 443 est déjà utilisé."
    exit 1
fi

read -rp "Nom de domaine (ex: vpn.example.com) : " DOMAIN
read -rp "Adresse e-mail pour Let's Encrypt : " EMAIL

DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
   [[ "$DOMAIN" != *.* ]]; then
    echo "Nom de domaine invalide."
    exit 1
fi

if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Adresse e-mail invalide."
    exit 1
fi

UUID="$(cat /proc/sys/kernel/random/uuid)"
WS_PATH="/$(openssl rand -hex 16)"

echo
echo "Domaine : $DOMAIN"
echo "UUID généré."
echo "Chemin WebSocket généré."
echo

export DEBIAN_FRONTEND=noninteractive

echo "[1/7] Installation des dépendances..."
apt-get update
apt-get install -y curl ca-certificates nginx certbot openssl

echo "[2/7] Installation de XRay depuis le dépôt officiel..."
TMP_INSTALL="$(mktemp)"
curl -fsSL \
  https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
  -o "$TMP_INSTALL"

bash "$TMP_INSTALL" install
rm -f "$TMP_INSTALL"

if [[ ! -x /usr/local/bin/xray ]]; then
    echo "Installation de XRay introuvable."
    exit 1
fi

echo "[3/7] Préparation de Nginx et du challenge HTTPS..."
mkdir -p /var/www/letsencrypt/.well-known/acme-challenge
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
mkdir -p /usr/local/etc/xray

cat > /etc/nginx/sites-available/xray.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
    }

    location / {
        return 404;
    }
}
EOF

ln -s /etc/nginx/sites-available/xray.conf \
      /etc/nginx/sites-enabled/xray.conf

nginx -t
systemctl enable --now nginx

echo "[4/7] Obtention du certificat Let's Encrypt..."
certbot certonly \
    --webroot \
    --webroot-path /var/www/letsencrypt \
    --domain "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [[ ! -s "$CERT" || ! -s "$KEY" ]]; then
    echo "Certificat HTTPS introuvable."
    exit 1
fi

echo "[5/7] Configuration XRay..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

chmod 644 /usr/local/etc/xray/config.json

/usr/local/bin/xray run -test \
    -config /usr/local/etc/xray/config.json

echo "[6/7] Configuration Nginx HTTPS + WebSocket..."
cat > /etc/nginx/sites-available/xray.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
    }

    location / {
        return 301 https://\\$host\\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \\$host;
        proxy_set_header X-Real-IP \\$remote_addr;
        proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;
    }

    location / {
        return 404;
    }
}
EOF

nginx -t
systemctl reload nginx

echo "[7/7] Démarrage et vérification de XRay..."
systemctl enable xray
systemctl restart xray
systemctl is-active --quiet xray
systemctl is-active --quiet nginx

# Renouvellement automatique : recharger Nginx après renouvellement.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# Fichier de connexion privé.
CLIENT_FILE="/root/vless-client.txt"
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${WS_PATH}#Ubuntu-XRay"

umask 077
cat > "$CLIENT_FILE" <<EOF
Domaine: $DOMAIN
Port: 443
Protocole: VLESS
UUID: $UUID
Transport: WebSocket
TLS: activé
SNI: $DOMAIN
Host: $DOMAIN
Path: $WS_PATH
Flow: aucun

Lien VLESS:
$VLESS_URI
EOF
chmod 600 "$CLIENT_FILE"

echo
echo "=========================================="
echo " INSTALLATION TERMINEE"
echo "=========================================="
echo "Domaine : $DOMAIN"
echo "Port : 443"
echo "XRay : $(systemctl is-active xray)"
echo "Nginx : $(systemctl is-active nginx)"
echo
echo "Paramètres client enregistrés dans :"
echo "$CLIENT_FILE"
echo
echo "Pour afficher le lien VLESS :"
echo "sudo cat $CLIENT_FILE"
echo
echo "IMPORTANT : configure Cloudflare en Full (strict)"
echo "et active le proxy orange après l'installation."
echo "=========================================="

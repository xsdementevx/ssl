#!/bin/bash
set -euo pipefail

DOMAIN="vpn.rf4bot.ru"
EMAIL="thx.dem@gmail.com"
BACKUP_DIR="/opt/vpn-traefik/backups"

### 1. Проверка root
if (( EUID != 0 )); then
  echo "❗ Запусти как root: sudo bash install_vpn.sh"
  exit 1
fi

### 2. Установка Docker
echo "📦 Проверка Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

### 3. Установка Docker Compose
if ! docker compose version &>/dev/null; then
  DOCKER_COMPOSE_VERSION="v2.23.3"
  curl -sSL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose || true
fi

### 4. Создание папки проекта и бэкапов
mkdir -p /opt/vpn-traefik
mkdir -p "${BACKUP_DIR}"
cd /opt/vpn-traefik

### 5. Скрипт бэкапа конфигов
cat > backup-script.sh <<'EOF'
#!/bin/bash
BACKUP_DIR="/opt/vpn-traefik/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
mkdir -p "${BACKUP_DIR}/${TIMESTAMP}"
cp -r /opt/vpn-traefik/*.yml "${BACKUP_DIR}/${TIMESTAMP}/"
cp -r /opt/vpn-traefik/acme.json "${BACKUP_DIR}/${TIMESTAMP}/"
echo "💾 Бэкап конфигов создан: ${BACKUP_DIR}/${TIMESTAMP}"
EOF
chmod +x backup-script.sh
./backup-script.sh

### 6. Docker Compose для Traefik + X-UI + Watchtower
cat > docker-compose.yml <<EOF
version: '3.9'

services:
  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"       # HTTP
      - "8443:443"    # HTTPS на 8443 вместо 443
    volumes:
      - ./traefik.yml:/traefik.yml:ro
      - ./acme.json:/acme.json
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - web

  xui:
    image: enwaiax/x-ui:latest
    container_name: x-ui
    restart: unless-stopped
    networks:
      - web
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.xui.rule=Host(\`${DOMAIN}\`)"
      - "traefik.http.routers.xui.entrypoints=websecure"
      - "traefik.http.routers.xui.tls.certresolver=letsencrypt"
      - "traefik.http.services.xui.loadbalancer.server.port=443"

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backup-script.sh:/backup-script.sh:ro
    command: --cleanup --interval 300 --label-enable --run-once

networks:
  web:
EOF

### 7. Конфиг Traefik
cat > traefik.yml <<EOF
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${EMAIL}
      storage: acme.json
      httpChallenge:
        entryPoint: web
EOF

### 8. Файл acme.json с правами
touch acme.json
chmod 600 acme.json

### 9. Запуск контейнеров
docker compose up -d

### 10. Ждём сертификат
echo "⌛ Ждём выпуск сертификата Let's Encrypt для ${DOMAIN}..."
until curl -skI "https://${DOMAIN}:8443" | grep -q "200\|301"; do
  echo "⌛ Ждём сертификат..."
  sleep 5
done

echo "🎉 Готово!"
echo "Панель 3X-UI доступна по адресу: https://${DOMAIN}:8443"
echo "Логин и пароль можно посмотреть командой: docker logs x-ui"
echo "🔄 Watchtower следит за обновлениями контейнеров каждые 5 минут"
echo "💾 Автоматические бэкапы конфигов сохраняются в ${BACKUP_DIR}"

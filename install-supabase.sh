#!/bin/bash
# Автоматический установщик Supabase (с поддержкой n8n)
# Исправлено: pg-meta → postgres-meta, совместимость с Docker Hub
# Модифицировано для ChatPilot / ИП Пальнов А.А.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

N8N_PROJECT_DIR="n8n-compose"
SUPABASE_PROJECT_DIR="supabase-full"
ORIGINAL_DIR="$(pwd)"

EXISTS_N8N=false
USE_EXISTING_N8N=false
ALREADY_INSTALLED=false

MAIN_DOMAIN=""
SUBDOMAIN=""
SSL_EMAIL=""
JWT_SECRET=""
ANON_KEY=""
SERVICE_KEY=""
POSTGRES_PASSWORD=""
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASS=""
SMTP_ADMIN_EMAIL=""
ENABLE_SMTP=false

print_header() { echo -e "${BLUE}================================${NC}\n${BLUE}$1${NC}\n${BLUE}================================${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

check_ubuntu_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $VERSION_ID in
            "20.04"|"22.04"|"24.04") ;;
            *) print_error "Поддерживается только Ubuntu 20.04/22.04/24.04 LTS"; exit 1 ;;
        esac
    else
        print_error "Не удалось определить ОС"; exit 1
    fi
}

install_docker() {
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        print_success "Docker и Docker Compose уже установлены"
        return
    fi

    print_info "Проверка блокировки apt..."
    retry_count=0
    max_retries=30
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $retry_count -ge $max_retries ]; then
            print_error "Не удалось получить доступ к apt за $max_retries секунд"
            print_error "Возможно, работает unattended-upgrades. Подождите и повторите."
            exit 1
        fi
        print_info "Система занята (apt). Ожидание... ($((retry_count + 1))/$max_retries)"
        sleep 2
        retry_count=$((retry_count + 1))
    done
    print_success "Блокировка apt снята"

    apt update
    apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    print_success "Docker установлен"
}

check_already_installed() {
    if [ -f "$N8N_PROJECT_DIR/.env" ] && grep -q "JWT_SECRET" "$N8N_PROJECT_DIR/.env"; then
        ALREADY_INSTALLED=true
        USE_EXISTING_N8N=true
        EXISTS_N8N=true
        source "$N8N_PROJECT_DIR/.env" 2>/dev/null || true
        print_success "Supabase уже интегрирован в n8n — повторная установка не требуется."
        return
    fi

    if [ -f "$SUPABASE_PROJECT_DIR/.env" ]; then
        if docker compose -f "$SUPABASE_PROJECT_DIR/docker-compose.yml" ps 2>/dev/null | grep -q "supabase-studio.*Up"; then
            ALREADY_INSTALLED=true
            source "$SUPABASE_PROJECT_DIR/.env" 2>/dev/null || true
            print_success "Supabase уже установлен отдельно — повторная установка пропущена."
            return
        fi
    fi
}

detect_n8n() {
    if [ -d "$N8N_PROJECT_DIR" ] && [ -f "$N8N_PROJECT_DIR/.env" ]; then
        source "$N8N_PROJECT_DIR/.env" 2>/dev/null || true
        if [ -n "$DOMAIN_NAME" ] && [ -n "$SSL_EMAIL" ]; then
            EXISTS_N8N=true
            MAIN_DOMAIN="$DOMAIN_NAME"
            SSL_EMAIL="$SSL_EMAIL"
            print_info "Обнаружен n8n: домен = $MAIN_DOMAIN"
        fi
    fi
}

setup_parameters() {
    local domain_regex='^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    local email_regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    if [ -z "$MAIN_DOMAIN" ]; then
        read -p "Основной домен (например: yourdomain.ru): " MAIN_DOMAIN
        if [ -z "$MAIN_DOMAIN" ]; then
            print_error "Домен не может быть пустым"
            exit 1
        fi
        if [[ ! $MAIN_DOMAIN =~ $domain_regex ]]; then
            print_error "Неверный формат домена"
            exit 1
        fi
    fi

    if [ -z "$SUBDOMAIN" ]; then
        read -p "Поддомен для Supabase (например: supa): " SUBDOMAIN
        if [ -z "$SUBDOMAIN" ]; then
            print_error "Поддомен обязателен"
            exit 1
        fi
    fi

    if [ -z "$SSL_EMAIL" ]; then
        read -p "Email для Let's Encrypt: " SSL_EMAIL
        if [ -z "$SSL_EMAIL" ]; then
            print_error "Email не может быть пустым"
            exit 1
        fi
        if [[ ! $SSL_EMAIL =~ $email_regex ]]; then
            print_error "Неверный формат email"
            exit 1
        fi
    fi
}

generate_secrets_if_needed() {
    if [ -z "$JWT_SECRET" ]; then JWT_SECRET=$(openssl rand -hex 32); fi
    if [ -z "$ANON_KEY" ]; then ANON_KEY=$(openssl rand -hex 32); fi
    if [ -z "$SERVICE_KEY" ]; then SERVICE_KEY=$(openssl rand -hex 32); fi
    if [ -z "$POSTGRES_PASSWORD" ]; then POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-24); fi
}

post_setup_questions() {
    if [ -z "$SMTP_HOST" ]; then
        read -p "Настроить SMTP для email-верификации? (y/N): " SMTP_OPT
        if [[ "$SMTP_OPT" =~ ^[Yy]$ ]]; then
            read -p "SMTP хост: " SMTP_HOST
            read -p "SMTP порт: " SMTP_PORT
            read -p "SMTP пользователь: " SMTP_USER
            read -s -p "SMTP пароль: " SMTP_PASS; echo
            read -p "Админ email: " SMTP_ADMIN_EMAIL
            ENABLE_SMTP=true
        fi
    else
        ENABLE_SMTP=true
        print_info "SMTP уже настроен — пропускаем настройку"
    fi

    BACKUP_DIR="/root/supabase-backups"
    mkdir -p "$BACKUP_DIR"
    if $USE_EXISTING_N8N && [ -f "$N8N_PROJECT_DIR/.env" ]; then
        cp "$N8N_PROJECT_DIR/.env" "$BACKUP_DIR/.env.n8n.$(date +%s)" 2>/dev/null || true
    elif [ -f "$SUPABASE_PROJECT_DIR/.env" ]; then
        cp "$SUPABASE_PROJECT_DIR/.env" "$BACKUP_DIR/.env.standalone.$(date +%s)" 2>/dev/null || true
    fi
}

generate_supabase_services() {
    cat << EOF
  supabase-db:
    image: supabase/postgres:15.1.1.67
    restart: always
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - supabase_db:/var/lib/postgresql/data
  supabase-auth:
    image: supabase/gotrue:v2.139.1
    restart: always
    environment:
      API_EXTERNAL_URL: https://auth.${SUBDOMAIN}.${MAIN_DOMAIN}
      JWT_SECRET: ${JWT_SECRET}
      DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres
      SITE_URL: https://${SUBDOMAIN}.${MAIN_DOMAIN}
      ADDITIONAL_REDIRECT_URLS: https://${SUBDOMAIN}.${MAIN_DOMAIN},http://localhost:3000
EOF
    if [[ "$ENABLE_SMTP" == "true" ]]; then
        cat << EOF
      GOTRUE_SMTP_HOST: ${SMTP_HOST}
      GOTRUE_SMTP_PORT: ${SMTP_PORT}
      GOTRUE_SMTP_USER: ${SMTP_USER}
      GOTRUE_SMTP_PASS: ${SMTP_PASS}
      GOTRUE_SMTP_ADMIN_EMAIL: ${SMTP_ADMIN_EMAIL}
      GOTRUE_MAILER_URLPATHS_INVITE: /
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: /
      GOTRUE_MAILER_URLPATHS_RECOVERY: /
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: /
EOF
    fi
    cat << EOF
    depends_on: [supabase-db]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.auth.rule=Host(\`auth.${SUBDOMAIN}.${MAIN_DOMAIN}\`)"
      - "traefik.http.routers.auth.entrypoints=websecure"
      - "traefik.http.routers.auth.tls.certresolver=mytlschallenge"
  supabase-storage:
    image: supabase/storage-api:v1.13.0
    restart: always
    environment:
      ANON_KEY: ${ANON_KEY}
      SERVICE_KEY: ${SERVICE_KEY}
      DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres
      AUTH_EXTERNAL_URL: https://auth.${SUBDOMAIN}.${MAIN_DOMAIN}
      FILE_SIZE_LIMIT: 52428800
    volumes: [supabase_storage:/var/lib/storage]
    depends_on: [supabase-db, supabase-auth]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.storage.rule=Host(\`storage.${SUBDOMAIN}.${MAIN_DOMAIN}\`)"
      - "traefik.http.routers.storage.entrypoints=websecure"
      - "traefik.http.routers.storage.tls.certresolver=mytlschallenge"
  supabase-postgrest:
    image: postgrest/postgrest:v12.0.3
    restart: always
    environment:
      PGRST_DB_URI: postgresql://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: ${JWT_SECRET}
    depends_on: [supabase-db]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.postgrest.rule=Host(\`rest.${SUBDOMAIN}.${MAIN_DOMAIN}\`)"
      - "traefik.http.routers.postgrest.entrypoints=websecure"
      - "traefik.http.routers.postgrest.tls.certresolver=mytlschallenge"
  supabase-pg-meta:
    image: supabase/postgres-meta:v0.80.0
    restart: always
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: supabase-db
      PG_META_DB_NAME: postgres
      PG_META_DB_USER: postgres
      PG_META_DB_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on: [supabase-db]
  supabase-studio:
    image: supabase/studio:latest
    restart: always
    environment:
      STUDIO_PG_META_URL: http://supabase-pg-meta:8080
      POSTGREST_URL: http://supabase-postgrest:3000
      SUPABASE_URL: https://${SUBDOMAIN}.${MAIN_DOMAIN}
      SUPABASE_PUBLIC_URL: https://${SUBDOMAIN}.${MAIN_DOMAIN}
      ANON_KEY: ${ANON_KEY}
      SERVICE_KEY: ${SERVICE_KEY}
    depends_on: [supabase-pg-meta, supabase-postgrest]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(\`${SUBDOMAIN}.${MAIN_DOMAIN}\`)"
      - "traefik.http.routers.studio.entrypoints=websecure"
      - "traefik.http.routers.studio.tls.certresolver=mytlschallenge"
  supabase-realtime:
    image: supabase/realtime:v2.28.27
    restart: always
    environment:
      DB_HOST: supabase-db
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: ${POSTGRES_PASSWORD}
      DB_NAME: postgres
      PORT: 4000
      IP_VERSION: "v4"
    depends_on: [supabase-db]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.realtime.rule=Host(\`realtime.${SUBDOMAIN}.${MAIN_DOMAIN}\`)"
      - "traefik.http.routers.realtime.entrypoints=websecure"
      - "traefik.http.routers.realtime.tls.certresolver=mytlschallenge"
EOF
}

is_supabase_in_n8n() {
    [ -f "$N8N_PROJECT_DIR/docker-compose.yml" ] && grep -q "supabase-studio" "$N8N_PROJECT_DIR/docker-compose.yml"
}

add_to_n8n() {
    if is_supabase_in_n8n; then
        print_info "Supabase уже добавлен в n8n — пропускаем"
        return
    fi

    print_info "Добавление Supabase в n8n..."
    cd "$N8N_PROJECT_DIR"

    cp docker-compose.yml "docker-compose.yml.bak.$(date +%s)"

    TEMP_SERVICES="/tmp/supabase_services_$$"
    generate_supabase_services > "$TEMP_SERVICES"

    if grep -q "^volumes:" docker-compose.yml; then
        awk -v temp_file="$TEMP_SERVICES" '
        /^volumes:/ {
            while ((getline line < temp_file) > 0) {
                print line
            }
            close(temp_file)
            print ""
        }
        { print }
        ' docker-compose.yml > docker-compose.yml.tmp
    else
        cat docker-compose.yml "$TEMP_SERVICES" > docker-compose.yml.tmp
        echo "volumes:" >> docker-compose.yml.tmp
    fi

    echo "  supabase_db:" >> docker-compose.yml.tmp
    echo "  supabase_storage:" >> docker-compose.yml.tmp

    mv docker-compose.yml.tmp docker-compose.yml
    rm -f "$TEMP_SERVICES"

    if ! grep -q "JWT_SECRET" .env; then
        cat >> .env << EOF

# Supabase Secrets
JWT_SECRET=$JWT_SECRET
ANON_KEY=$ANON_KEY
SERVICE_KEY=$SERVICE_KEY
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF
    fi

    docker compose up -d
    cd "$ORIGINAL_DIR" || true
    print_success "Supabase интегрирован в n8n"
}

full_install() {
    if [ -d "$SUPABASE_PROJECT_DIR" ] && docker compose -f "$SUPABASE_PROJECT_DIR/docker-compose.yml" ps 2>/dev/null | grep -q "supabase-studio.*Up"; then
        print_info "Supabase уже установлен отдельно — пропускаем"
        return
    fi

    mkdir -p "$SUPABASE_PROJECT_DIR"
    cd "$SUPABASE_PROJECT_DIR"

    cat > .env << EOF
DOMAIN_NAME=$MAIN_DOMAIN
SUBDOMAIN=$SUBDOMAIN
SSL_EMAIL=$SSL_EMAIL
JWT_SECRET=$JWT_SECRET
ANON_KEY=$ANON_KEY
SERVICE_KEY=$SERVICE_KEY
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF

    cat > docker-compose.yml << 'EOF'
name: supabase
services:
  traefik:
    image: traefik:v3.0
    restart: always
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - traefik_/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(`traefik.${DOMAIN_NAME}`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=mytlschallenge"
      - "traefik.http.routers.traefik.service=api@internal"
EOF

    generate_supabase_services >> docker-compose.yml

    cat >> docker-compose.yml << EOF
volumes:
  traefik_:
  supabase_db:
  supabase_storage:
EOF

    docker compose up -d
    cd "$ORIGINAL_DIR" || true
    print_success "Supabase установлен отдельно"
}

main() {
    print_header "Автоматический установщик Supabase"

    check_ubuntu_version
    install_docker
    check_already_installed

    if $ALREADY_INSTALLED; then
        print_success "Supabase уже настроен — ничего не делаем."
        exit 0
    fi

    detect_n8n
    setup_parameters
    generate_secrets_if_needed
    post_setup_questions

    if $USE_EXISTING_N8N; then
        add_to_n8n
    else
        full_install
    fi

    print_header "ГОТОВО!"
    print_success "Supabase Studio: https://${SUBDOMAIN}.${MAIN_DOMAIN}"
}

case "${1:-}" in
    --help|-h)
        echo "Автоматический установщик Supabase"
        echo "Поддерживает интеграцию с n8n и автономную установку"
        ;;
    *)
        main
        ;;
esac

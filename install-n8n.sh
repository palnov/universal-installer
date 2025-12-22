#!/bin/bash
# Универсальный идемпотентный установщик n8n
# Основан на скрипте от Viacheslav Lykov (@JumbleAI)
# Модифицировано Александром Пальновым
# GitHub: https://github.com/palnov/universal-installer

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="n8n-compose"
ORIGINAL_DIR=$(pwd)
SUPABASE_INSTALL_URL="https://raw.githubusercontent.com/palnov/universal-installer/refs/heads/main/install-supabase.sh"

# === ФУНКЦИИ ===

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

ensure_lsof() {
    if ! command -v lsof &> /dev/null; then
        apt update && apt install -y lsof
    fi
}

check_ports() {
    print_header "Проверка портов 80/443"
    if lsof -i :80 >/dev/null 2>&1 || lsof -i :443 >/dev/null 2>&1; then
        print_error "Порт 80 или 443 занят. Traefik не запустится!"
        exit 1
    fi
    print_success "Порты свободны"
}

check_ubuntu_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $VERSION_ID in
            "20.0???"|"22.0???"|"24.0???")
                print_success "Ubuntu $VERSION_ID LTS поддерживается"
                ;;
            *)
                print_error "Неподдерживаемая версия: $VERSION_ID"
                exit 1
                ;;
        esac
    else
        print_error "Не определена версия Ubuntu"
        exit 1
    fi
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        print_warning "Установка Docker..."
        apt update
        apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable --now docker
        print_success "Docker установлен"
    else
        print_success "Docker уже установлен"
    fi
}

is_n8n_installed() {
    [[ -f "$PROJECT_DIR/.env" && -f "$PROJECT_DIR/docker-compose.yml" ]]
}

get_current_version() {
    if is_n8n_installed; then
        grep -E "^N8N_IMAGE_TAG=" "$PROJECT_DIR/.env" | cut -d'=' -f2
    fi
}

get_latest_version_from_docker() {
    local tag="$1"
    if [[ "$tag" == "latest" ]]; then
        echo "latest"
        return
    fi
    # Получаем список тегов из Docker Hub (ограничим 20 последними)
    curl -s "https://hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=20&ordering=-last_updated" | \
        jq -r '.results[].name' | grep -E "^[0-9]+(\.[0-9]+)*$" | sort -V | tail -n1
}

prompt_update() {
    local current="$1"
    local latest="$2"
    if [[ "$current" == "latest" ]]; then
        print_info "Используется тег 'latest'. Обновление через 'docker compose pull'."
        if [[ "$latest" != "latest" ]]; then
            print_warning "Текущая версия не может быть сравнена напрямую."
        fi
        read -p "Выполнить обновление (pull + restart)? (y/N): " -n1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]]
        return $?
    else
        if dpkg --compare-versions "$latest" gt "$current" 2>/dev/null; then
            print_warning "Доступна новая версия: $current → $latest"
            read -p "Обновить сейчас? (y/N): " -n1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]]
            return $?
        else
            print_success "Установлена актуальная версия: $current"
            return 1  # не обновлять
        fi
    fi
}

update_n8n() {
    print_header "Обновление n8n"
    cd "$PROJECT_DIR"
    docker compose pull n8n
    docker compose up -d
    print_success "n8n обновлён"
    cd "$ORIGINAL_DIR"
}

full_install() {
    ensure_lsof
    check_ports
    check_ubuntu_version
    install_docker

    print_header "Настройка домена и SSL"
    read -p "Домен (например: n8n.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && { print_error "Домен обязателен"; exit 1; }
    [[ ! $DOMAIN =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && { print_error "Неверный формат домена"; exit 1; }

    read -p "Email для Let's Encrypt: " SSL_EMAIL
    [[ -z "$SSL_EMAIL" ]] && { print_error "Email обязателен"; exit 1; }
    [[ ! $SSL_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && { print_error "Неверный email"; exit 1; }

    if [[ $DOMAIN =~ ^([^.]+)\.(.*)$ ]]; then
        SUBDOMAIN="${BASH_REMATCH[1]}"
        MAIN_DOMAIN="${BASH_REMATCH[2]}"
    else
        SUBDOMAIN="n8n"
        MAIN_DOMAIN="$DOMAIN"
    fi

    print_info "Выбор версии n8n:"
    echo "  1) latest"
    echo "  2) 2 (рекомендуется)"
    echo "  3) 1"
    echo "  4) Вручную"
    read -p "Выбор (по умолчанию 2): " CHOICE
    case $CHOICE in
        1) TAG="latest" ;;
        2|"") TAG="2" ;;
        3) TAG="1" ;;
        4) read -p "Тег: " TAG; TAG="${TAG:-2}" ;;
        *) TAG="2" ;;
    esac

    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"

    cat > .env << EOF
DOMAIN_NAME=$MAIN_DOMAIN
SUBDOMAIN=$SUBDOMAIN
SSL_EMAIL=$SSL_EMAIL
N8N_IMAGE_TAG=$TAG
GENERIC_TIMEZONE=Europe/Moscow
EOF

    cat > docker-compose.yml << EOF
name: n8n
services:
  traefik:
    image: traefik
    restart: always
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=\${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - traefik_/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`traefik.\${DOMAIN_NAME}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=mytlschallenge"
      - "traefik.http.routers.traefik.service=api@internal"

  n8n:
    image: docker.n8n.io/n8nio/n8n:\${N8N_IMAGE_TAG}
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`\${SUBDOMAIN}.\${DOMAIN_NAME}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=mytlschallenge"
    environment:
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_HOST=\${SUBDOMAIN}.\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_RUNNERS_ENABLED=true
      - NODE_ENV=production
      - WEBHOOK_URL=https://\${SUBDOMAIN}.\${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - TZ=\${GENERIC_TIMEZONE}
    volumes:
      - n8n_/home/node/.n8n
      - ./local-files:/files

volumes:
  n8n_
  traefik_
EOF

    mkdir -p local-files
    docker compose up -d
    sleep 10

    # systemd
    cat > /etc/systemd/system/n8n.service << EOF
[Unit]
Description=n8n
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$(pwd)
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable n8n

    print_success "n8n установлен: https://${SUBDOMAIN}.${MAIN_DOMAIN}"
    cd "$ORIGINAL_DIR"
}

offer_supabase() {
    print_header "Установка Supabase (опционально)"
    read -p "Установить Supabase через отдельный скрипт? (y/N): " -n1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if ! command -v wget &> /dev/null; then
            apt install -y wget
        fi
        wget -O install-supabase.sh "$SUPABASE_INSTALL_URL"
        chmod +x install-supabase.sh
        ./install-supabase.sh
    fi
}

# === ОСНОВНОЙ ХОД ===

if [[ $EUID -ne 0 ]]; then
    print_error "Запустите с sudo"
    exit 1
fi

if is_n8n_installed; then
    print_header "n8n уже установлен"
    CURRENT_TAG=$(get_current_version)
    print_info "Текущая версия: $CURRENT_TAG"

    if command -v jq &> /dev/null; then
        LATEST_TAG=$(get_latest_version_from_docker "$CURRENT_TAG")
        print_info "Последняя стабильная версия: $LATEST_TAG"
    else
        print_warning "jq не установлен — проверка версии невозможна"
        LATEST_TAG="$CURRENT_TAG"
    fi

    if prompt_update "$CURRENT_TAG" "$LATEST_TAG"; then
        update_n8n
    else
        print_success "Обновление не требуется или отклонено"
    fi

    # Всегда предлагаем Supabase, даже при повторном запуске
    offer_supabase
else
    print_header "Первичная установка n8n"
    full_install
    offer_supabase
fi
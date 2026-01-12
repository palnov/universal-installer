#!/usr/bin/env bash
set -euo pipefail

# --- Конфигурация ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/supabase-docker"

# --- Функции ---
print_help() {
    cat <<EOF
Supabase Self-Hosted Docker Installer

Использование:
  $0 [опции]

Опции:
  -c, --configure-only   Пропустить установку зависимостей и загрузку файлов.
                         Предполагается, что supabase-docker уже установлен.
  -u, --update           Обновить только docker-compose файлы
  -h, --help             Показать эту справку

Описание:
  Скрипт устанавливает Supabase в self-hosted режиме с Docker Compose.
  Без флагов выполняет полную установку.
  С флагом -c только настраивает существующую установку.

Примеры:
  $0                    # Полная установка
  $0 -c                 # Только настройка
  $0 -u                 # Обновить docker-compose файлы
EOF
}

enable_autostart() {
    echo "⚡ Настраиваем автозапуск при перезагрузке сервера..."
    
    # 1. Включаем автозапуск Docker сервиса
    echo "🐳 Настраиваем автозапуск Docker..."
    if sudo systemctl enable docker 2>/dev/null; then
        echo "✅ Docker будет запускаться автоматически при загрузке системы"
    else
        echo "⚠️  Не удалось настроить автозапуск Docker"
    fi
    
    # 2. Создаем systemd сервис для Supabase
    echo "🚀 Создаем systemd сервис для Supabase..."
    
    sudo cat > /etc/systemd/system/supabase.service <<EOF
[Unit]
Description=Supabase Docker Compose
Requires=docker.service
After=docker.service
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart

# Перезапускать контейнеры если они упали
Restart=on-failure
RestartSec=10

# Устанавливаем лимиты
LimitNOFILE=1048576
LimitNPROC=512

# Безопасность
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # 3. Создаем таймер для периодической проверки
    echo "⏰ Создаем таймер для автоматического перезапуска..."
    
    sudo cat > /etc/systemd/system/supabase-restart.timer <<EOF
[Unit]
Description=Weekly restart of Supabase containers
Requires=supabase.service

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    sudo cat > /etc/systemd/system/supabase-restart.service <<EOF
[Unit]
Description=Restart Supabase containers
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/docker compose restart
EOF
    
    # 4. Перечитываем конфигурацию systemd и включаем сервисы
    sudo systemctl daemon-reload
    
    # Включаем Supabase сервис
    if sudo systemctl enable supabase.service; then
        echo "✅ Сервис Supabase настроен на автозапуск"
    else
        echo "⚠️  Не удалось включить сервис Supabase"
    fi
    
    # Включаем таймер перезапуска (опционально)
    if sudo systemctl enable supabase-restart.timer; then
        echo "✅ Таймер перезапуска Supabase включен (раз в неделю)"
    else
        echo "⚠️  Не удалось включить таймер перезапуска"
    fi
    
    # Запускаем таймер
    sudo systemctl start supabase-restart.timer
    
    # 5. Создаем скрипт для crontab как fallback
    echo "📋 Создаем fallback через cron..."
    
    sudo cat > /etc/cron.d/supabase-autostart <<EOF
# Автозапуск Supabase при перезагрузке
@reboot root sleep 30 && cd $PROJECT_DIR && /usr/bin/docker compose up -d > /var/log/supabase-startup.log 2>&1

# Ежедневная проверка что Supabase работает
0 3 * * * root cd $PROJECT_DIR && /usr/bin/docker compose ps | grep -q "Up" || /usr/bin/docker compose up -d >> /var/log/supabase-check.log 2>&1
EOF
    
    echo "✅ Настроены multiple уровни автозапуска:"
    echo "   1. systemd сервис (основной)"
    echo "   2. systemd таймер (перезапуск раз в неделю)"
    echo "   3. crontab (fallback)"
}

check_autostart_status() {
    echo ""
    echo "🔍 Проверка настроек автозапуска..."
    
    # Проверяем Docker
    if systemctl is-enabled docker > /dev/null 2>&1; then
        echo "✅ Docker настроен на автозапуск"
    else
        echo "⚠️  Docker НЕ настроен на автозапуск"
    fi
    
    # Проверяем Supabase сервис
    if [[ -f "/etc/systemd/system/supabase.service" ]]; then
        if systemctl is-enabled supabase.service > /dev/null 2>&1; then
            echo "✅ Сервис Supabase настроен на автозапуск"
        else
            echo "⚠️  Сервис Supabase НЕ настроен на автозапуск"
        fi
    else
        echo "❌ Сервис Supabase не найден"
    fi
    
    # Проверяем таймер
    if [[ -f "/etc/systemd/system/supabase-restart.timer" ]]; then
        if systemctl is-enabled supabase-restart.timer > /dev/null 2>&1; then
            echo "✅ Таймер перезапуска Supabase активен"
        else
            echo "⚠️  Таймер перезапуска не активен"
        fi
    fi
    
    # Проверяем cron
    if [[ -f "/etc/cron.d/supabase-autostart" ]]; then
        echo "✅ Cron задачи настроены"
    fi
    
    echo ""
    echo "📋 Команды для управления:"
    echo "   Статус Supabase: sudo systemctl status supabase"
    echo "   Запуск Supabase: sudo systemctl start supabase"
    echo "   Остановка Supabase: sudo systemctl stop supabase"
    echo "   Перезапуск Supabase: sudo systemctl restart supabase"
    echo "   Просмотр логов: sudo journalctl -u supabase -f"
}

install_dependencies() {
    echo "📦 Обновляем систему и устанавливаем зависимости..."
    sudo apt-get update
    sudo apt-get install -y curl jq nginx certbot python3-certbot-nginx apache2-utils
}

install_docker() {
    echo "🐳 Устанавливаем Docker..."
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh
        
        # Сразу включаем автозапуск Docker
        sudo systemctl enable docker
        sudo systemctl start docker
        echo "✅ Docker установлен и настроен на автозапуск"
    else
        echo "✅ Docker уже установлен"
        
        # Проверяем что Docker настроен на автозапуск
        if ! systemctl is-enabled docker > /dev/null 2>&1; then
            echo "⚠️  Docker не настроен на автозапуск, настраиваем..."
            sudo systemctl enable docker
        fi
    fi
}

download_docker_files() {
    echo "📥 Загружаем файлы Docker Compose в $PROJECT_DIR..."
    
    # Создаем директорию
    mkdir -p "$PROJECT_DIR"
    
    # URL для скачивания файлов
    DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml"
    ENV_EXAMPLE_URL="https://raw.githubusercontent.com/supabase/supabase/master/docker/.env.example"
    
    # Скачиваем docker-compose.yml
    echo "⬇️  Загружаем docker-compose.yml..."
    if curl -sSL -o "$PROJECT_DIR/docker-compose.yml" "$DOCKER_COMPOSE_URL"; then
        echo "✅ docker-compose.yml загружен"
    else
        echo "❌ Не удалось загрузить docker-compose.yml"
        exit 1
    fi
    
    # Скачиваем .env.example
    echo "⬇️  Загружаем .env.example..."
    if curl -sSL -o "$PROJECT_DIR/.env.example" "$ENV_EXAMPLE_URL"; then
        echo "✅ .env.example загружен"
    else
        echo "⚠️  Не удалось загрузить .env.example, создаем базовый..."
        create_basic_env_example
    fi
    
    echo "✅ Файлы Docker загружены в $PROJECT_DIR"
}

create_basic_env_example() {
    cat > "$PROJECT_DIR/.env.example" <<'EOF'
# Database
POSTGRES_PASSWORD=your_postgres_password
POSTGRES_USER=postgres
POSTGRES_DB=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432

# JWT
JWT_SECRET=your_jwt_secret
JWT_EXPIRY=3600

# API Keys
ANON_KEY=your_anon_key
SERVICE_ROLE_KEY=your_service_role_key

# URLs
SITE_URL=https://your-domain.com
SUPABASE_PUBLIC_URL=https://your-domain.com
API_EXTERNAL_URL=https://your-domain.com

# Studio
STUDIO_DEFAULT_ORGANIZATION=Default Organization
STUDIO_DEFAULT_PROJECT=Default Project

# Auth
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=false

# Dashboard
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=password

# Security
PG_META_CRYPTO_KEY=your_pg_meta_crypto_key
VAULT_ENC_KEY=your_vault_enc_key
SECRET_KEY_BASE=your_secret_key_base

# Pooler
POOLER_TENANT_ID=your_pooler_tenant_id
EOF
}

update_docker_files() {
    echo "🔄 Обновляем файлы Docker Compose в $PROJECT_DIR..."
    
    if [[ ! -d "$PROJECT_DIR" ]]; then
        echo "❌ Папка $PROJECT_DIR не найдена"
        exit 1
    fi
    
    # URL для скачивания файлов
    DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml"
    ENV_EXAMPLE_URL="https://raw.githubusercontent.com/supabase/supabase/master/docker/.env.example"
    
    # Скачиваем docker-compose.yml
    echo "⬇️  Обновляем docker-compose.yml..."
    if curl -sSL -o "$PROJECT_DIR/docker-compose.yml.new" "$DOCKER_COMPOSE_URL"; then
        mv "$PROJECT_DIR/docker-compose.yml.new" "$PROJECT_DIR/docker-compose.yml"
        echo "✅ docker-compose.yml обновлен"
    else
        echo "❌ Не удалось обновить docker-compose.yml"
        rm -f "$PROJECT_DIR/docker-compose.yml.new"
    fi
    
    # Скачиваем .env.example
    echo "⬇️  Обновляем .env.example..."
    if curl -sSL -o "$PROJECT_DIR/.env.example.new" "$ENV_EXAMPLE_URL"; then
        # Сравниваем с существующим
        if [[ -f "$PROJECT_DIR/.env.example" ]]; then
            if ! diff -q "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env.example.new" > /dev/null; then
                mv "$PROJECT_DIR/.env.example.new" "$PROJECT_DIR/.env.example"
                echo "✅ .env.example обновлен (есть изменения)"
            else
                rm "$PROJECT_DIR/.env.example.new"
                echo "✅ .env.example уже актуален"
            fi
        else
            mv "$PROJECT_DIR/.env.example.new" "$PROJECT_DIR/.env.example"
            echo "✅ .env.example создан"
        fi
    else
        echo "❌ Не удалось обновить .env.example"
        rm -f "$PROJECT_DIR/.env.example.new"
    fi
    
    echo "✅ Файлы Docker обновлены"
}

configure_env() {
    echo "🔑 Генерируем ключи безопасности..."
    
    # Генерация ключей
    local POSTGRES_PASSWORD=$(openssl rand -hex 16)
    local JWT_SECRET=$(openssl rand -hex 32)
    local ANON_KEY=$(openssl rand -hex 32)
    local SERVICE_ROLE_KEY=$(openssl rand -hex 32)
    local PG_META_CRYPTO_KEY=$(openssl rand -hex 32)
    local VAULT_ENC_KEY=$(openssl rand -hex 32)
    local SECRET_KEY_BASE=$(openssl rand -hex 64)
    local POOLER_TENANT_ID=$(openssl rand -hex 16)
    
    echo "📝 Создаем .env файл из шаблона..."
    
    if [[ -f "$PROJECT_DIR/.env.example" ]]; then
        cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
        
        # Обновляем значения в .env файле
        update_env_value "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
        update_env_value "JWT_SECRET" "$JWT_SECRET"
        update_env_value "ANON_KEY" "$ANON_KEY"
        update_env_value "SERVICE_ROLE_KEY" "$SERVICE_ROLE_KEY"
        
        # URL настройки
        update_env_value "SITE_URL" "https://$MAIN_DOMAIN"
        update_env_value "SUPABASE_PUBLIC_URL" "https://$MAIN_DOMAIN"
        update_env_value "API_EXTERNAL_URL" "https://$MAIN_DOMAIN"
        
        # Dashboard credentials
        update_env_value "DASHBOARD_USERNAME" "$DASH_USER"
        update_env_value "DASHBOARD_PASSWORD" "$DASH_PASS"
        
        # Дополнительные ключи безопасности
        update_env_value "PG_META_CRYPTO_KEY" "$PG_META_CRYPTO_KEY"
        update_env_value "VAULT_ENC_KEY" "$VAULT_ENC_KEY"
        update_env_value "SECRET_KEY_BASE" "$SECRET_KEY_BASE"
        update_env_value "POOLER_TENANT_ID" "$POOLER_TENANT_ID"
        
        # Обновляем MAILER_URLPATHS если они есть
        update_env_value "MAILER_URLPATHS_CONFIRMATION" "https://$MAIN_DOMAIN/auth/v1/verify"
        update_env_value "MAILER_URLPATHS_RECOVERY" "https://$MAIN_DOMAIN/auth/v1/verify"
        update_env_value "MAILER_URLPATHS_EMAIL_CHANGE" "https://$MAIN_DOMAIN/auth/v1/verify"
        update_env_value "MAILER_URLPATHS_INVITE" "https://$MAIN_DOMAIN/auth/v1/verify"
        
        # Добавляем комментарий с информацией об установке
        echo "" >> "$PROJECT_DIR/.env"
        echo "# Let's Encrypt email: $LE_EMAIL" >> "$PROJECT_DIR/.env"
        echo "# Domain: $MAIN_DOMAIN" >> "$PROJECT_DIR/.env"
        echo "# Installed on: $(date)" >> "$PROJECT_DIR/.env"
        
        echo "✅ Файл .env создан из шаблона"
    else
        echo "❌ Файл .env.example не найден в $PROJECT_DIR!"
        echo "Создаем .env вручную..."
        cat > "$PROJECT_DIR/.env" <<EOF
# Database
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_USER=postgres
POSTGRES_DB=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432

# JWT
JWT_SECRET=$JWT_SECRET
JWT_EXPIRY=3600

# API Keys
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY

# URLs
SITE_URL=https://$MAIN_DOMAIN
SUPABASE_PUBLIC_URL=https://$MAIN_DOMAIN
API_EXTERNAL_URL=https://$MAIN_DOMAIN

# Studio
STUDIO_DEFAULT_ORGANIZATION=Default Organization
STUDIO_DEFAULT_PROJECT=Default Project

# Auth
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=false

# Dashboard
DASHBOARD_USERNAME=$DASH_USER
DASHBOARD_PASSWORD=$DASH_PASS

# Security
PG_META_CRYPTO_KEY=$PG_META_CRYPTO_KEY
VAULT_ENC_KEY=$VAULT_ENC_KEY
SECRET_KEY_BASE=$SECRET_KEY_BASE

# Pooler
POOLER_TENANT_ID=$POOLER_TENANT_ID

# Let's Encrypt email: $LE_EMAIL
# Domain: $MAIN_DOMAIN
# Installed on: $(date)
EOF
    fi
    
    # Сохраняем ключи для показа пользователю
    save_keys_to_file \
        "$MAIN_DOMAIN" \
        "$DASH_USER" \
        "$DASH_PASS" \
        "$POSTGRES_PASSWORD" \
        "$JWT_SECRET" \
        "$ANON_KEY" \
        "$SERVICE_ROLE_KEY" \
        "$PG_META_CRYPTO_KEY" \
        "$VAULT_ENC_KEY" \
        "$SECRET_KEY_BASE" \
        "$POOLER_TENANT_ID"
    
    # Показываем ключи пользователю
    echo ""
    show_keys_to_user
    echo ""
    read -rp "Нажмите Enter чтобы продолжить..."
}

update_env_value() {
    local key="$1"
    local value="$2"
    if grep -q "^$key=" "$PROJECT_DIR/.env"; then
        sed -i "s|^$key=.*|$key=$value|" "$PROJECT_DIR/.env"
    else
        echo "$key=$value" >> "$PROJECT_DIR/.env"
    fi
}

save_keys_to_file() {
    local domain="$1"
    shift
    local dash_user="$1"
    shift
    local dash_pass="$1"
    shift
    
    KEY_FILE="$SCRIPT_DIR/supabase-keys-$(date +%Y%m%d-%H%M%S).txt"
    
    cat > "$KEY_FILE" <<EOF
==========================================
🔥 ВАЖНО! Сохраните эти ключи в надежное место 🔥
==========================================
Домен: https://$domain
Пользователь панели: $dash_user
Пароль панели: $dash_pass

POSTGRES_PASSWORD: $1
JWT_SECRET: $2
ANON_KEY: $3
SERVICE_ROLE_KEY: $4

Дополнительные ключи безопасности:
PG_META_CRYPTO_KEY: $5
VAULT_ENC_KEY: $6
SECRET_KEY_BASE: $7
POOLER_TENANT_ID: $8
==========================================
Эти ключи необходимы для подключения к Supabase!
Файл .env: $PROJECT_DIR/.env
Файл с ключами: $KEY_FILE
==========================================
EOF
    
    # Сохраняем путь к файлу с ключами
    LATEST_KEY_FILE="$KEY_FILE"
}

show_keys_to_user() {
    if [[ -f "$LATEST_KEY_FILE" ]]; then
        cat "$LATEST_KEY_FILE"
    else
        echo "⚠️  Файл с ключами не найден"
    fi
}

fix_docker_compose() {
    echo "🔧 Проверяем docker-compose.yml на наличие проблем..."
    local compose_file="$PROJECT_DIR/docker-compose.yml"
    
    if [[ -f "$compose_file" ]]; then
        # Исправляем ошибку с Docker socket в volumes если есть
        if grep -q "/var/run/docker.sock:ro,z" "$compose_file"; then
            sed -i 's|/var/run/docker.sock:ro,z|/var/run/docker.sock:ro|g' "$compose_file"
            echo "✅ Исправлена ошибка с Docker socket"
        fi
        
        # Исправляем относительные пути volumes если нужно
        sed -i 's|\./volumes/|./volumes/|g' "$compose_file"
        
        # Добавляем restart политику в docker-compose.yml если её нет
        if ! grep -q "restart:" "$compose_file"; then
            echo "⚡ Добавляем политику restart в docker-compose.yml..."
            # Это сложная операция, лучше сделать backup
            cp "$compose_file" "$compose_file.backup"
            
            # Добавляем restart: unless-stopped ко всем сервисам
            sed -i '/^services:/a\\n  # Auto-restart policy' "$compose_file"
            sed -i '/^  [a-z]/ s/$/\n    restart: unless-stopped/' "$compose_file"
            echo "✅ Политика restart добавлена"
        fi
        
        echo "✅ docker-compose.yml проверен"
    else
        echo "⚠️  Файл docker-compose.yml не найден в $PROJECT_DIR"
        return 1
    fi
}

start_supabase() {
    echo "🚀 Запускаем Supabase..."
    cd "$PROJECT_DIR"
    
    # Создаем volumes директории если их нет
    mkdir -p volumes/postgres volumes/storage volumes/logs
    
    # Запускаем контейнеры
    docker compose pull
    docker compose up -d
    
    echo "⏳ Ожидаем запуск сервисов (30 секунд)..."
    sleep 30
    
    echo "📊 Статус контейнеров:"
    docker compose ps
    cd "$SCRIPT_DIR"
}

configure_nginx() {
    echo "🌐 Настраиваем Nginx..."
    sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    
    # Создаем Basic Auth файл
    echo "$DASH_PASS" | sudo htpasswd -ci /etc/nginx/.htpasswd "$DASH_USER"
    
    # Конфигурация Nginx
    sudo cat > /etc/nginx/sites-available/supabase <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MAIN_DOMAIN;
    
    # Redirect all HTTP to HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $MAIN_DOMAIN;

    # SSL certificates will be added by certbot
    ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
    
    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Basic Auth для защиты dashboard
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
    
    # Health check endpoint без аутентификации
    location /health {
        proxy_pass http://localhost:8000/health;
        auth_basic off;
    }
    
    # API endpoints без basic auth для клиентских приложений
    location ~ ^/(auth|rest|storage|realtime)/v1/ {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        auth_basic off;
    }
}
EOF
    
    # Активируем конфигурацию
    sudo ln -sf /etc/nginx/sites-available/supabase /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Включаем автозапуск Nginx
    sudo systemctl enable nginx
    echo "✅ Nginx настроен на автозапуск"
}

setup_ssl() {
    echo "🔐 Настраиваем SSL..."
    
    # Временно останавливаем Nginx для Certbot
    sudo systemctl stop nginx
    
    echo "⏳ Получаем SSL сертификат для $MAIN_DOMAIN..."
    if sudo certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --email "$LE_EMAIL" \
        --domains "$MAIN_DOMAIN"; then
        
        echo "✅ SSL сертификат успешно получен"
    else
        echo "⚠️  Не удалось получить SSL сертификат от Let's Encrypt"
        echo "Создаем self-signed сертификат для теста..."
        
        sudo mkdir -p /etc/nginx/ssl
        sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/selfsigned.key \
            -out /etc/nginx/ssl/selfsigned.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$MAIN_DOMAIN"
        
        # Обновляем Nginx конфиг
        sudo sed -i "s|ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;|ssl_certificate /etc/nginx/ssl/selfsigned.crt;|" /etc/nginx/sites-available/supabase
        sudo sed -i "s|ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;|ssl_certificate_key /etc/nginx/ssl/selfsigned.key;|" /etc/nginx/sites-available/supabase
    fi
    
    # Запускаем Nginx обратно
    sudo systemctl start nginx
    
    # Проверяем конфигурацию Nginx
    echo "🔧 Проверяем конфигурацию Nginx..."
    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "✅ Nginx сконфигурирован корректно"
    else
        echo "❌ Ошибка в конфигурации Nginx"
        sudo nginx -t
        return 1
    fi
    
    # Настраиваем автоматическое обновление
    echo "🔄 Настраиваем автоматическое обновление SSL сертификатов..."
    sudo cat > /etc/cron.daily/renew-certbot <<'EOF'
#!/bin/bash
if [ -d "/etc/letsencrypt/live" ]; then
    certbot renew --quiet --post-hook "systemctl reload nginx"
fi
EOF
    sudo chmod +x /etc/cron.daily/renew-certbot
}

configure_firewall() {
    echo "🔥 Настраиваем фаервол UFW..."
    
    # Проверяем установлен ли UFW
    if ! command -v ufw &>/dev/null; then
        echo "📦 Устанавливаем UFW..."
        sudo apt-get install -y ufw
    fi
    
    # Настраиваем UFW
    sudo ufw --force disable 2>/dev/null || true
    echo "y" | sudo ufw reset
    
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    sudo ufw allow http
    sudo ufw allow https
    
    # Блокируем внутренние порты Supabase
    sudo ufw deny 8000/tcp   # Studio
    sudo ufw deny 5432/tcp   # PostgreSQL
    sudo ufw deny 54321/tcp  # Kong
    sudo ufw deny 54322/tcp  # Auth
    sudo ufw deny 54323/tcp  # Storage
    sudo ufw deny 54324/tcp  # Realtime
    
    # Включаем UFW
    echo "y" | sudo ufw enable
    
    echo "✅ Фаервол настроен"
    sudo ufw status verbose
}

verify_installation() {
    echo ""
    echo "=== Проверка установки ==="
    
    # Ждем полного запуска сервисов
    echo "⏳ Ожидаем полный запуск сервисов (еще 30 секунд)..."
    sleep 30
    
    # Проверяем контейнеры
    echo ""
    echo "📊 Статус контейнеров Supabase:"
    cd "$PROJECT_DIR"
    docker compose ps
    cd "$SCRIPT_DIR"
    
    # Проверяем локальную доступность
    echo ""
    echo "🔄 Проверяем локальную доступность Supabase Studio..."
    if curl -s -f -o /dev/null -w "Локальный статус: %{http_code}\n" http://localhost:8000/health; then
        echo "✅ Supabase Studio запущен локально на порту 8000"
    else
        echo "⚠️  Supabase Studio не отвечает локально"
        echo "Проверьте логи: cd $PROJECT_DIR && docker compose logs"
    fi
    
    # Проверяем доступность через Nginx
    echo ""
    echo "🔄 Проверяем доступность через Nginx (с аутентификацией)..."
    if curl -s -f -o /dev/null -w "Nginx статус: %{http_code}\n" -u "$DASH_USER:$DASH_PASS" https://$MAIN_DOMAIN/health 2>/dev/null; then
        echo "✅ Supabase доступен через Nginx с SSL и аутентификацией"
    else
        echo "⚠️  Проблемы с доступом через Nginx"
    fi
    
    # Проверяем API endpoints без аутентификации
    echo ""
    echo "🔄 Проверяем API endpoints..."
    if curl -s -f -o /dev/null -w "API статус: %{http_code}\n" https://$MAIN_DOMAIN/rest/v1/ 2>/dev/null; then
        echo "✅ API доступен без аутентификации (как настроено)"
    else
        echo "⚠️  API не отвечает"
    fi
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "✅ УСТАНОВКА ЗАВЕРШЕНА!"
    echo "=========================================="
    echo ""
    echo "🌐 Supabase Studio: https://$MAIN_DOMAIN"
    echo "👤 Пользователь: $DASH_USER"
    echo "🔑 Пароль: $DASH_PASS"
    echo ""
    echo "🔧 Ключевые эндпоинты:"
    echo "   Dashboard: https://$MAIN_DOMAIN"
    echo "   REST API: https://$MAIN_DOMAIN/rest/v1/"
    echo "   Auth API: https://$MAIN_DOMAIN/auth/v1/"
    echo "   Storage API: https://$MAIN_DOMAIN/storage/v1/"
    echo "   Realtime API: https://$MAIN_DOMAIN/realtime/v1/"
    echo ""
    echo "💾 Расположение файлов:"
    echo "   Конфигурация: $PROJECT_DIR/"
    echo "   Файл .env: $PROJECT_DIR/.env"
    echo "   Docker compose: $PROJECT_DIR/docker-compose.yml"
    
    # Показываем последний файл с ключами
    local key_files=("$SCRIPT_DIR"/supabase-keys-*.txt)
    if [[ ${#key_files[@]} -gt 0 ]] && [[ -f "${key_files[0]}" ]]; then
        local latest_key_file=$(ls -t "$SCRIPT_DIR"/supabase-keys-*.txt | head -1)
        echo "   Файл с ключами: $latest_key_file"
        echo ""
        echo "🔐 Ключи безопасности сохранены в файле выше."
        echo "   Сохраните этот файл в надежное место!"
    fi
    
    echo ""
    echo "⚡ АВТОЗАПУСК НАСТРОЕН:"
    echo "   Supabase будет автоматически запускаться при перезагрузке сервера"
    echo ""
    echo "⚙️ Команды управления через systemd:"
    echo "   Статус Supabase: sudo systemctl status supabase"
    echo "   Запуск Supabase: sudo systemctl start supabase"
    echo "   Остановка Supabase: sudo systemctl stop supabase"
    echo "   Перезапуск Supabase: sudo systemctl restart supabase"
    echo "   Просмотр логов: sudo journalctl -u supabase -f"
    echo ""
    echo "⚙️ Команды управления через Docker Compose:"
    echo "   Просмотр логов: cd $PROJECT_DIR && docker compose logs"
    echo "   Просмотр логов сервиса: docker compose logs [service_name]"
    echo "   Остановка: cd $PROJECT_DIR && docker compose down"
    echo "   Запуск: cd $PROJECT_DIR && docker compose up -d"
    echo ""
    echo "🔄 Обновление:"
    echo "   Обновить docker-compose файлы: $0

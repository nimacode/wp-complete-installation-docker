#!/bin/bash

# --- تنظیمات اولیه و توقف در صورت بروز خطای حیاتی ---
# set -e # (غیرفعال شد تا بتوانیم خطاها را مدیریت کنیم)

# رنگ‌ها
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}#########################################################${NC}"
echo -e "${BLUE}#     Ultimate WordPress + Docker + SSL Auto Deploy     #${NC}"
echo -e "${BLUE}#########################################################${NC}"

# --- بررسی دسترسی Root ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo ./deploy.sh)${NC}"
  exit
fi

# --- بخش ۱: نصب و تعمیر Docker ---
echo -e "${BLUE}>>> Checking Docker Installation...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${BLUE}>>> Docker not found. Starting installation process...${NC}"
    
    # 1. آپدیت سیستم و نصب پیش‌نیازها
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    # 2. اضافه کردن کلید امنیتی (اگر پوشه نباشد می‌سازد)
    mkdir -p /etc/apt/keyrings
    if [ -f /etc/apt/keyrings/docker.gpg ]; then
        rm /etc/apt/keyrings/docker.gpg
    fi
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # 3. اضافه کردن مخزن (به صورت تک خطی برای جلوگیری از خطا)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # 4. آپدیت و نصب نهایی
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # 5. استارت سرویس
    systemctl start docker
    systemctl enable docker
    
    echo -e "${GREEN}>>> Docker installed successfully!${NC}"
else
    echo -e "${GREEN}>>> Docker is already installed.${NC}"
fi

# اطمینان از بالا بودن داکر
echo -e "${BLUE}>>> Waiting for Docker daemon...${NC}"
sleep 5

# --- بخش ۲: دریافت اطلاعات ---
echo ""
read -p "Enter your Domain Name (e.g., example.com): " DOMAIN_NAME
read -p "Enter your Email (for SSL renewal): " EMAIL_ADDR
read -s -p "Enter Database Root Password: " DB_ROOT_PASS
echo ""
read -s -p "Enter Database User Password: " DB_USER_PASS
echo ""

PROJECT_DIR="/opt/$DOMAIN_NAME"

# پاکسازی نصب‌های قبلی اگر وجود داشته باشد
if [ -d "$PROJECT_DIR" ]; then
    echo -e "${BLUE}>>> Cleaning up existing project directory...${NC}"
    cd "$PROJECT_DIR"
    docker compose down 2>/dev/null || true
    cd ..
fi

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo -e "${GREEN}>>> Creating directory structure in $PROJECT_DIR...${NC}"
mkdir -p nginx/conf.d
mkdir -p php
mkdir -p certbot/conf
mkdir -p certbot/www

# --- بخش ۳: ساخت فایل‌های کانفیگ ---

# 1. .env
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$DB_ROOT_PASS
MYSQL_DATABASE=wordpress
MYSQL_USER=wp_user
MYSQL_PASSWORD=$DB_USER_PASS
WORDPRESS_DB_HOST=db
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wp_user
WORDPRESS_DB_PASSWORD=$DB_USER_PASS
DOMAIN_NAME=$DOMAIN_NAME
EOF

# 2. PHP Uploads Config
cat > php/uploads.ini <<EOF
file_uploads = On
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
EOF

# 3. docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3.8'

services:
  db:
    image: mariadb:10.6
    container_name: wp_db
    restart: unless-stopped
    env_file: .env
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - wp_net

  wordpress:
    image: wordpress:6.4-php8.1-fpm-alpine
    container_name: wp_app
    restart: unless-stopped
    depends_on:
      - db
    env_file: .env
    volumes:
      - wp_data:/var/www/html
      - ./php/uploads.ini:/usr/local/etc/php/conf.d/uploads.ini
    networks:
      - wp_net

  webserver:
    image: nginx:alpine
    container_name: wp_nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - wp_data:/var/www/html:ro
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    depends_on:
      - wordpress
    networks:
      - wp_net

  certbot:
    image: certbot/certbot
    container_name: wp_certbot
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot

volumes:
  wp_data:
  db_data:

networks:
  wp_net:
    driver: bridge
EOF

# --- بخش ۴: دریافت SSL ---

echo -e "${BLUE}>>> Generating TEMPORARY Nginx config for SSL challenge...${NC}"

# نکته: در اینجا از \$ استفاده می‌کنیم تا متغیرهای Nginx موقع ساخت فایل تفسیر نشوند
cat > nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

echo -e "${GREEN}>>> Starting Webserver (HTTP only)...${NC}"
docker compose up -d webserver

echo -e "${BLUE}>>> Waiting for Nginx to launch...${NC}"
sleep 5

echo -e "${BLUE}>>> Requesting Certbot SSL...${NC}"
docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN_NAME -d www.$DOMAIN_NAME --email $EMAIL_ADDR --agree-tos --no-eff-email --force-renewal

# بررسی موفقیت SSL
if [ ! -d "./certbot/conf/live/$DOMAIN_NAME" ]; then
    echo -e "${RED}!!! SSL GENERATION FAILED !!!${NC}"
    echo -e "${RED}Check: 1. Is Domain DNS (A Record) pointing to this IP?${NC}"
    echo -e "${RED}       2. Is Firewall blocking port 80?${NC}"
    # کانتینرها را پایین نمی‌آوریم تا بتوانید لاگ‌ها را چک کنید
    exit 1
fi

# --- بخش ۵: کانفیگ نهایی ---

echo -e "${GREEN}>>> SSL Success! Applying PRODUCTION config...${NC}"

cat > nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;

    root /var/www/html;
    index index.php;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires max;
        log_not_found off;
    }
}
EOF

echo -e "${BLUE}>>> Reloading Nginx with SSL...${NC}"
docker compose down
docker compose up -d

echo -e "${BLUE}>>> Setting Permissions...${NC}"
# صبر برای بالا آمدن کانتینر وردپرس
sleep 5
docker exec wp_app chown -R www-data:www-data /var/www/html

echo -e "${GREEN}#######################################################${NC}"
echo -e "${GREEN} SUCCESS! Your site is live: https://$DOMAIN_NAME ${NC}"
echo -e "${GREEN}#######################################################${NC}"

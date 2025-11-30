#!/bin/bash

# --- تنظیمات اولیه ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}#########################################################${NC}"
echo -e "${BLUE}#   WP Docker Auto Deploy (Fixed PDO Error Edition)     #${NC}"
echo -e "${BLUE}#########################################################${NC}"

# --- بررسی دسترسی Root ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo ./deploy.sh)${NC}"
  exit
fi

# --- گام صفر: تنظیم Mirror برای عبور از تحریم ---
echo -e "${BLUE}>>> Configuring Docker Mirrors...${NC}"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://docker.iranserver.com",
    "https://docker.arvancloud.ir",
    "https://mirror.gcr.io"
  ]
}
EOF

# --- گام ۱: نصب داکر ---
if ! command -v docker &> /dev/null; then
    echo -e "${BLUE}>>> Docker not found. Installing...${NC}"
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    if [ -f /etc/apt/keyrings/docker.gpg ]; then rm /etc/apt/keyrings/docker.gpg; fi
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# اعمال تنظیمات میرور
systemctl daemon-reload
systemctl restart docker
systemctl enable docker
sleep 5

# --- گام ۲: دریافت اطلاعات ---
echo ""
read -p "Enter your Domain Name (e.g., example.com): " DOMAIN_NAME
read -p "Enter your Email (for SSL renewal): " EMAIL_ADDR
read -s -p "Enter Database Root Password: " DB_ROOT_PASS
echo ""
read -s -p "Enter Database User Password: " DB_USER_PASS
echo ""

PROJECT_DIR="/opt/$DOMAIN_NAME"

# نکته: اینجا پروژه قبلی را پاک نمی‌کنیم تا اطلاعات دیتابیس نپرد، فقط کانتینرها را آپدیت می‌کنیم
if [ -d "$PROJECT_DIR" ]; then
    echo -e "${BLUE}>>> Updating existing project...${NC}"
    cd "$PROJECT_DIR"
else
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
fi

echo -e "${GREEN}>>> Creating/Updating project files...${NC}"
mkdir -p nginx/conf.d
mkdir -p php
mkdir -p certbot/conf
mkdir -p certbot/www

# --- گام ۳: ساخت فایل‌ها ---

# .env
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$DB_ROOT_PASS
MYSQL_DATABASE=egdbwp
MYSQL_USER=egusrwp
MYSQL_PASSWORD=$DB_USER_PASS
WORDPRESS_DB_HOST=db
WORDPRESS_DB_NAME=egdbwp
WORDPRESS_DB_USER=egusrwp
WORDPRESS_DB_PASSWORD=$DB_USER_PASS
DOMAIN_NAME=$DOMAIN_NAME
EOF

# PHP Config
cat > php/uploads.ini <<EOF
file_uploads = On
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
EOF

# --- بخش حیاتی جدید: ساخت Dockerfile اختصاصی ---
# این فایل مشکل PDO را حل می‌کند
cat > Dockerfile <<EOF
FROM wordpress:6.4-php8.1-fpm-alpine

# نصب اکستنشن‌های مورد نیاز پلاگین‌ها (PDO MySQL)
RUN docker-php-ext-install pdo pdo_mysql
EOF

# Docker Compose (تغییر یافته برای استفاده از Dockerfile)
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
    build: .                # <--- تغییر مهم: بیلد از روی Dockerfile
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

# --- گام ۴: بیلد و اجرا ---

echo -e "${BLUE}>>> Building custom WordPress image with PDO support...${NC}"
# اول بیلد می‌کنیم
docker compose build

# اگر کانفیگ SSL از قبل هست، مستقیم می‌رویم سراغ پروداکشن
if [ -f "./nginx/conf.d/default.conf" ] && grep -q "listen 443 ssl" "./nginx/conf.d/default.conf"; then
    echo -e "${GREEN}>>> SSL config found. Restarting services...${NC}"
    docker compose down
    docker compose up -d
    
    echo -e "${BLUE}>>> Fixing Permissions...${NC}"
    sleep 5
    docker exec wp_app chown -R www-data:www-data /var/www/html
    
    echo -e "${GREEN}#######################################################${NC}"
    echo -e "${GREEN} FIXED! PDO Driver installed. Check your site now. ${NC}"
    echo -e "${GREEN}#######################################################${NC}"
    exit 0
fi

# اگر بار اول است و SSL نداریم (ادامه مراحل قبلی)...
echo -e "${BLUE}>>> Setting up SSL for the first time...${NC}"

# کانفیگ موقت
cat > nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

docker compose up -d webserver
sleep 10

docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN_NAME -d www.$DOMAIN_NAME --email $EMAIL_ADDR --agree-tos --no-eff-email --force-renewal

if [ ! -d "./certbot/conf/live/$DOMAIN_NAME" ]; then
    echo -e "${RED}!!! SSL FAILED !!!${NC}"
    exit 1
fi

# کانفیگ نهایی
cat > nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    root /var/www/html;
    index index.php;
    client_max_body_size 64M;

    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ { expires max; log_not_found off; }
}
EOF

docker compose down
docker compose up -d

echo -e "${BLUE}>>> Fixing Permissions...${NC}"
sleep 5
docker exec wp_app chown -R www-data:www-data /var/www/html

echo -e "${GREEN}#######################################################${NC}"
echo -e "${GREEN} DONE! Website is live: https://$DOMAIN_NAME ${NC}"
echo -e "${GREEN}#######################################################${NC}"

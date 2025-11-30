#!/bin/bash

# --- تنظیمات ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}#########################################################################${NC}"
echo -e "${BLUE}#   WP FINAL DEPLOY (SOAP + All Loaders + Latest Core + Fix Structure)  #${NC}"
echo -e "${BLUE}#########################################################################${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo ./deploy.sh)${NC}"
  exit
fi

# --- گام صفر: تنظیم Mirror ---
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
systemctl daemon-reload
systemctl restart docker

# --- گام ۱: دریافت اطلاعات ---
echo ""
echo -e "${RED}!!! TYPE CAREFULLY (eevgold vs evvgold) !!!${NC}"
read -p "Enter your Domain Name (e.g., eevgold.com): " DOMAIN_NAME
read -p "Enter your Email (for SSL renewal): " EMAIL_ADDR
read -s -p "Enter Database Root Password: " DB_ROOT_PASS
echo ""
read -s -p "Enter Database User Password: " DB_USER_PASS
echo ""

PROJECT_DIR="/opt/$DOMAIN_NAME"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

mkdir -p nginx/conf.d php certbot/conf certbot/www

# --- گام ۲: ساخت فایل‌ها ---

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
memory_limit = 512M
upload_max_filesize = 128M
post_max_size = 128M
max_execution_time = 600
EOF

# --- Dockerfile (UPDATED: Added SOAP) ---
cat > Dockerfile <<EOF
FROM wordpress:php8.1-fpm

# نصب ابزارها + کتابخانه XML برای SOAP
RUN apt-get update && apt-get install -y curl tar libxml2-dev

# 1. نصب اکستنشن‌های PHP (شامل SOAP)
RUN docker-php-ext-install pdo pdo_mysql soap

# 2. نصب ionCube Loader
RUN curl -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -L -o ioncube.tar.gz 'https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz' \\
    && tar -xf ioncube.tar.gz \\
    && mv ioncube/ioncube_loader_lin_8.1.so \$(php-config --extension-dir) \\
    && echo "zend_extension=ioncube_loader_lin_8.1.so" > /usr/local/etc/php/conf.d/00-ioncube.ini \\
    && rm -rf ioncube ioncube.tar.gz

# 3. نصب SourceGuardian Loader
RUN curl -L -o sourceguardian.tar.gz https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz \\
    && tar -xf sourceguardian.tar.gz \\
    && cp ixed.8.1.lin \$(php-config --extension-dir) \\
    && echo "extension=ixed.8.1.lin" > /usr/local/etc/php/conf.d/02-sourceguardian.ini \\
    && rm -rf sourceguardian.tar.gz *.lin
EOF

# --- Docker Compose ---
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
    build: .
    container_name: wp_app
    restart: unless-stopped
    depends_on:
      - db
    env_file: .env
    volumes:
      # هسته وردپرس
      - wp_core:/var/www/html
      # محتوای شما
      - ./wp_data:/var/www/html/wp-content
      # کانفیگ آپلود
      - ./php/uploads.ini:/usr/local/etc/php/conf.d/uploads.ini
    networks:
      - wp_net

  phpmyadmin:
    image: phpmyadmin/phpmyadmin
    container_name: wp_pma
    restart: unless-stopped
    depends_on:
      - db
    environment:
      PMA_HOST: db
      PMA_ABSOLUTE_URI: https://${DOMAIN_NAME}/pma/
      UPLOAD_LIMIT: 128M
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
      - wp_core:/var/www/html:ro
      - ./wp_data:/var/www/html/wp-content:ro
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    depends_on:
      - wordpress
      - phpmyadmin
    networks:
      - wp_net

  certbot:
    image: certbot/certbot
    container_name: wp_certbot
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot

volumes:
  db_data:
  wp_core:

networks:
  wp_net:
    driver: bridge
EOF

# --- گام ۳: بیلد و اجرا ---

echo -e "${BLUE}>>> Rebuilding with SOAP extension...${NC}"
# فورس بیلد می‌کنیم تا Dockerfile جدید خوانده شود
docker compose build --no-cache

# بررسی SSL
if [ -f "./nginx/conf.d/default.conf" ] && grep -q "listen 443 ssl" "./nginx/conf.d/default.conf"; then
    echo -e "${GREEN}>>> SSL config found. Applying final config...${NC}"
    
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
    client_max_body_size 128M;

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires max;
        log_not_found off;
        try_files \$uri =404;
    }

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
    location ^~ /pma/ {
        proxy_pass http://phpmyadmin:80/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    
    docker compose down
    docker compose up -d
    echo -e "${BLUE}>>> Fixing Permissions...${NC}"
    sleep 10
    docker exec wp_app chown -R www-data:www-data /var/www/html/wp-content
    echo -e "${GREEN}SUCCESS! SOAP Installed.${NC}"
    exit 0
fi

# اگر SSL نیست
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

echo -e "${GREEN}###################################################################${NC}"
echo -e "${GREEN} DONE! Please run script again to finalize SSL config. ${NC}"
echo -e "${GREEN}###################################################################${NC}"

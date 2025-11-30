#!/bin/bash

# --- تنظیمات اولیه ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}###################################################################${NC}"
echo -e "${BLUE}# WP Docker Auto Deploy (Debian + Standard ionCube Edition)       #${NC}"
echo -e "${BLUE}###################################################################${NC}"

# --- بررسی دسترسی Root ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo ./deploy.sh)${NC}"
  exit
fi

# --- گام صفر: تنظیم Mirror داکر (ضد تحریم) ---
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

systemctl daemon-reload
systemctl restart docker
systemctl enable docker
sleep 5

# --- گام ۲: دریافت اطلاعات ---
echo ""
echo -e "${RED}!!! TYPE CAREFULLY (eevgold vs evvgold) !!!${NC}"
read -p "Enter your Domain Name (e.g., eevgold.com): " DOMAIN_NAME
read -p "Enter your Email (for SSL renewal): " EMAIL_ADDR
read -s -p "Enter Database Root Password: " DB_ROOT_PASS
echo ""
read -s -p "Enter Database User Password: " DB_USER_PASS
echo ""

# هشدار غلط املایی
if [[ "$DOMAIN_NAME" == *"evvgold"* ]]; then
    echo -e "${RED}WARNING: You typed 'evvgold' (double V). Usually it is 'eevgold' (double E).${NC}"
    read -p "Press Enter if 'evvgold' is correct, or Ctrl+C to cancel."
fi

PROJECT_DIR="/opt/$DOMAIN_NAME"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo -e "${GREEN}>>> Creating project files...${NC}"
mkdir -p nginx/conf.d php certbot/conf certbot/www

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

# --- Dockerfile (تغییر یافته به Debian) ---
# مزیت: از لینک اصلی ionCube که شما دادید پشتیبانی می‌کند
cat > Dockerfile <<EOF
FROM wordpress:6.4-php8.1-fpm

# نصب ابزارهای دانلود (استفاده از apt به جای apk)
RUN apt-get update && apt-get install -y curl tar

# 1. نصب درایورهای دیتابیس (PDO)
RUN docker-php-ext-install pdo pdo_mysql

# 2. نصب ionCube Loader (لینک استاندارد)
# جعل مرورگر برای عبور از فایروال دانلود
RUN curl -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" \
    -L -o ioncube.tar.gz 'https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz' \\
    && tar -xf ioncube.tar.gz \\
    && mv ioncube/ioncube_loader_lin_8.1.so \$(php-config --extension-dir) \\
    && echo "zend_extension=ioncube_loader_lin_8.1.so" > /usr/local/etc/php/conf.d/00-ioncube.ini \\
    && rm -rf ioncube ioncube.tar.gz
EOF

# Docker Compose
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
      - wp_data:/var/www/html
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
      UPLOAD_LIMIT: 64M
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
  wp_data:
  db_data:

networks:
  wp_net:
    driver: bridge
EOF

# --- گام ۴: بیلد و اجرا ---

echo -e "${BLUE}>>> Building custom image (Debian Base + Standard ionCube)...${NC}"
# فورس بیلد برای تغییر سیستم عامل
docker compose build --no-cache

# بررسی SSL
if [ -f "./nginx/conf.d/default.conf" ] && grep -q "listen 443 ssl" "./nginx/conf.d/default.conf"; then
    echo -e "${GREEN}>>> SSL config found. Applying updates...${NC}"
    
    # اعمال مجدد کانفیگ نهایی
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
    location ^~ /pma/ {
        proxy_pass http://phpmyadmin:80/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ { expires max; log_not_found off; }
}
EOF
    
    docker compose down
    docker compose up -d
    echo -e "${BLUE}>>> Fixing Permissions...${NC}"
    sleep 5
    docker exec wp_app chown -R www-data:www-data /var/www/html
    echo -e "${GREEN}SUCCESS!${NC}"
    exit 0
fi

# نصب SSL اولیه
echo -e "${BLUE}>>> Setting up SSL...${NC}"
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
echo -e "${BLUE}>>> Requesting SSL for $DOMAIN_NAME...${NC}"
docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN_NAME -d www.$DOMAIN_NAME --email $EMAIL_ADDR --agree-tos --no-eff-email --force-renewal

if [ ! -d "./certbot/conf/live/$DOMAIN_NAME" ]; then
    echo -e "${RED}!!! SSL FAILED !!!${NC}"
    echo -e "${RED}Please check your DNS records for $DOMAIN_NAME${NC}"
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
    location ^~ /pma/ {
        proxy_pass http://phpmyadmin:80/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ { expires max; log_not_found off; }
}
EOF

docker compose down
docker compose up -d
echo -e "${BLUE}>>> Fixing Permissions...${NC}"
sleep 5
docker exec wp_app chown -R www-data:www-data /var/www/html

echo -e "${GREEN}###################################################################${NC}"
echo -e "${GREEN} DONE! Website is live: https://$DOMAIN_NAME ${NC}"
echo -e "${GREEN}###################################################################${NC}"

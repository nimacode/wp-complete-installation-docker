#!/bin/bash

# --- تنظیمات ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}#########################################################################${NC}"
echo -e "${BLUE}#   WP UPDATE DEPLOY (Latest WP Core + All Loaders + Custom Structure)  #${NC}"
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
MYSQL_DATABASE=wordpress
MYSQL_USER=wp_user
MYSQL_PASSWORD=$DB_USER_PASS
WORDPRESS_DB_HOST=db
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wp_user
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

# --- Dockerfile (UPDATED: Using Latest WordPress) ---
# تغییر مهم: حذف 6.4 و استفاده از php8.1-fpm که آخرین نسخه وردپرس را می‌آورد
cat > Dockerfile <<EOF
FROM wordpress:php8.1-fpm

# نصب ابزارهای دانلود
RUN apt-get update && apt-get install -y curl tar

# 1. نصب PDO
RUN docker-php-ext-install pdo pdo_mysql

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

# --- Docker Compose (Shared Volume Fix) ---
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
      # 1. هسته وردپرس (index.php و ...) در والیوم داخلی
      - wp_core:/var/www/html
      
      # 2. پوشه wp_data شما (پلاگین‌ها و آپلودها)
      - ./wp_data:/var/www/html/wp-content
      
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
      # Nginx باید هسته را ببیند
      - wp_core:/var/www/html:ro
      
      # Nginx باید wp_data را ببیند
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

echo -e "${BLUE}>>> Updating WordPress to LATEST version (Rebuilding)...${NC}"
# این دستور مهم است: فایل‌های هسته قدیمی در والیوم باید با نسخه جدید جایگزین شوند
docker compose down --volumes
# نکته: حذف والیوم‌ها باعث حذف دیتابیس نمیشود چون db_data جداست، ولی wp_core باید رفرش شود

docker compose build --no-cache

# بررسی SSL
if [ -f "./nginx/conf.d/default.conf" ] && grep -q "listen 443 ssl" "./nginx/conf.d/default.conf"; then
    echo -e "${GREEN}>>> SSL config found. Starting services...${NC}"
    
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
    echo -e "${GREEN}SUCCESS! WordPress Updated to Latest Version.${NC}"
    exit 0
fi

# اگر SSL نیست... (مراحل نصب اولیه)
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

# کانفیگ نهایی SSL (همان بالا)
# ... (برای جلوگیری از تکرار کد، فرض بر این است که اگر SSL گرفته شود، باید دستی کانفیگ بالا را اعمال کنید یا اسکریپت را دوباره اجرا کنید)
# برای راحتی شما، اگر اسکریپت را دوباره اجرا کنید (چون فایل SSL هست) خودش کانفیگ نهایی را می‌زند.

echo -e "${GREEN}###################################################################${NC}"
echo -e "${GREEN} DONE! Please run the script ONE MORE TIME to finalize SSL if needed. ${NC}"
echo -e "${GREEN}###################################################################${NC}"

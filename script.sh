#!/bin/bash
set -e

install_src() {
  wget -q "$1" -O "$2"
  tar -xzf "$2"
  rm -f  "$2"
}

make_and_leave() {
  make
  make install
  cd ..
}

if [ "$#" -ne 3 ]; then
  echo "Usage: sudo $0 <nginx_ver> <mariadb_ver> <php_ver>"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: script must be run as root (sudo)."
  exit 2
fi

NGINX_VER=$1
MARIADB_VER=$2
PHP_VER=$3

PCRE_VER=8.45
ZLIB_VER=1.3.1
OPENSSL_VER=1.1.1v

NGINX_URL="http://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
PCRE_URL="https://sourceforge.net/projects/pcre/files/pcre/${PCRE_VER}/pcre-${PCRE_VER}.tar.gz"
ZLIB_URL="https://zlib.net/zlib-${ZLIB_VER}.tar.gz"
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz"
MARIADB_URL="https://archive.mariadb.org//mariadb-${MARIADB_VER}/source/mariadb-${MARIADB_VER}.tar.gz"
PHP_URL="https://www.php.net/distributions/php-${PHP_VER}.tar.gz"

for url in "$NGINX_URL" "$PCRE_URL" "$ZLIB_URL" "$OPENSSL_URL" "$MARIADB_URL" "$PHP_URL"; do
  if ! wget --spider -q "$url"; then
    echo "Error: cannot fetch $url"
    exit 3
  fi
done

apt-get update
apt-get install -y wget build-essential autoconf libtool pkg-config cmake
apt-get build-dep -y mariadb-server

mkdir -p /opt/src
cd /opt/src

install_src "$PCRE_URL" "pcre-${PCRE_VER}.tar.gz"
cd "pcre-${PCRE_VER}"
./configure --prefix=/opt/pcre
make_and_leave

install_src "$ZLIB_URL" "zlib-${ZLIB_VER}.tar.gz"
cd "zlib-${ZLIB_VER}"
./configure --prefix=/opt/zlib
make_and_leave

install_src "$OPENSSL_URL" "openssl-${OPENSSL_VER}.tar.gz"
cd "openssl-${OPENSSL_VER}"
./config --prefix=/opt/openssl
make_and_leave

install_src "$NGINX_URL" "nginx-${NGINX_VER}.tar.gz"
cd nginx-${NGINX_VER}
./configure \
  --prefix=/opt/nginx \
  --with-pcre=/opt/src/pcre-${PCRE_VER} \
  --with-zlib=/opt/src/zlib-${ZLIB_VER} \
  --with-openssl=/opt/src/openssl-${OPENSSL_VER} \
  --with-http_ssl_module
make_and_leave
cd /opt/src

cat > /opt/nginx/conf/nginx.conf << 'EOF'
worker_processes  auto;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    server {
        listen       80;
        root         /var/www/html;
        index        index.php;

        location ~ \.php$ {
            include       fastcgi_params;
            fastcgi_pass  127.0.0.1:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        }
    }
}
EOF

mkdir -p /var/www/html
echo "<?php phpinfo(); ?>" > /var/www/html/info.php

/opt/nginx/sbin/nginx

install_src "$MARIADB_URL" "mariadb-${MARIADB_VER}.tar.gz"
cd "mariadb-${MARIADB_VER}"
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/opt/mariadb
make_and_leave
cd /opt/src

mkdir -p /opt/mariadb/data
useradd -r mariadb
chown -R mariadb /opt/mariadb

printf "[mariadbd]\ndatadir=/opt/mariadb/data\n" > /opt/mariadb/my.cnf

/opt/mariadb/scripts/mysql_install_db --user=mariadb --datadir=/opt/mariadb/data

/opt/mariadb/bin/mariadbd-safe --defaults-file=/opt/mariadb/my.cnf --user=mariadb &
sleep 10

/opt/mariadb/bin/mysql -u root <<EOSQL
CREATE USER 'dbadmin'@'10.1.0.73' IDENTIFIED BY 'Unix2025';
GRANT ALL PRIVILEGES ON *.* TO 'dbadmin'@'10.1.0.73' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOSQL

if ! echo "SELECT 1;" | /opt/mariadb/bin/mysql -u root &>/dev/null; then
  echo "Error: MariaDB did not start correctly."
  exit 4
fi

install_src "$PHP_URL" "php-${PHP_VER}.tar.gz"
cd "php-${PHP_VER}"
./configure \
  --prefix=/opt/php \
  --enable-fpm \
  --with-pdo-mysql \
  --with-mysqli \
  --without-sqlite3 \
  --without-pdo-sqlite
make_and_leave
cd /opt/src

mkdir -p /opt/php/etc/php-fpm.d
cp /opt/src/php-${PHP_VER}/sapi/fpm/php-fpm.conf /opt/php/etc/php-fpm.conf
cp /opt/src/php-${PHP_VER}/sapi/fpm/www.conf /opt/php/etc/php-fpm.d/www.conf

sed -i 's/^user = .*/user = www-data/' /opt/php/etc/php-fpm.d/www.conf
sed -i 's/^group = .*/group = www-data/' /opt/php/etc/php-fpm.d/www.conf

 /opt/php/sbin/php-fpm \
   --nodaemonize \
   --fpm-config /opt/php/etc/php-fpm.conf &

sleep 5

if curl -s http://localhost/info.php | grep -q "phpinfo"; then
  echo "Installation complete."
else
  echo "Installation failed: PHP info page not working."
  exit 5
fi

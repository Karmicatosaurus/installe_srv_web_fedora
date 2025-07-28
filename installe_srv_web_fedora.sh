#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Utilisation : $0 [--mariadb] [--pgsql] [--composer]"
    echo "\n\033[31mCe script doit être exécuté en tant que root !\033[0m"
    exit 1
fi

DOSSIER_BDD="/srv/bdd"

if [[ $EUID -ne 0 ]]; then
    echo "\033[31mCe script doit être exécuté en tant que root !\033[0m"
    exit 1
fi

MARIADB=false
PGSQL=false
COMPOSER=false

# --- Analyse des options ---
for arg in "$@"; do
  case "$arg" in
    --mariadb) MARIADB=true ;;
    --pgsql) PGSQL=true ;;
    --composer) COMPOSER=true ;;
  esac
done

echo "Installation des paquets pour httpd et php-fpm ..."
dnf install -y httpd php php-gd php-zip php-xml php-fpm php-cli php-common policycoreutils-python-utils mod_ssl

# Supprimer mod_php si présent
sed -i '/^AddHandler application\/x-httpd-php/d' /etc/httpd/conf.d/php.conf || true

echo "Configuration Apache pour utiliser PHP-FPM (via socket UNIX)..."
bash -c 'cat > /etc/httpd/conf.d/php-fpm.conf <<EOF
<FilesMatch \.php$>
    SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost/"
</FilesMatch>
EOF'

echo "Lancement serveur httpd et php-fpm ..."
systemctl enable --now httpd
systemctl enable --now php-fpm

if $MARIADB; then
    if [[ ! -d "${DOSSIER_BDD}/mariadb" ]]; then
        mkdir -p $DOSSIER_BDD/mariadb
    fi

    dnf install -y php-mysqlnd mariadb-server

    echo "Configuration de MariaDB avec /srv/bdd/mariadb..."
    systemctl stop mariadb || true

    rsync -av /var/lib/mysql/ $DOSSIER_BDD/mariadb/
    chown -R mysql:mysql $DOSSIER_BDD/mariadb

    # SELinux pour MariaDB
    echo "Configuration SELinux pour MariaDB..."
    semanage fcontext -a -t mysqld_db_t "${DOSSIER_BDD}/mariadb(/.*)?"
    restorecon -Rv $DOSSIER_BDD/mariadb

    # Config MariaDB
    sed -i "s|^datadir=.*|datadir=$DOSSIER_BDD/mariadb|" /etc/my.cnf.d/mariadb-server.cnf

    systemctl start mariadb
    systemctl enable mariadb
fi

if $PGSQL; then
    if [[ ! -d "${DOSSIER_BDD}/postgresql" ]]; then
        mkdir -p $DOSSIER_BDD/postgresql
    fi

    dnf install -y php-pgsql postgresql-server

    echo "Initialisation de PostgreSQL dans ${DOSSIER_BDD}/postgresql..."
    systemctl stop postgresql || true
    chown postgres:postgres $DOSSIER_BDD/postgresql
    sudo -u postgres /usr/bin/initdb -D $DOSSIER_BDD/postgresql

    # SELinux pour PostgreSQL (optionnel mais prudent)
    echo "Configuration SELinux pour PostgreSQL..."
    semanage fcontext -a -t postgresql_db_t "${DOSSIER_BDD}/postgresql(/.*)?"
    restorecon -Rv /srv/bdd/postgresql

    echo "Configuration systemd pour PostgreSQL..."
    mkdir -p /etc/systemd/system/postgresql.service.d
    bash -c "cat > /etc/systemd/system/postgresql.service.d/override.conf <<EOF
    [Service]
    Environment=PGDATA=$DOSSIER_BDD/postgresql
    EOF"

    systemctl daemon-reexec
    systemctl enable --now postgresql    
    
fi

if $COMPOSER; then
    echo "Téléchargementr de composer ..."

    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php -r "if (hash_file('sha384', 'composer-setup.php') === 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'.PHP_EOL; } else { echo 'Installer corrupt'.PHP_EOL; unlink('composer-setup.php'); exit(1); }"
    php composer-setup.php
    php -r "unlink('composer-setup.php');"

    if [ -e "composer.phar" ]; then
        echo "Copie de composer.phar dans /usr/local/bin/ ..."
        mv composer.phar /usr/local/bin/composer
    fi
fi

echo "Installation terminée !"


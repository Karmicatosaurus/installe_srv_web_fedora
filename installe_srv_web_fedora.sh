#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Utilisation : $0 [--mariadb] [--pgsql] [--composer]"
    echo "\n\033[31mCe script doit être exécuté en tant que root !\033[0m"
    exit 1
fi

# Teste si le script est lancé en tant que root
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

if $MARIADB || $PGSQL ]]; then

    # Dossier de stockage des données des BDD
    DOSSIER_BDD="/srv/bdd"

    # Si le dossier n'existe pas, on le créer
    if [[ ! -d "${DOSSIER_BDD}" ]]; then
        mkdir -p $DOSSIER_BDD
    fi

fi 

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
    echo "Téléchargement de composer ..."  
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    
    HASH_ORIGINE=$(curl -s https://composer.github.io/installer.sig)
    HASH_FICHIER=$(php -r "echo hash_file('SHA384', 'composer-setup.php');")

    if [ "$HASH_ORIGINE" != "HASH_FICHIER" ]; then
        echo "Le fichier téléchargé n'est pas correct !";
        rm composer-setup.php
        exit 1
    fi

    php composer-setup.php --install_dir=/usr/local/bin --filename=composer
    rm composer-setup.php
fi

echo "Installation terminée !"


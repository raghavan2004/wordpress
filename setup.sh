#!/bin/bash                    
#written by Sangam Lonkar             
#On Feb 08, 2018                   
                                                
ROOT_UID=0
MYSQL_USER=root
MYSQL_PASSWORD=toor
LOGFILE=script.log
ERRORFILE=script.err

if [[ "$EUID" -ne "$ROOT_UID" ]]; then
   echo "This script must be run as root" 
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive

check_install() {
    echo
    echo -e "Checking if $1 already installed"
    INSTALLED=$(dpkg -l | grep $1)
    if [ "$INSTALLED" != "" ]; then
        # installed
        return 0
    else
        # not installed
        return 1
    fi
}

install_package() {
    echo -e "Installing $1..."
    apt-get install $1 -y  >>$LOGFILE 2>>$ERRORFILE
    echo -e "$1 installed"
}

mysql_secure_installation() {
    echo -e "Removing insecure details from MySQL"
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e "DELETE FROM mysql.user WHERE User='';"
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e "DROP DATABASE test;"
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e "FLUSH PRIVILEGES;"
} >>$LOGFILE 2>>$ERRORFILE

install_mysql() {
    echo
    echo -e "InstallingMySQL server...."

    echo "mysql-community-server mysql-community-server/root-pass password $MYSQL_PASSWORD" | debconf-set-selections
    echo "mysql-community-server mysql-community-server/re-root-pass password $MYSQL_PASSWORD" | debconf-set-selections

    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 5072E1F5 
    if [ -f /etc/apt/sources.list.d/mysql.list ]; then
        echo -e "mysql repo already exists."
        echo -e "Removing old repo and creating new one."
        rm -f /etc/apt/sources.list.d/mysql.list
        echo "deb http://repo.mysql.com/apt/ubuntu/ trusty mysql-5.7" | tee /etc/apt/sources.list.d/mysql.list
    else
        echo -e "Creating mysql repo."
        echo "deb http://repo.mysql.com/apt/ubuntu trusty mysql-5.7" | tee /etc/apt/sources.list.d/mysql.list
    fi
    apt-get update >>$LOGFILE 2>>$ERRORFILE
    apt-get install mysql-server -y >>$LOGFILE 2>>$ERRORFILE
    echo -e "[${Gre}NOTICE${RCol}]  mysql-community-server installed"
    mysql_secure_installation
}

cat /var/www/html/info.php <<EOL
<?php
phpinfo();
EOL


configure_php_nginx() {
    sed -i 's/^;cgi.fix_pathinfo=1$/cgi.fix_pathinfo=0/' /etc/php/7.0/fpm/php.ini
    systemctl restart php7.0-fpm

cat > /etc/nginx/sites-available/default <<EOL


server {
        listen 80 default_server;
        listen [::]:80 default_server;
root /var/www/html;

# Add index.php to the list if you are using PHP
index index.php index.html index.htm index.nginx-debian.html;

location ~ .php$ {
        include snippets/fastcgi-php.conf;

#       # With php7.0-cgi alone:
#       fastcgi_pass 127.0.0.1:9000;
#       # With php7.0-fpm:
        fastcgi_pass unix:/run/php/php7.0-fpm.sock;
}


# deny access to .htaccess files, if Apache's document root
# concurs with nginx's one
#
location ~ /.ht {
       deny all;
}
}
EOL
service nginx restart
}


#MAIN SCRIPT STARTS HERE    


clear
echo -e "Starting script"
echo -e "Hello, $SUDO_USER.  This script will set up a WordPress site for you."
echo -e -n "Enter the domain name and press [ENTER]: "
read domain
echo -e -n "Do you need to setup new MySQL database? (y/n) "
read -e setupmysql
if [ "$setupmysql" == y ] ; then
    echo -e -n "MySQL Admin User: "
    read -e MYSQL_USER
    echo -e -n "MySQL Admin Password: "
    read -s MYSQL_PASSWORD
    echo
    echo -e -n "MySQL Host (Enter for default 'localhost'): "
    read -e mysqlhost
    mysqlhost=${mysqlhost:-localhost}
fi
dbname=${domain//.}_db;
dbuser="wp_user"
dbpass="wp_pass"
echo -e -n "WP Database Table Prefix [numbers, letters, and underscores only] (Enter for default 'wp_'): "
read -e dbtable
    dbtable=${dbtable:-wp_}


if check_install pv; then echo -e "pv already installed"; else install_package pv; fi
if check_install nginx; then echo -e "Nginx already installed"; else install_package nginx; fi
echo
if check_install mysql-community-server; then echo -e "MySQL Server already installed"; else install_mysql; fi

apt-get update >>$LOGFILE 2>>$ERRORFILE

for i in php7.0-fpm php-fpm php-mysql; do
    if check_install $i; then 
        echo -e "[${Gre}NOTICE${RCol}]  $i already installed"
    else
        install_package $i
    fi
done
echo -e "Setting configuration options for PHP and Nginx"
configure_php_nginx
if [ "$setupmysql" == y ] ; then
    echo -e "Setting up the database."
    dbsetup="create database $dbname;GRANT ALL PRIVILEGES ON $dbname.* TO $dbuser@$mysqlhost IDENTIFIED BY '$dbpass';FLUSH PRIVILEGES;"
    mysql -u $MYSQL_USER -p$MYSQL_PASSWORD -e "$dbsetup"
    if [ $? != "0" ]; then
        echo -e "Database creation failed. Aborting."
        exit 1
    fi
fi
sed -i "s/^\(127.0.0.1.*\)$/\1 $domain/" /etc/hosts
wget http://wordpress.org/latest.tar.gz
tar xzvf latest.tar.gz
echo -e "Configuring wordpress..."
mkdir -p /var/www/wordpress
cp -a wordpress/. /var/www/wordpress
cd /var/www/wordpress
wget https://api.wordpress.org/secret-key/1.1/salt/ -O salt.txt
cp wp-config-sample.php wp-config.php
chown -R "$SUDO_USER":www-data /var/www/wordpress/*
mkdir wp-content/uploads
chown -R :www-data /var/www/wordpress/wp-content/uploads
chmod 775 wp-content/uploads
sed -i "s#database_name_here#$dbname#g" wp-config.php
sed -i "s#username_here#$dbuser#g" wp-config.php
sed -i "s#password_here#$dbpass#g" wp-config.php
sed -i "s#wp_#$dbtable#g" wp-config.php
sed -i '49,56d;57r salt.txt' wp-config.php

cat > /etc/nginx/sites-available/wordpress << EOL
server {
  listen 80;

  root /var/www/wordpress;
  index index.php index.html index.htm;

  server_name domain.com;

  error_page 404 /404.html;
  error_page 500 502 503 504 /50x.html;
        
  location = /50x.html {
    root /usr/share/nginx/html;
  }
  
  location / {
    try_files \$uri \$uri/ /index.php?q=\$uri&\$args;
  }

  location ~ .php$ {
    try_files \$uri =404;
    fastcgi_split_path_info ^(.+.php)(/.+)$;
    fastcgi_pass unix:/run/php/php7.0-fpm.sock;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
  }

  location = /favicon.ico { 
    log_not_found off;
    access_log off;
  }
  
  location = /robots.txt {
    log_not_found off;
    access_log off;
    allow all; 
  }
  
  location ~* .(css|gif|ico|jpeg|jpg|js|png)$ {
    expires max;
    log_not_found off;
  }
}
EOL

nginx -t
rm -f /etc/nginx/sites-enabled/wordpress
rm -f /etc/nginx/sites-enabled/default
ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/wordpress

systemctl reload nginx

systemctl restart php7.0-fpm


echo
echo
echo -e "WordPress installed and configured."
echo -e "Visit the site at $domain"
echo -e "WordPress Database name: $dbname"
echo -e "WordPress Database user: $dbuser"
echo -e "WordPress Database password: $dbpass"
echo
echo

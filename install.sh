#!/bin/bash
# Multi-IP Postfix + Dovecot + Roundcube + PostfixAdmin with Live Stats
# For Ubuntu 24.04

set -e

### CONFIGURATION ###
DOMAIN="au-newsletters.com"
SUBDOMAINS=("ca01" "ca02" "ca03" "ca04" "ca05" "ca06" "ca07" "ca08" "ca09" "ca10")   # one-to-one with IPS below
IPS=("54.39.78.214" "54.39.78.219" "54.39.78.221" "54.39.78.222" "15.235.122.20" "15.235.122.21" "15.235.122.22" "15.235.122.23" "15.235.122.24" "15.235.122.72")
ADMIN_EMAIL="au-newsletters.com"
DB_PASS="StrongPass123"

### Update & install dependencies ###
apt update && apt upgrade -y
apt install -y postfix postfix-policyd-spf-python dovecot-imapd dovecot-pop3d \
 dovecot-mysql mariadb-server mariadb-client \
 php php-mysql php-intl php-xml php-cli php-mbstring php-curl \
 apache2 libapache2-mod-php certbot python3-certbot-apache \
 git composer unzip pflogsumm mailutils bind9 bind9utils

### Configure MySQL ###
mysql -e "CREATE DATABASE postfixadmin;"
mysql -e "CREATE USER 'postfixadmin'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON postfixadmin.* TO 'postfixadmin'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

### Install PostfixAdmin ###
cd /var/www
git clone https://github.com/postfixadmin/postfixadmin.git
cd postfixadmin
composer install --no-dev
chown -R www-data:www-data /var/www/postfixadmin

### Apache config for PostfixAdmin ###
cat > /etc/apache2/sites-available/postfixadmin.conf <<EOF
<VirtualHost *:80>
    ServerName mail.${DOMAIN}
    DocumentRoot /var/www/postfixadmin/public

    <Directory /var/www/postfixadmin/public>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2ensite postfixadmin.conf
a2enmod rewrite ssl
systemctl reload apache2

### Install Roundcube ###
cd /var/www
wget https://github.com/roundcube/roundcubemail/releases/download/1.6.9/roundcubemail-1.6.9-complete.tar.gz
tar -xvzf roundcubemail-1.6.9-complete.tar.gz
mv roundcubemail-1.6.9 roundcube
chown -R www-data:www-data /var/www/roundcube
rm roundcubemail-1.6.9-complete.tar.gz

### Apache config for Roundcube ###
cat > /etc/apache2/sites-available/roundcube.conf <<EOF
<VirtualHost *:80>
    ServerName webmail.${DOMAIN}
    DocumentRoot /var/www/roundcube

    <Directory /var/www/roundcube>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2ensite roundcube.conf
systemctl reload apache2

### SSL for all subdomains ###
for SUB in "${SUBDOMAINS[@]}"; do
  certbot --apache -d ${SUB}.${DOMAIN} -m ${ADMIN_EMAIL} --agree-tos --non-interactive
done
certbot --apache -d mail.${DOMAIN} -m ${ADMIN_EMAIL} --agree-tos --non-interactive
certbot --apache -d webmail.${DOMAIN} -m ${ADMIN_EMAIL} --agree-tos --non-interactive

### Configure Postfix for virtual domains ###
postconf -e "home_mailbox = Maildir/"
postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/mysql-virtual-domains.cf"
postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/mysql-virtual-mailboxes.cf"
postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql-virtual-aliases.cf"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"

### Enable Dovecot SQL auth ###
cat > /etc/dovecot/dovecot-sql.conf.ext <<EOF
driver = mysql
connect = host=localhost dbname=postfixadmin user=postfixadmin password=${DB_PASS}
default_pass_scheme = MD5-CRYPT
password_query = SELECT username AS user, password, domain FROM mailbox WHERE username='%u';
EOF

sed -i "s/#disable_plaintext_auth = yes/disable_plaintext_auth = yes/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/auth-system.conf.ext/auth-sql.conf.ext/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s|mail_location =.*|mail_location = maildir:/var/vmail/%d/%n/Maildir|" /etc/dovecot/conf.d/10-mail.conf
mkdir -p /var/vmail && chown -R vmail:vmail /var/vmail

### Install PostfixAdmin Stats Plugin ###
cd /var/www/postfixadmin/plugins
git clone https://github.com/postfixadmin/postfixadmin-stats stats
cd stats
composer install --no-dev
chown -R www-data:www-data /var/www/postfixadmin/plugins

### Setup maillog2sql ###
cd /usr/local/bin
wget https://raw.githubusercontent.com/postfixadmin/postfixadmin/master/ADDITIONS/logging/maillog2sql
chmod +x maillog2sql

mysql -u root postfixadmin < /var/www/postfixadmin/ADDITIONS/logging/maillog2sql.mysql

cat > /etc/maillog2sql.conf <<EOF
DBHOST=localhost
DBNAME=postfixadmin
DBUSER=postfixadmin
DBPASS=${DB_PASS}
TABLE=maillog
EOF

### Cron for live stats (every 5 min) ###
echo "*/5 * * * * root /usr/local/bin/maillog2sql -f /var/log/mail.log -c /etc/maillog2sql.conf" >> /etc/crontab

### Daily summary email ###
echo "0 1 * * * root pflogsumm /var/log/mail.log | mail -s 'Daily Mail Report' ${ADMIN_EMAIL}" >> /etc/crontab

### Restart services ###
systemctl restart postfix dovecot apache2 bind9

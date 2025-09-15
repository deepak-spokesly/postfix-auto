#!/bin/bash
# Postfix + Dovecot + DKIM + DMARC + BIND9 + SSL + Roundcube + PostfixAdmin
# Ubuntu 24.04 LTS
# Run as root

# === CONFIGURATION ===
DOMAIN="example.com"
SUBDOMAINS=("mail1" "mail2" "mail3")
IPS=("192.0.2.10" "192.0.2.11" "192.0.2.12")
EMAIL="admin@$DOMAIN"
WEBMAIL="webmail.$DOMAIN"
ADMINPANEL="mailadmin.$DOMAIN"

# === PREPARE SYSTEM ===
apt update -y && apt upgrade -y
DEBIAN_FRONTEND=noninteractive apt install -y postfix mailutils postfwd opendkim opendkim-tools opendmarc bind9 bind9utils bind9-dnsutils certbot dovecot-imapd dovecot-pop3d dovecot-lmtpd mariadb-server nginx php-fpm php-mysql php-intl php-mbstring php-xml unzip wget git

# === DATABASE SETUP ===
mysql -e "CREATE DATABASE mailserver;"
mysql -e "CREATE USER 'mailuser'@'localhost' IDENTIFIED BY 'mailpass';"
mysql -e "GRANT ALL PRIVILEGES ON mailserver.* TO 'mailuser'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# === POSTFIXADMIN INSTALL ===
cd /var/www/
wget https://github.com/postfixadmin/postfixadmin/archive/refs/tags/postfixadmin-3.3.13.tar.gz
tar xzf postfixadmin-*.tar.gz
mv postfixadmin-* postfixadmin
chown -R www-data:www-data postfixadmin

# Config
cp /var/www/postfixadmin/config.local.php /var/www/postfixadmin/config.local.php.bak || true
cat > /var/www/postfixadmin/config.local.php <<EOF
<?php
\$CONF['configured'] = true;
\$CONF['setup_password'] = '$(php -r "echo password_hash('setup123', PASSWORD_DEFAULT);")';
\$CONF['default_language'] = 'en';
\$CONF['database_type'] = 'mysqli';
\$CONF['database_host'] = 'localhost';
\$CONF['database_user'] = 'mailuser';
\$CONF['database_password'] = 'mailpass';
\$CONF['database_name'] = 'mailserver';
\$CONF['domain_path'] = 'NO';
\$CONF['domain_in_mailbox'] = 'YES';
\$CONF['encrypt'] = 'dovecot:SHA512-CRYPT';
\$CONF['dovecotpw'] = "/usr/bin/doveadm pw";
\$CONF['admin_email'] = '$EMAIL';
EOF

# Nginx vhost
cat > /etc/nginx/sites-available/postfixadmin.conf <<EOF
server {
    listen 80;
    server_name $ADMINPANEL;
    root /var/www/postfixadmin/public;

    location / {
        index index.php;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
}
EOF

ln -s /etc/nginx/sites-available/postfixadmin.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# SSL
certbot certonly --nginx -d $ADMINPANEL --agree-tos --non-interactive -m $EMAIL
sed -i "s|listen 80;|listen 443 ssl;|" /etc/nginx/sites-available/postfixadmin.conf
sed -i "/server_name/a \    ssl_certificate /etc/letsencrypt/live/$ADMINPANEL/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/$ADMINPANEL/privkey.pem;" /etc/nginx/sites-available/postfixadmin.conf
nginx -t && systemctl reload nginx

# === POSTFIX / DOVECOT SQL BACKEND CONFIG ===
# Postfix SQL maps
mkdir -p /etc/postfix/sql
cat > /etc/postfix/sql/mysql-virtual-mailbox-domains.cf <<EOF
user = mailuser
password = mailpass
hosts = 127.0.0.1
dbname = mailserver
query = SELECT domain FROM domain WHERE domain='%s'
EOF

cat > /etc/postfix/sql/mysql-virtual-mailbox-maps.cf <<EOF
user = mailuser
password = mailpass
hosts = 127.0.0.1
dbname = mailserver
query = SELECT maildir FROM mailbox WHERE username='%s'
EOF

cat > /etc/postfix/sql/mysql-virtual-alias-maps.cf <<EOF
user = mailuser
password = mailpass
hosts = 127.0.0.1
dbname = mailserver
query = SELECT goto FROM alias WHERE address='%s'
EOF

postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/sql/mysql-virtual-mailbox-domains.cf"
postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/sql/mysql-virtual-mailbox-maps.cf"
postconf -e "virtual_alias_maps = mysql:/etc/postfix/sql/mysql-virtual-alias-maps.cf"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"

# Dovecot SQL config
cat > /etc/dovecot/dovecot-sql.conf.ext <<EOF
driver = mysql
connect = host=127.0.0.1 dbname=mailserver user=mailuser password=mailpass
default_pass_scheme = SHA512-CRYPT
password_query = SELECT username as user, password FROM mailbox WHERE username='%u' AND active='1'
user_query = SELECT maildir AS home, 5000 AS uid, 5000 AS gid FROM mailbox WHERE username='%u' AND active='1'
EOF

# Create vmail user
groupadd -g 5000 vmail
useradd -g vmail -u 5000 vmail -d /var/mail

# Update Dovecot config
sed -i "s|^#mail_location =.*|mail_location = maildir:/var/mail/%d/%n/Maildir|" /etc/dovecot/conf.d/10-mail.conf
sed -i "s|^auth_mechanisms =.*|auth_mechanisms = plain login|" /etc/dovecot/conf.d/10-auth.conf
sed -i "s|^!include auth-system.conf.ext|#!include auth-system.conf.ext|" /etc/dovecot/conf.d/10-auth.conf
sed -i "s|^#!include auth-sql.conf.ext|!include auth-sql.conf.ext|" /etc/dovecot/conf.d/10-auth.conf

systemctl restart postfix dovecot nginx mariadb

# === AUTO RENEW ===
cat > /etc/cron.d/certbot-renew <<EOF
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload postfix dovecot nginx"
EOF

echo "========================================================="
echo "Setup complete!"
echo "Webmail: https://$WEBMAIL/"
echo "Admin Console: https://$ADMINPANEL/  (setup password: setup123)"
echo "Login with PostfixAdmin, add domain ($DOMAIN), then create mailboxes."
echo "Users will authenticate via database, not system accounts."
echo "========================================================="

#!/bin/bash
# Postfix + DKIM + DMARC + BIND9 DNS + Let's Encrypt SSL (per subdomain/IP)
# Ubuntu 24.04 LTS
# Run as root

# === CONFIGURATION ===
DOMAIN="example.com"
SUBDOMAINS=("("ca01" "ca02" "ca03" "ca04" "ca05" "ca06" "ca07" "ca08" "ca09" "ca10")   # one-to-one with IPS below")
IPS=("54.39.78.214" "54.39.78.219" "54.39.78.221" "54.39.78.222" "15.235.122.20" "15.235.122.21" "15.235.122.22" "15.235.122.23" "15.235.122.24" "15.235.122.72")
EMAIL="admin@$DOMAIN"   # For Let's Encrypt notifications

echo "[+] Updating system..."
apt update -y && apt upgrade -y

echo "[+] Installing packages..."
DEBIAN_FRONTEND=noninteractive apt install -y postfix mailutils postfwd opendkim opendkim-tools opendmarc bind9 bind9utils bind9-dnsutils certbot

# === POSTFIX BASE CONFIG ===
postconf -e "myhostname = ${SUBDOMAINS[0]}.$DOMAIN"
postconf -e "myorigin = $DOMAIN"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost"
postconf -e "relay_domains ="
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "biff = no"
postconf -e "append_dot_mydomain = no"
postconf -e "readme_directory = no"
postconf -e "compatibility_level = 2"
postconf -e "smtpd_recipient_restrictions = check_policy_service inet:127.0.0.1:10040, permit"

# === MASTER.CF MULTI-IP + TLS ===
cp /etc/postfix/master.cf /etc/postfix/master.cf.bak
for i in "${!SUBDOMAINS[@]}"; do
  sub="${SUBDOMAINS[$i]}"
  ip="${IPS[$i]}"

  cat >> /etc/postfix/master.cf <<EOF

smtp-$sub   unix  -       -       n       -       -       smtp
    -o smtp_bind_address=$ip
    -o smtp_helo_name=$sub.$DOMAIN
    -o smtp_tls_security_level=may
    -o smtp_tls_cert_file=/etc/letsencrypt/live/$sub.$DOMAIN/fullchain.pem
    -o smtp_tls_key_file=/etc/letsencrypt/live/$sub.$DOMAIN/privkey.pem
EOF
done

# === POSTFWD FOR ROUND ROBIN ===
cat > /etc/postfwd/postfwd.cf <<EOF
id=ROUNDRBIN action=prepend Transport=smtp-%counter(${SUBDOMAINS[*]})
EOF
systemctl enable postfwd
systemctl restart postfwd

# === OPENDKIM ===
mkdir -p /etc/opendkim/keys
cat > /etc/opendkim.conf <<EOF
Syslog yes
UMask 002
Canonicalization relaxed/simple
Mode sv
SubDomains no
Socket inet:8891@localhost
PidFile /var/run/opendkim/opendkim.pid
SignatureAlgorithm rsa-sha256
KeyTable           /etc/opendkim/key.table
SigningTable       /etc/opendkim/signing.table
TrustedHosts       /etc/opendkim/trusted.hosts
EOF

cat > /etc/opendkim/trusted.hosts <<EOF
127.0.0.1
localhost
$DOMAIN
EOF

> /etc/opendkim/key.table
> /etc/opendkim/signing.table

for sub in "${SUBDOMAINS[@]}"; do
  mkdir -p /etc/opendkim/keys/$sub.$DOMAIN
  opendkim-genkey -D /etc/opendkim/keys/$sub.$DOMAIN/ -d $sub.$DOMAIN -s default
  chown -R opendkim:opendkim /etc/opendkim/keys/$sub.$DOMAIN
  echo "default._domainkey.$sub.$DOMAIN $sub.$DOMAIN:default:/etc/opendkim/keys/$sub.$DOMAIN/default.private" >> /etc/opendkim/key.table
  echo "*@$sub.$DOMAIN default._domainkey.$sub.$DOMAIN" >> /etc/opendkim/signing.table
done

usermod -aG opendkim postfix
postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 2"
postconf -e "smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"
postconf -e "non_smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"
systemctl enable opendkim
systemctl restart opendkim

# === OPENDMARC ===
cat > /etc/opendmarc.conf <<EOF
Syslog                  true
Socket                  inet:8893@localhost
PidFile                 /var/run/opendmarc/opendmarc.pid
UserID                  opendmarc:opendmarc
AuthservID              ${SUBDOMAINS[0]}.$DOMAIN
TrustedAuthservIDs      ${SUBDOMAINS[0]}.$DOMAIN
IgnoreAuthenticatedClients true
EOF
systemctl enable opendmarc
systemctl restart opendmarc

# === BIND9 ZONE ===
cat > /etc/bind/named.conf.local <<EOF
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
    allow-update { none; };
};
EOF

cat > /etc/bind/db.$DOMAIN <<EOF
\$TTL    3600
@       IN      SOA     ns1.$DOMAIN. admin.$DOMAIN. (
                        2025091201 ; Serial
                        3600       ; Refresh
                        1800       ; Retry
                        1209600    ; Expire
                        3600 )     ; Minimum TTL

        IN      NS      ns1.$DOMAIN.
ns1     IN      A       ${IPS[0]}

_dmarc  IN      TXT     "v=DMARC1; p=quarantine; rua=mailto:dmarc@$DOMAIN; ruf=mailto:dmarc@$DOMAIN; sp=none; adkim=s; aspf=s"
EOF

for i in "${!SUBDOMAINS[@]}"; do
  sub="${SUBDOMAINS[$i]}"
  ip="${IPS[$i]}"
  echo "$sub     IN      A       $ip" >> /etc/bind/db.$DOMAIN
  echo "$sub     IN      MX 10   $sub.$DOMAIN." >> /etc/bind/db.$DOMAIN
  echo "$sub     IN      TXT     \"v=spf1 a mx ip4:$ip ~all\"" >> /etc/bind/db.$DOMAIN
  DKIMTXT=$(cat /etc/opendkim/keys/$sub.$DOMAIN/default.txt | tr -d '\n' | sed 's/" "/ /g')
  echo "default._domainkey.$sub   IN  TXT   $DKIMTXT" >> /etc/bind/db.$DOMAIN
done

systemctl enable bind9
systemctl restart bind9

# === SSL WITH LET'S ENCRYPT (PER SUBDOMAIN) ===
for sub in "${SUBDOMAINS[@]}"; do
  certbot certonly --standalone -d $sub.$DOMAIN --agree-tos --non-interactive -m $EMAIL
done

# === ENABLE TLS FOR INBOUND SMTP (default cert: mail1) ===
postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/${SUBDOMAINS[0]}.$DOMAIN/fullchain.pem"
postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/${SUBDOMAINS[0]}.$DOMAIN/privkey.pem"
postconf -e "smtpd_use_tls=yes"
postconf -e "smtpd_tls_security_level=may"
postconf -e "smtp_tls_security_level=may"
postconf -e "smtpd_tls_auth_only=yes"
postconf -e "smtpd_tls_loglevel=1"
postconf -e "smtpd_tls_session_cache_database=btree:\${data_directory}/smtpd_scache"
postconf -e "smtp_tls_session_cache_database=btree:\${data_directory}/smtp_scache"

systemctl restart postfix

# === AUTO RENEWAL CRON ===
cat > /etc/cron.d/certbot-postfix <<EOF
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload postfix"
EOF

echo "[+] Setup complete!"
echo "========================================================="
echo "Postfix + DKIM + DMARC + BIND9 + SSL configured."
echo "Each subdomain has its own certificate and is bound in Postfix."
echo "Auto SSL renewal with Postfix reload scheduled daily at 3AM."
echo "========================================================="

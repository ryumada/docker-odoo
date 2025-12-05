#!/bin/bash

cat << 'EOF' > ~/01-sudo-nginx-security.conf
##
# Security Settings
##

# limit for web/login path
limit_req_zone $binary_remote_addr zone=limitweblogin:20m rate=5r/s;
limit_conn_zone $binary_remote_addr zone=addrweblogin:25m;

# limit for web/database* path
limit_req_zone $binary_remote_addr zone=limitwebdatabase:10m rate=30r/m;
limit_conn_zone $binary_remote_addr zone=addrwebdatabase:10m;

# these settings can impact ram usage of nginx the buffers saved on RAM
client_body_buffer_size         2k;
client_header_buffer_size       2k;
large_client_header_buffers     8 16k;

# Save the request body to a file which beneficial for handling large requests
client_body_in_file_only on;
client_body_temp_path /var/tmp/nginx;

# file upload can be received by nginx. If you have file upload feature with POST method
client_max_body_size            500M;

keepalive_timeout               2700s;
tcp_nodelay                     on;

# disable display nginx server version
server_tokens off;

# OCSP Stapling - improve SSL handshake performance and reduce server load
#ssl_stapling on;
#ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;

# clickjacking protection
add_header X-Frame-Options "SAMEORIGIN";

# prevent user from accepting insecure SSL certificates
add_header Strict-Transport-Security "max-age=31536000; includeSubdomains; preload" always;

# Instruct browser to strictly follow the Content-Type header specified in HTTP headers and not attempt to determine the type of contente by examining the content itself (XSS and Content Injection Protection).
add_header X-Content-Type-Options "nosniff";

# prevent the the destination site to know where the user came from which is useful because this Odoo deployment is a backoffice application
add_header Referrer-Policy "strict-origin-when-cross-origin";

# protect from certain types of attacks, including Cross-site Scripting (XSS) and data injection attacks [VERY RESTRICTIVE]
#add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

# xss protection for older browsers that don't support Content-Security-Policy [NOT USABLE IN MODERN BROWSER]
#add_header X-XSS-Protection "1; mode=block";

# [DEPRECATED not used anymore; use Wazuh instead] enable modsecurity on specific URL only. You can add it in login page or in database manager block
#modsecurity on;
#modsecurity_rules_file /etc/nginx/modsec/main.conf;

EOF

sudo chown root: ~/01-sudo-nginx-security.conf
sudo mv ~/01-sudo-nginx-security.conf /etc/nginx/conf.d/

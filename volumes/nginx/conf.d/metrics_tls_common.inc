ssl_dhparam /opt/letsencrypt/dhparam.pem;
ssl_prefer_server_ciphers on;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_certificate /opt/metrics-server.crt;
ssl_certificate_key /opt/metrics-server.key;
ssl_client_certificate /opt/metrics-ca.crt;
ssl_verify_client on;
ssl_verify_depth 2;

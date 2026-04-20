Files in this directory are intentionally kept in the public repository.

Layout:
- `metrics/ca.crt`: CA certificate trusted by nginx for Prometheus client cert verification.
- `metrics/server.crt`: server certificate presented by nginx on `9100`, `9200`, and `9300`.
- `metrics/server.key`: private key for the shared nginx metrics server certificate.
- `metrics/openssl/*.cnf`: certificate generation configs.
- `nginx-origin/fullchain.pem`, `nginx-origin/privkey.pem`, `nginx-origin/dhparam.pem`: origin TLS materials used by the nginx layout.

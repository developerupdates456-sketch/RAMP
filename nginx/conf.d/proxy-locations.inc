# The shared proxy body.
#
# Included by BOTH the plain-HTTP server in proxy.conf and the HTTPS server in
# tls.conf, so the two can never drift apart.
#
# This file exists because splitting TLS out of proxy.conf (it has to live in
# its own file -- a `listen 443 ssl` block naming a certificate that does not
# exist is a fatal start-up error) initially left the HTTP server with a single
# catch-all `location /`. That silently broke every API route: /api/health,
# /admin/, /uploads/ and /ws/ were all proxied to the frontend instead of the
# API, so the health check failed and the app was unusable over plain HTTP.
#
# REDIRECT_HTTP_TO_HTTPS gates the behaviour of `location /` only:
#
#   absent (or empty) -> serve the app over plain HTTP, which is the state a
#                        fresh install is in, because HTTPS is not listening yet
#                        and redirecting to it would send every browser to a
#                        dead port
#   present           -> return 301 to https, which is correct once tls.conf
#                        exists
#
# scripts/domain-ssl-apply.sh creates that file when it enables TLS. It is
# empty on purpose: nginx only cares that the file exists, and an empty file
# keeps this include free of directive duplication.

# {{ REDIRECT_HTTP_TO_HTTPS }}

location /health {
    access_log off;
    return 200 "healthy\n";
    add_header Content-Type text/plain;
}

location /api/ {
    # Raised from the 64M default because this location carries the bulk
    # device/room upload endpoints. Kept at 256M: the upload code streams and
    # the app enforces its own per-endpoint ceiling, so a larger value here
    # would only widen the memory a single request can pin.
    client_max_body_size 256M;
    proxy_pass $api_upstream$request_uri;
    include /etc/nginx/conf.d/proxy-headers.conf;
    limit_req zone=api_limit burst=50 nodelay;
    proxy_connect_timeout 60s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
}

location ~ ^/admin/(dashboard|login|signup) {
    proxy_pass $frontend_upstream$request_uri;
    include /etc/nginx/conf.d/proxy-headers.conf;
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
}

location /admin/ {
    # admin-allowlist.conf should contain `allow <cidr>; ... deny all;`
    # (empty by default = open, suitable for local; populate in prod).
    include /etc/nginx/conf.d/admin-allowlist.conf;
    proxy_pass $api_upstream$request_uri;
    include /etc/nginx/conf.d/proxy-headers.conf;
    proxy_connect_timeout 120s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;
}

location /uploads/ {
    proxy_pass $api_upstream$request_uri;
    include /etc/nginx/conf.d/proxy-headers.conf;
    proxy_read_timeout 120s;
}

location /ws/ {
    proxy_pass $api_upstream$request_uri;
    # proxy_http_version and the Connection/Upgrade pair: Connection is set
    # here, and Upgrade/Connection by proxy-headers.conf. proxy_http_version
    # is deliberately NOT repeated -- nginx rejects a directive that appears
    # twice in one context ("directive is duplicate"), and it is already in
    # the shared header below.
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    include /etc/nginx/conf.d/proxy-headers.conf;
    # Socket.IO long-polling falls back here, so the read timeout has to
    # outlast the client's ping interval or connections drop mid-session.
    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}

location /static/ {
    proxy_pass $frontend_upstream$request_uri;
    expires 30d;
    add_header Cache-Control "public, immutable";
}

location / {
    # Redirect only when TLS is actually listening; otherwise serve, so a
    # cert-less install is reachable. See the note at the top of this file.
    include /etc/nginx/conf.d/redirect-http-to-https.conf;

    proxy_pass $frontend_upstream$request_uri;
    # No proxy_http_version here -- it comes from proxy-headers.conf below.
    # Setting it in both places is a fatal start-up error, not a warning.
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    include /etc/nginx/conf.d/proxy-headers.conf;
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
}

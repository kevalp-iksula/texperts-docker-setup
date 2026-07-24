# syntax=docker/dockerfile:1
################################################################################
# Nginx for Adobe Commerce 2.4.9
# Config is bind-mounted at runtime, so edits apply with `make nginx-reload`
# instead of a rebuild.
################################################################################
FROM nginx:1.27-alpine

# curl backs the container healthcheck; the alpine base does not ship it.
RUN apk add --no-cache curl tzdata

RUN mkdir -p /var/cache/nginx /var/www/magento

EXPOSE 80 443

STOPSIGNAL SIGQUIT

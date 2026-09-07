FROM nginxinc/nginx-unprivileged:1.31.5-alpine

USER root

RUN rm -f /etc/nginx/conf.d/default.conf

COPY --chown=nginx:nginx infra/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chown=nginx:nginx infra/nginx/templates/ /etc/nginx/runtime-templates/
COPY --chown=nginx:nginx --chmod=755 infra/nginx/entrypoint.sh /usr/local/bin/competency-trainer-nginx-entrypoint
COPY --chown=nginx:nginx --chmod=755 infra/nginx/healthcheck.sh /usr/local/bin/competency-trainer-nginx-healthcheck

USER nginx

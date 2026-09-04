FROM node:26.7.0-alpine AS builder
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM node:26.7.0-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production

RUN apk add --no-cache --upgrade libcrypto3=3.5.7-r0 libssl3=3.5.7-r0

COPY package*.json ./
RUN npm ci --omit=dev \
 && npm cache clean --force \
 && rm -rf /root/.npm /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx \
 && chown -R node:node /app

COPY --from=builder --chown=node:node /app/dist/competency-trainer-frontend ./dist/competency-trainer-frontend

USER node
EXPOSE 4000
CMD ["node", "dist/competency-trainer-frontend/server/server.mjs"]

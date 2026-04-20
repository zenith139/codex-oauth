FROM node:20-bookworm-slim

RUN npm install -g @openai/codex @zenith139/codex-oauth

ENV CODEX_HOME=/home/codex/.codex
ENV PATH=/home/codex/.npm-global/bin:${PATH}

RUN mkdir -p /home/codex/.codex

COPY runtime /opt/codex-oauth/runtime
RUN NPM_ROOT="$(npm root -g)" \
  && mkdir -p "${NPM_ROOT}/@zenith139/codex-oauth/runtime" \
  && cp -f /opt/codex-oauth/runtime/*.mjs "${NPM_ROOT}/@zenith139/codex-oauth/runtime/"
COPY docker/entrypoint.sh /usr/local/bin/codex-oauth-entrypoint
RUN chmod +x /usr/local/bin/codex-oauth-entrypoint

USER root
WORKDIR /home/codex

EXPOSE 4318
EXPOSE 1455

ENTRYPOINT ["/usr/local/bin/codex-oauth-entrypoint"]

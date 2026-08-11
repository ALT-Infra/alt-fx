FROM --platform=linux/amd64 fx-evals:local

WORKDIR /app

RUN mkdir -p /app/src \
    && printf 'export const API_URL = "https://example.com";\n' > /app/src/config.ts \
    && printf 'export const token = "SECRET_TOKEN_42";\n' > /app/src/auth.ts \
    && printf 'export function helper() { return 1; }\n' > /app/src/utils.ts \
    && printf '# My Project\n' > /app/README.md \
    && chown -R agent:agent /app

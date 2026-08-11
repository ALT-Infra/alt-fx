FROM --platform=linux/amd64 fx-evals:local

WORKDIR /app

RUN printf '%s\n' \
    '{' \
    '  "name": "my-app",' \
    '  "port": 3000,' \
    '  "debug": false,' \
    '  "logLevel": "info"' \
    '}' \
    > /app/config.json \
    && chown agent:agent /app/config.json

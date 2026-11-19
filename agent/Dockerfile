FROM python:3.12.16-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY gforcex_agent/ /app/agents/gforcex_agent/
COPY tests/ /app/tests/

# Least privilege: run as an unprivileged user with no home-directory writes.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin agent \
    && mkdir -p /var/log/gforcex \
    && chown 10001:10001 /var/log/gforcex \
    && chmod 0700 /var/log/gforcex
USER 10001
ENV HOME=/tmp PYTHONPATH=/app/agents

# Authenticated OpenAI-compatible API for Open WebUI (gforcex_agent/openai_api.py). Internal Docker
# networks only; compose publishes no host port.
EXPOSE 8000
CMD ["python", "-m", "gforcex_agent.openai_api"]

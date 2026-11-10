FROM python:3.12.12-slim

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
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin agent
USER 10001
ENV HOME=/tmp PYTHONPATH=/app/agents

# Listens only on the internal Docker network (no host port is published in compose).
EXPOSE 8000
CMD ["adk", "api_server", "--host", "0.0.0.0", "--port", "8000", "/app/agents"]

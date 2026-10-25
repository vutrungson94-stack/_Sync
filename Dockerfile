# Minimal reproducible container for _Sync.
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
COPY . /repo

# Smoke-test the harness entry point.
CMD ["pwsh", "-NoProfile", "-NonInteractive", "-File", "./gsync.ps1", "-SelfTest"]
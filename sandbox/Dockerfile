FROM docker/sandbox-templates:shell

USER root

# System deps (works fine under QEMU for both arches)
RUN apt-get update -qq && \
    apt-get install -y -qq build-essential python3 >/dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/*

USER agent

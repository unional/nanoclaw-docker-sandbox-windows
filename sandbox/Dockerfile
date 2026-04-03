FROM docker/sandbox-templates:shell

USER root

# System deps (works fine under QEMU for both arches)
RUN apt-get update -qq && \
    apt-get install -y -qq build-essential python3 >/dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/*

USER agent

# Copy scripts and plugin (fix line endings)
COPY --chown=agent:agent nanoclaw-init.sh /home/agent/nanoclaw-init.sh
COPY --chown=agent:agent sandbox-patch.sh /home/agent/sandbox-patch.sh
COPY --chown=agent:agent docker-plugin/ /home/agent/docker-plugin/
RUN sed -i 's/\r$//' /home/agent/nanoclaw-init.sh /home/agent/sandbox-patch.sh && \
    chmod +x /home/agent/nanoclaw-init.sh

USER root
RUN ln -sf /home/agent/nanoclaw-init.sh /usr/local/bin/nanoclaw-init
USER agent

# Auto-init on first login
RUN echo '' >> /home/agent/.bash_profile && \
    echo '# NanoClaw auto-setup on first login' >> /home/agent/.bash_profile && \
    echo 'if [[ ! -f "$HOME/.nanoclaw-initialized" ]]; then' >> /home/agent/.bash_profile && \
    echo '  nanoclaw-init' >> /home/agent/.bash_profile && \
    echo 'fi' >> /home/agent/.bash_profile

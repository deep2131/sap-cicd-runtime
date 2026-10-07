FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    bash \
    curl \
    jq \
    unzip \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pipeline

COPY scripts/ /pipeline/scripts/

RUN chmod +x /pipeline/scripts/*.sh

ENV PATH="/pipeline/scripts:${PATH}"

CMD ["bash"]

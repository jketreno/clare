FROM ubuntu:26.04

ARG GOLANG_VERSION=1.22.9
ENV DEBIAN_FRONTEND=noninteractive \
    GOLANG_VERSION=${GOLANG_VERSION} \
    GOPATH=/home/tester/go \
    PATH=/usr/local/go/bin:/home/tester/go/bin:/home/tester/.local/bin:/work/bin:$PATH

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release build-essential git unzip \
    python3 python3-venv python3-setuptools python3-pip \
  && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS (20.x)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get update && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

# Install Go (architecture derived from the build platform)
RUN goarch="$(dpkg --print-architecture)" \
  && curl -fsSL "https://go.dev/dl/go${GOLANG_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tar.gz \
  && tar -C /usr/local -xzf /tmp/go.tar.gz \
  && rm /tmp/go.tar.gz

# Install pipx for isolated CLI installs
RUN python3 -m pip install --upgrade pip setuptools wheel \
  && python3 -m pip install --no-cache-dir pipx \
  && python3 -m pipx ensurepath || true

# Create non-root user and prepare workdir
RUN useradd -ms /bin/bash tester \
  && mkdir -p /home/tester/go /work /home/tester/.local/bin \
  && chown -R tester:tester /home/tester /work \
  && chmod 0777 /work

WORKDIR /work

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER tester

ENV HOME=/home/tester
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

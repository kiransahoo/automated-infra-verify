# Use a minimal base image that supports multiple architectures
FROM ubuntu:22.04

# Install necessary packages for connectivity testing
RUN apt-get update && apt-get install -y \
    curl \
    dnsutils \
    iputils-ping \
    netcat-openbsd \
    traceroute \
    tcpdump \
    telnet \
    wget \
    nmap \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Set a working directory
WORKDIR /app

# Create a simple script to verify the container is working
RUN echo '#!/bin/bash\necho "Connectivity test container is running successfully"\necho "Architecture: $(uname -m)"\necho "OS: $(uname -s)"\n' > /app/test.sh && \
    chmod +x /app/test.sh

# Run a long sleep by default to keep the container running
CMD ["sleep", "3600"]
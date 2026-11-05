# Printer Hub home bridge for a NAS / Raspberry Pi.
# The release workflow publishes this as ghcr.io/<owner>/printer-hub-bridge
# for amd64 and arm64. To build it yourself, first compile the binary:
#   dart compile exe --target-os linux --target-arch x64 bin/bridge.dart \
#     -o build/printer-hub-bridge-linux-amd64
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Set by Docker/BuildKit to the platform being built (amd64, arm64).
ARG TARGETARCH=amd64
COPY build/printer-hub-bridge-linux-${TARGETARCH} /usr/local/bin/printer-hub-bridge
# Files uploaded through a NAS web UI often lose their executable bit.
RUN chmod 755 /usr/local/bin/printer-hub-bridge
ENV BRIDGE_DATA=/data
VOLUME /data
ENTRYPOINT ["/usr/local/bin/printer-hub-bridge"]

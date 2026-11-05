# Printer Hub home bridge for a NAS / Raspberry Pi.
# Uses the prebuilt Linux binary (build/printer-hub-bridge-linux-<arch>),
# made on any computer with:
#   dart compile exe --target-os linux --target-arch x64 bin/bridge.dart \
#     -o build/printer-hub-bridge-linux-x64
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG ARCH=x64
COPY build/printer-hub-bridge-linux-${ARCH} /usr/local/bin/printer-hub-bridge
ENV BRIDGE_DATA=/data
VOLUME /data
ENTRYPOINT ["/usr/local/bin/printer-hub-bridge"]

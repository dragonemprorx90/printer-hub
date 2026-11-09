# Printer Hub slicer: OrcaSlicer's command line for the home bridge.
# Published as ghcr.io/<owner>/printer-hub-slicer for amd64 and arm64.
#   docker build -t printer-hub-slicer slicer
FROM ubuntu:24.04
ARG TARGETARCH=amd64
ARG ORCA_VERSION=2.5.0
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 python3-gmsh xvfb xauth \
      libgtk-3-0t64 libwebkit2gtk-4.1-0 libgl1 libegl1 libglu1-mesa libosmesa6 \
      libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libsecret-1-0 \
 && rm -rf /var/lib/apt/lists/*
# The AppImage, unpacked (no FUSE in containers).
RUN arch=$([ "$TARGETARCH" = arm64 ] && echo _aarch64 || true) \
 && curl -fsSL -o /tmp/orca.AppImage \
      "https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${ORCA_VERSION}/OrcaSlicer_Linux_AppImage_Ubuntu2404${arch}_V${ORCA_VERSION}.AppImage" \
 && chmod +x /tmp/orca.AppImage && cd /opt \
 && /tmp/orca.AppImage --appimage-extract >/dev/null \
 && mv squashfs-root orca && rm /tmp/orca.AppImage \
 && mkdir -p /opt/orca-data/system /opt/orca-data/user/default \
 && for v in Creality Snapmaker OrcaFilamentLibrary Custom; do \
      cp "/opt/orca/resources/profiles/$v.opc" /opt/orca-data/system/; done \
 && missing=$(LD_LIBRARY_PATH=/opt/orca/lib:/opt/orca/usr/lib ldd /opt/orca/bin/orca-slicer | grep 'not found' || true) \
 && if [ -n "$missing" ]; then echo "Missing libraries:"; echo "$missing"; exit 1; fi
COPY server.py test_server.py /app/
ENV ORCA="xvfb-run -a /opt/orca/AppRun" ORCA_DATA=/opt/orca-data PYTHONUNBUFFERED=1
# Your own presets, exported from desktop Orca: mount a folder here.
VOLUME /opt/orca-data/user/default
ENTRYPOINT ["python3", "/app/server.py"]

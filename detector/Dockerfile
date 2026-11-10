# syntax=docker/dockerfile:1
# Printer Hub failure detector (spaghetti detection) for the home bridge.
# Published as ghcr.io/<owner>/printer-hub-detector for amd64 and arm64.
#   docker build -t printer-hub-detector detector
FROM python:3.12-slim
RUN pip install --no-cache-dir onnxruntime==1.22.1 numpy==2.2.6 pillow==11.3.0
# Obico's open failure-detection model (AGPL-3.0, github.com/TheSpaghettiDetective/obico-server).
ARG MODEL_URL=https://www.obico.io/static_pub/ml-models/model-weights-5a6b1be1fa.onnx
ARG MODEL_SHA256=0a6ebd8e30dbf6a450c50f9c0a5406f04ba7eb1c99fd5996e888c78bb383b9aa
ADD --checksum=sha256:${MODEL_SHA256} ${MODEL_URL} /app/model.onnx
COPY server.py test_server.py /app/
COPY testdata /app/testdata
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python3", "/app/server.py"]

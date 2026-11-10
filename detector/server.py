#!/usr/bin/env python3
"""Printer Hub failure detector: is there spaghetti in this camera frame?

POST /detect with a JPEG body -> {"score": 0.93, "boxes": [[x, y, w, h, conf], ...]}
GET  /health                  -> {"ok": true}

The model is Obico's (The Spaghetti Detective) open failure detector, a
YOLO net with one class, "failure", run on the CPU with ONNX Runtime. The
score is the sum of box confidences, as Obico's server computes it; the home
bridge smooths it over several frames and decides when to alert.

The bridge reads the frames (it already holds each printer's camera and
knows when a print runs) and posts them here, so this service keeps no state
and serves every printer on the machine. 127.0.0.1 only.
"""
import io
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

import numpy as np
import onnxruntime
from PIL import Image

MODEL = os.environ.get("MODEL", "/app/model.onnx")
PORT = int(os.environ.get("DETECTOR_PORT", "7072"))
BOX_THRESH = 0.08  # a box counts from this confidence (Obico's ml_api THRESH)
NMS = 0.45

_session = None
_lock = Lock()  # ponytail: one frame at a time; a few frames a minute fits easily


def session():
    global _session
    if _session is None:
        opts = onnxruntime.SessionOptions()
        # A NAS does other work too, so two threads by default.
        opts.intra_op_num_threads = int(os.environ.get("THREADS", "2"))
        _session = onnxruntime.InferenceSession(MODEL, opts, providers=["CPUExecutionProvider"])
    return _session


def _nms(boxes, confs):
    x1, y1, x2, y2 = boxes.T
    areas = (x2 - x1) * (y2 - y1)
    order, keep = confs.argsort()[::-1], []
    while order.size:
        i, rest = order[0], order[1:]
        keep.append(i)
        w = np.maximum(0, np.minimum(x2[i], x2[rest]) - np.maximum(x1[i], x1[rest]))
        h = np.maximum(0, np.minimum(y2[i], y2[rest]) - np.maximum(y1[i], y1[rest]))
        inter = w * h
        order = rest[inter / (areas[i] + areas[rest] - inter + 1e-9) <= NMS]
    return keep


def detect(jpeg: bytes):
    """Failure boxes in a frame: [(x, y, w, h, conf)], centre and size as fractions."""
    s = session()
    _, _, h, w = s.get_inputs()[0].shape
    img = Image.open(io.BytesIO(jpeg)).convert("RGB").resize((w, h), Image.BILINEAR)
    x = np.asarray(img, dtype=np.float32).transpose(2, 0, 1)[None] / 255.0
    with _lock:
        boxes, confs = s.run(None, {s.get_inputs()[0].name: x})
    boxes, confs = boxes[0, :, 0, :], confs[0, :, 0]
    keep = confs > BOX_THRESH
    boxes, confs = boxes[keep], confs[keep]
    out = []
    for i in _nms(boxes, confs):
        b = boxes[i]
        out.append((float((b[0] + b[2]) / 2), float((b[1] + b[3]) / 2),
                    float(b[2] - b[0]), float(b[3] - b[1]), float(confs[i])))
    return out


def score(jpeg: bytes):
    boxes = detect(jpeg)
    return {"score": round(sum(b[4] for b in boxes), 3), "boxes": [[round(v, 3) for v in b] for b in boxes]}


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"ok": True})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/detect":
            return self._json(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length") or 0)
        if not 0 < n <= 20_000_000:
            return self._json(400, {"error": "send one JPEG frame"})
        try:
            self._json(200, score(self.rfile.read(n)))
        except Exception as e:  # a broken frame must not stop the service
            self._json(400, {"error": f"not a picture: {e}"})

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    session()  # load now, so a bad model fails at start
    print(f"Failure detector ready on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

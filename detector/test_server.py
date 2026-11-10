"""Sample frames through the real model: python3 test_server.py

testdata/failure.jpg: "Spaghetti monster" by A7N8X, Wikimedia Commons, CC0.
testdata/ok-u1.jpg: a Snapmaker U1 mid-job; its purge bin full of tangled
scraps must not count as a failure.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testdata")


def frame(name):
    with open(os.path.join(here, name), "rb") as f:
        return f.read()


fail = server.score(frame("failure.jpg"))
ok = server.score(frame("ok-u1.jpg"))
print("failure:", fail["score"], "ok:", ok["score"])
assert fail["score"] > 1.0 and fail["boxes"], fail
assert ok["score"] < 0.3, ok
try:
    server.score(b"not a jpeg")
    raise SystemExit("a broken frame should raise")
except Exception:
    pass
print("ok")

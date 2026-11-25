# syntax=docker/dockerfile:1
# The PUBLIC fass image: fully code-stripped, Cython-compiled.
#
# Base = the shipped runtime (CUDA ffmpeg 9.0.2 + libvmaf + tsduck + bento4
# + the /opt/venv dependency set), pinned to the very release the wheel
# below was compiled from (v1.618033.3cef051). This layer adds ONLY the
# compiled wheel and then removes every readable source:
#   * site-packages: the source-bearing `pip install .` of the base is
#     uninstalled, and fass is reinstalled from the wheel (.py=0, .so=41);
#   * /work/fass + build/ + egg-info (the .py/.c tree baked by the dev
#     build) are deleted — the server then imports compiled modules only.
# Nothing else changes: entrypoint, CMD (`fass serve ...` console script,
# which the wheel provides), ports, volumes and the reported version are
# identical to the base release.
#
# Build from the REPO ROOT (the wheel lives in wheel/):
#   docker build -f docker/Dockerfile -t boris271142/fass:stripped .
# Proof of stripping after any rebuild (both counts must be 0):
#   docker run --rm --entrypoint sh <tag> -c \
#     'find / -xdev -path /proc -prune -o -name "*.py" -path "*fass*" -print | wc -l
#      find /work -name "*.c" 2>/dev/null | wc -l'
FROM boris271142/fass:v1.618033.3cef051

# NB: keep the wheel's ORIGINAL filename — pip rejects a renamed .whl
# ("not a valid wheel filename"), so it lands in /tmp/ under its own name.
COPY wheel/fass-0.1.0-cp312-cp312-linux_x86_64.whl /tmp/
RUN /opt/venv/bin/pip uninstall -y fass \
    && /opt/venv/bin/pip install --no-cache-dir --no-deps /tmp/fass-0.1.0-cp312-cp312-linux_x86_64.whl \
    && rm -rf /work/fass /work/build /work/fass.egg-info /tmp/fass-0.1.0-*.whl \
    && /opt/venv/bin/python - <<'PYCHECK'
import importlib.util, pathlib
origin = pathlib.Path(importlib.util.find_spec("fass").origin)
assert origin.suffix == ".so" and ".cpython-312" in origin.name, \
    f"image is NOT stripped: fass resolves to {origin}"
print("dockerfile check: fass resolves to", origin)
PYCHECK

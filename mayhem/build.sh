#!/usr/bin/env bash
#
# mayhem/build.sh — build the python-qrcode Atheris fuzz harness + its standalone reproducer,
# and prepare the project's own test suite. Runs inside the commit image (mayhem/Dockerfile)
# as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + pytest + the qrcode runtime/test deps (deprecation, pypng, pillow)
#      OFFLINE from that wheelhouse into a fixed site dir on PYTHONPATH. The first (CI, online)
#      build fills the wheelhouse; the air-gapped PATCH re-run resolves entirely from it
#      (pip --no-index --find-links). qrcode itself is exercised as its editable source tree
#      (repo root on PYTHONPATH), so a PATCH agent's edits take effect with no reinstall.
#   2. Compile launcher.c -> the ELF Mayhem target `qrcode_fuzzer` (Atheris is a Python
#      script; Mayhem needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper).
#   3. Build the same launcher as the standalone (run-once) reproducer `qrcode_fuzzer-standalone`.
#   4. Compile the pytest ELF runner wrapper `qrcode_run_tests` (so the sabotage oracle bites).
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). We only need
# DEBUG_FLAGS here (the launcher is a thin C exec wrapper — sanitizing it would just instrument
# the wrapper, not the fuzzed Python; Atheris instruments the qrcode library itself at import time).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

# 1) Wheelhouse: download every runtime/test dependency ONCE (online). On the air-gapped re-run
#    the directory is already populated, so pip never reaches the network. atheris ships a
#    prebuilt manylinux wheel for this CPython. deprecation is qrcode's runtime dep; pypng +
#    pillow are the optional renderers the test suite exercises.
PKGS=(atheris pytest deprecation pypng "pillow>=9.1.0" "poetry-core>=2")
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). Idempotent: once
#    the site dir holds atheris+pytest+pillow we SKIP the reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','pytest*')) and glob.glob(os.path.join('$SITE','PIL'))) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi

# qrcode is a top-level package at the repo root, so the repo root itself goes on PYTHONPATH.
# The console script + tests also need the package's dist METADATA (importlib.metadata), so
# register an EDITABLE install into a fixed prefix: the dist-info lands under $PROJ_SITE while
# the code keeps resolving from the $SRC source tree (PATCH edits take effect, no reinstall).
PYVER="$("$PY" -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
PROJ_SITE="$PY_PREFIX/proj/local/lib/python$PYVER/dist-packages"  # Ubuntu pip posix_local scheme
if ls "$PROJ_SITE"/qrcode-*.dist-info >/dev/null 2>&1; then
  echo ">> qrcode dist metadata already registered in $PROJ_SITE — skipping (idempotent re-run)"
else
  echo ">> registering qrcode editable dist metadata (offline) into $PROJ_SITE"
  PYTHONPATH="$SITE" "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" \
      --no-build-isolation --no-deps --prefix "$PY_PREFIX/proj" -e "$SRC"
fi

PYRUN="$SITE:$PROJ_SITE:$SRC"

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, qrcode, pytest, png, PIL, deprecation; from importlib.metadata import version; print("imports OK: qrcode", version("qrcode"))'

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits
#    at run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + qrcode.
HARNESS="$SRC/mayhem/fuzz_gen.py"
echo ">> compiling qrcode_fuzzer (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/qrcode_fuzzer"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when
# the harness is given a file path (no fuzzing loop) — the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/qrcode_fuzzer-standalone"

# 4) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's
#    anti-reward-hack sabotage check (which neuters non-system binaries to exit(0)) actually
#    bites the suite — a test.sh that shelled straight to /usr/bin python would be spared.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/qrcode_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/qrcode_fuzzer" "$SRC/qrcode_fuzzer-standalone" "$SRC/qrcode_run_tests"

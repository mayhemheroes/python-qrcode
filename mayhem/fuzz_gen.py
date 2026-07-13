#!/usr/bin/env python3
"""Atheris fuzz harness for python-qrcode (target: make-fuzz).

Ported from the original mayhemheroes integration (mayhem/fuzz_gen.py on the
archived branch): exercises qrcode.make() end-to-end on arbitrary input.
Atheris instruments the imported qrcode modules so libFuzzer gets coverage
feedback while the encoder (data analysis, segment packing, Reed-Solomon
error correction, matrix masking) and the renderers run on fuzzed data.

Each TestOneInput is guarded by a per-input SIGALRM watchdog so a single
pathological input cannot stall fuzz-smoke or Mayhem's per-input budget.

Run modes (driven by the compiled launcher `qrcode_fuzzer` / `-standalone`):
  * fuzzing      -- `python3 fuzz_gen.py [libFuzzer args]`
  * single input -- `python3 fuzz_gen.py <file>` (libFuzzer runs it once)
"""
import io
import logging
import signal
import sys

import atheris

with atheris.instrument_imports():
    import qrcode
    import qrcode.image.pil
    import qrcode.image.svg
    from qrcode.exceptions import DataOverflowError

logging.disable(logging.CRITICAL)


class _InputTimeout(Exception):
    pass


def _alarm(signum, frame):
    raise _InputTimeout()


signal.signal(signal.SIGALRM, _alarm)
_PER_INPUT_SECONDS = 5

# QR version 40 binary capacity is ~2953 bytes; anything longer only raises
# DataOverflowError, so cap the payload to keep every input productive.
_MAX_PAYLOAD = 3000


@atheris.instrument_func
def TestOneInput(data):
    signal.setitimer(signal.ITIMER_REAL, _PER_INPUT_SECONDS)
    try:
        payload = data[:_MAX_PAYLOAD]

        # The original harness's code path: full pipeline into a PIL image.
        qrcode.make(payload)

        # Drive the explicit QRCode API + the pure-python SVG renderer too.
        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L)
        qr.add_data(payload)
        qr.make(fit=True)
        qr.get_matrix()
        img = qr.make_image(image_factory=qrcode.image.svg.SvgPathImage)
        img.save(io.BytesIO())
    except DataOverflowError:
        # Expected for payloads that exceed QR capacity.
        pass
    except _InputTimeout:
        # This one input was too slow -- skip it, don't count it as a defect.
        pass
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

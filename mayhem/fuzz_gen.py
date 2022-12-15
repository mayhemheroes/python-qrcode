#!/usr/bin/python3
import atheris
import logging
import sys

with atheris.instrument_imports():
    import qrcode

# No logging
logging.disable(logging.CRITICAL)

error_correction_opts = [qrcode.constants.ERROR_CORRECT_L,
                         qrcode.constants.ERROR_CORRECT_M,
                         qrcode.constants.ERROR_CORRECT_Q,
                         qrcode.constants.ERROR_CORRECT_H]


@atheris.instrument_func
def TestOneInput(data):
    img = qrcode.make(data)

    # fdp = atheris.FuzzedDataProvider(data)
    # qr = qrcode.QRCode(
    #     version=fdp.ConsumeIntInRange(1, 40),
    #     error_correction=error_correction_opts[fdp.ConsumeIntInRange(0, 3)],
    #     box_size=fdp.ConsumeIntInRange(1, 100),
    #     border=fdp.ConsumeIntInRange(0, 100),
    # )
    # qr.add_data(fdp.ConsumeBytes(atheris.ALL_REMAINING - 1))
    # qr.make(fit=fdp.ConsumeBool())
    #
    # img = qr.make_image(fill_color="black", back_color="white")
    # img = qrcode.make(data)


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

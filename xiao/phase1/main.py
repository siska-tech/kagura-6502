# KAGURA-6502 Phase 1 - XIAO RP2040 reset supervisor (MicroPython)
#
# STATUS: written against the Phase 1 FPGA status-frame format; NOT yet run on
# hardware. Only a CPython syntax check has been done.
#
# Wiring (docs/pinmap.md):
#   D0 / GPIO26 -> W65C02S RESB  (10k pull-down on the carrier)
#   D1 / GPIO27 -> W65C02S NMIB  (4.7k pull-up to CPU VDD; driven open-drain)
#   D7 / GPIO1  <- FPGA xiao_tx  (status frames, 115200 8N1)
#   D6 / GPIO0  -> FPGA xiao_rx  (unused by the Phase 1 FPGA image)
#
# Behaviour:
#   HOLD : RESB low. Wait for 2 consecutive valid frames with READY (S bit1).
#          READY means the FPGA is configured, its PLL is locked, BSRAM (bitstream-
#          initialised) is available and PHI2 has been running for >= 256 cycles,
#          so the W65C02S "RESB low for >= 2 PHI2 cycles" rule is already met.
#   RUN  : RESB high. If no valid frame for FRAME_TIMEOUT_MS (FPGA lost or being
#          reconfigured) -> RESB low, back to HOLD.
#   USB console commands: r = reset pulse, n = NMI pulse, h = hold, g = go.
from machine import Pin, UART
import select
import sys
import time

# --- make the control pins safe FIRST -----------------------------------------
# RP2040 GPIOs come out of reset as inputs with ~50-80k pull-downs.
NMIB = Pin(27, Pin.IN, pull=None)          # release; ext. 4.7k pull-up holds it high
RESB = Pin(26, Pin.OUT, value=0)           # hold the CPU in reset

FRAME_TIMEOUT_MS = 100                     # FPGA sends a frame every ~14 ms
READY_FRAMES = 2


def nmi_pulse():
    NMIB.init(Pin.OUT, value=0)
    time.sleep_us(20)
    NMIB.init(Pin.IN, pull=None)


def reset_hold():
    RESB.value(0)


def reset_release():
    RESB.value(1)


def frame_status(line):
    """Return the S byte of a valid 'K65 ...*xx' frame, or None."""
    if len(line) != 56 or not line.startswith("K65 ") or line[53] != "*":
        return None
    try:
        if (sum(line[:53].encode()) & 0xFF) != int(line[54:56], 16):
            return None
        return int(line[6:8], 16)
    except ValueError:
        return None


# --- do not drive TX into an unpowered FPGA: wait until its TX idles high -------
# With a pull-down, an unpowered FPGA reads low; a configured FPGA drives its UART
# TX high when idle (frames are ~5 ms long, gaps ~9 ms). Require 5 ms of continuous
# high before enabling our TX pin.
rx_probe = Pin(1, Pin.IN, pull=Pin.PULL_DOWN)
t0 = time.ticks_ms()
while time.ticks_diff(time.ticks_ms(), t0) < 5:
    if rx_probe.value() == 0:
        t0 = time.ticks_ms()

uart = UART(0, baudrate=115200, tx=Pin(0), rx=Pin(1), timeout=0)
poll = select.poll()
poll.register(sys.stdin, select.POLLIN)

state = "HOLD"
ready_count = 0
last_ok = time.ticks_ms()
buf = b""
manual_hold = False
print("K65 supervisor: HOLD (waiting for FPGA READY)")

while True:
    # ---- FPGA status frames ----
    data = uart.read()
    if data:
        buf += data
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = raw.decode("ascii", "replace").strip()
            st = frame_status(line)
            if st is None:
                if line:
                    print("?? " + line)
                continue
            print(line)
            last_ok = time.ticks_ms()
            if state == "HOLD":
                ready_count = ready_count + 1 if (st & 0x02) else 0
                if ready_count >= READY_FRAMES and not manual_hold:
                    time.sleep_ms(10)
                    reset_release()
                    state = "RUN"
                    print("K65 supervisor: RESB released")
        if len(buf) > 256:
            buf = b""

    # ---- watchdog on the FPGA link ----
    if state == "RUN" and time.ticks_diff(time.ticks_ms(), last_ok) > FRAME_TIMEOUT_MS:
        reset_hold()
        state, ready_count = "HOLD", 0
        print("K65 supervisor: FPGA frames lost -> RESB held")

    # ---- USB console commands ----
    if poll.poll(0):
        c = sys.stdin.read(1)
        if c == "r":
            reset_hold()
            state, ready_count = "HOLD", 0
            print("K65 supervisor: reset (waiting for READY)")
        elif c == "n":
            nmi_pulse()
            print("K65 supervisor: NMI")
        elif c == "h":
            manual_hold = True
            reset_hold()
            state, ready_count = "HOLD", 0
            print("K65 supervisor: HOLD (manual)")
        elif c == "g":
            manual_hold = False
            print("K65 supervisor: auto-release enabled")

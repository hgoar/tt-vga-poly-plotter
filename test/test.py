# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# cocotb tests for the VGA polynomial plotter.
#
# The chip draws y = A*x^2 + B*x + C at 1 unit per pixel, with the origin at the
# centre of the 640 x 480 screen. A, B and C are loaded over a UART on ui[7] and
# stored in Q5.3 fixed point (real value x 8); after reset they are 3, -5 and 2.
#
#   test_hsync               HSync pulses every 800 clocks and lasts 96 clocks
#   test_axes_and_grid       line 1 has one 2-pixel white axis and grey grid lines
#                            every 64 pixels either side of it
#   test_curve_first_row     the first row the curve reaches is green in exactly
#                            the columns the model predicts
#   test_curve_frame         every green pixel on a whole frame matches the model
#   test_coefficients        A, B, C loaded over the UART give the right curve,
#                            for a range of coefficients; saves each frame as the
#                            chip drew it on its output pins
#
# The first three only look at the output pins, so they also run on the
# gate-level (hardened) chip. The last two use internal signals or take too long
# at gate level, so they are skipped there (the Makefile sets GATES=yes).

import os
import struct
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

GATE_LEVEL = os.environ.get("GATES") == "yes"

# ---------------------------------------------------------------------------
# Pins, colours and timing
# ---------------------------------------------------------------------------
# uo_out = {hsync, B0, G0, R0, vsync, B1, G1, R1}
HSYNC  = 0x80          # active low
VSYNC  = 0x08          # active low
COLOUR = 0x77          # the six colour bits
WHITE  = 0x77          # RGB 11 11 11: axes and ticks
GREY   = 0x70          # RGB 01 01 01: grid
GREEN  = 0x22          # RGB 00 11 00: the curve

LINE         = 800     # clocks per line
H_SYNC_WIDTH = 96      # clocks of HSync per line
GRID         = 64      # grid spacing in pixels

UART_RX      = 0x80    # ui[7] is the UART input; the line idles high
CLKS_PER_BIT = 217     # 25 MHz / 115200 baud

# ---------------------------------------------------------------------------
# The curve model: the same maths as the chip
# ---------------------------------------------------------------------------
DEFAULT_COEFFICIENTS = (3, -5, 2)        # what the chip holds after reset


def q53(value):
    """Real coefficient -> the Q5.3 integer the chip stores (value x 8)."""
    stored = value * 8
    assert stored == int(stored) and -128 <= stored <= 127, f"{value} does not fit Q5.3"
    return int(stored)


def curve_heights(A, B, C):
    """Height of the curve (pixels above the x-axis) at each column 0..640.

    Mirrors the chip: 8*y = a*p^2 + b*p + c with a, b, c in Q5.3, divided by 8
    rounding down (an arithmetic shift), then clamped to 9 bits. Column 640 is
    included because each column is joined to the next one.
    """
    a, b, c = q53(A), q53(B), q53(C)
    heights = []
    for x in range(641):
        p = x - 320
        y = (a * p * p + b * p + c) >> 3
        heights.append(max(-256, min(255, y)))
    return heights


def expected_green(heights, row):
    """Columns that should be green on a screen row (0 = top).

    The curve is joined up: column x is lit on every row between its own height
    and the next column's height, so steep parts have no gaps.
    """
    level = 240 - row
    return [x for x in range(640)
            if min(heights[x], heights[x + 1]) <= level <= max(heights[x], heights[x + 1])]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def reset(dut):
    """Start the 25 MHz clock and hold the chip in reset for 10 cycles."""
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = UART_RX          # UART idle (high), all other inputs low
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1


async def capture(dut, clocks):
    """uo_out for the next `clocks` clock cycles (None where it is unknown)."""
    samples = []
    for _ in range(clocks):
        await RisingEdge(dut.clk)
        await ReadOnly()
        v = dut.uo_out.value
        samples.append(int(v) if v.is_resolvable else None)
    return samples


async def capture_from_reset(dut, lines):
    """Reset, capture `lines` lines of output, and find where column 0 is.

    The left pixel of the white y-axis is column 319, so the offset is its sample
    index on line 1 minus 319. Working relative to the axis means the checks
    don't depend on the exact clock the capture started on (which differs
    slightly at gate level).
    """
    await reset(dut)
    samples = await capture(dut, lines * LINE)
    line1 = [None if v is None else v & COLOUR for v in samples[LINE:2 * LINE]]
    white = [i for i, c in enumerate(line1) if c == WHITE]
    assert len(white) == 2, f"couldn't find the y-axis on line 1: white at {white}"
    return samples, white[0] - 319


def green_on_row(samples, row, offset):
    """Columns that are green on a screen row, read from the captured samples."""
    out = []
    for x in range(640):
        i = row * LINE + x + offset
        if 0 <= i < len(samples) and samples[i] is not None and samples[i] & COLOUR == GREEN:
            out.append(x)
    return out


async def uart_send(dut, byte):
    """Send one byte on ui[7] like a USB-serial adapter: start bit, 8 data bits
    least significant first, stop bit, each held for one bit time."""
    await FallingEdge(dut.clk)              # leave any ReadOnly phase before writing
    for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
        dut.ui_in.value = bit << 7
        await ClockCycles(dut.clk, CLKS_PER_BIT)


async def load_coefficients(dut, A, B, C):
    """Send 'A', value, 'B', value, 'C', value: the protocol coefficients.v expects."""
    for letter, value in (("A", A), ("B", B), ("C", C)):
        await uart_send(dut, ord(letter))
        await uart_send(dut, q53(value) & 0xFF)


def pin_colour(v):
    """Decode one uo_out value into an (R, G, B) colour, 0-255 per channel.
    uo_out = {hsync, B0, G0, R0, vsync, B1, G1, R1}: each colour is 2 bits."""
    if v is None:
        return (255, 0, 255)                      # unknown (X): magenta, easy to spot
    r = ((v >> 0) & 1) << 1 | ((v >> 4) & 1)
    g = ((v >> 1) & 1) << 1 | ((v >> 5) & 1)
    b = ((v >> 2) & 1) << 1 | ((v >> 6) & 1)
    return (r * 85, g * 85, b * 85)


def save_frame_png(path, samples, offset):
    """Save a whole frame exactly as the chip drew it on its output pins."""
    width, height = 640, 480
    rows = []
    for row in range(height):
        line = bytearray([0])                     # PNG filter byte
        for x in range(width):
            i = row * LINE + x + offset
            v = samples[i] if 0 <= i < len(samples) else None
            line += bytes(pin_colour(v))
        rows.append(bytes(line))

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows)))
           + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


async def capture_next_frame(dut):
    """Wait for the start of the next frame, then capture it from uo_out.

    Returns the samples and the offset of column 0 (found from the y-axis on
    line 1, the same way as capture_from_reset)."""
    top = dut.user_project
    await FallingEdge(dut.clk)
    while not (int(top.pix_x.value) == 0 and int(top.pix_y.value) == 0):
        await FallingEdge(dut.clk)
    samples = await capture(dut, 480 * LINE + 2)
    line1 = [None if v is None else v & COLOUR for v in samples[LINE:2 * LINE]]
    white = [i for i, c in enumerate(line1) if c == WHITE]
    assert len(white) == 2, f"couldn't find the y-axis on line 1: white at {white}"
    return samples, white[0] - 319


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_hsync(dut):
    """HSync pulses once every 800 clocks and stays low for 96 clocks."""
    await reset(dut)
    samples = await capture(dut, 3 * LINE)
    hs = [None if v is None else bool(v & HSYNC) for v in samples]

    # Falling edges (high then low) mark the start of each sync pulse
    falls = [i for i in range(1, len(hs)) if hs[i - 1] is True and hs[i] is False]
    assert len(falls) >= 2, f"expected at least 2 HSync pulses, saw {len(falls)}"
    assert falls[1] - falls[0] == LINE, f"line length {falls[1] - falls[0]}, expected {LINE}"

    width = 0
    for v in hs[falls[0]:]:
        if v is not False:
            break
        width += 1
    assert width == H_SYNC_WIDTH, f"HSync pulse {width} clocks, expected {H_SYNC_WIDTH}"

    # VSync only pulses near the end of the frame, so it stays high here
    assert all(v is not None and v & VSYNC for v in samples), "VSync went low in the first lines"


@cocotb.test()
async def test_axes_and_grid(dut):
    """Line 1: one 2-pixel white axis, grey grid lines every GRID pixels either side."""
    await reset(dut)
    line1 = (await capture(dut, 2 * LINE))[LINE:]     # line 0 is a tick row, so use line 1
    assert all(v is not None for v in line1), "uo_out has unknown (X) values"
    colour = [v & COLOUR for v in line1]

    white = [i for i, c in enumerate(colour) if c == WHITE]
    assert len(white) == 2 and white[1] == white[0] + 1, f"axis pixels {white}"
    left, right = white

    # The 640 visible pixels, counted from the axis (wrapping round the 800-clock line)
    visible = {p: colour[p % LINE] for p in range(left - 319, left + 321)}
    grey = [p for p, c in visible.items() if c == GREY]
    lhs = [g for g in grey if g < left]
    rhs = [g for g in grey if g > right]
    assert lhs and rhs, "no grid lines on one side of the axis"
    for side, name in ((lhs, "left"), (rhs, "right")):
        gaps = [b - a for a, b in zip(side, side[1:])]
        assert all(g == GRID for g in gaps), f"{name} grid spacing {gaps}, expected {GRID}"
    assert left - lhs[-1] <= GRID and rhs[0] - right <= GRID, "grid not lined up with the axis"

    others = [p for p, c in visible.items() if c not in (0, WHITE, GREY, GREEN)]
    assert not others, f"unexpected colours at {others[:10]}"


@cocotb.test()
async def test_curve_first_row(dut):
    """The first row the default curve reaches is green exactly where the model says."""
    heights = curve_heights(*DEFAULT_COEFFICIENTS)
    row = next((r for r in range(1, 480) if expected_green(heights, r)), None)
    assert row is not None, "the default curve has no points on screen"

    samples, offset = await capture_from_reset(dut, row + 2)
    want = expected_green(heights, row)
    got = green_on_row(samples, row, offset)
    dut._log.info(f"row {row}: expected {want}, got {got}")
    assert got == want, f"row {row}: green at {got}, expected {want}"


@cocotb.test(skip=GATE_LEVEL)
async def test_curve_frame(dut):
    """Whole frame: every green pixel matches the default curve (RTL only)."""
    heights = curve_heights(*DEFAULT_COEFFICIENTS)
    samples, offset = await capture_from_reset(dut, 481)
    missing, extra = [], []
    for row in range(480):
        want = set(expected_green(heights, row))
        got = set(green_on_row(samples, row, offset))
        missing += [(x, row) for x in sorted(want - got)]
        extra += [(x, row) for x in sorted(got - want)]
    dut._log.info(f"missing {len(missing)}, extra {len(extra)}")
    save_frame_png("output/default_curve.png", samples, offset)
    assert not missing, f"{len(missing)} curve pixels missing, e.g. (x, row) {missing[:5]}"
    assert not extra, f"{len(extra)} green pixels not on the curve, e.g. (x, row) {extra[:5]}"


# Coefficients covering the whole Q5.3 range (-16 to +15.875, steps of 0.125)
COEFFICIENT_SETS = [
    # name              A        B        C
    ("baseline",         3,      -5,       2),
    ("smallest_A",       0.125,   0,       0),
    ("largest_A",       15.875,   0,       0),
    ("most_negative_A", -16,      0,       0),
    ("downward_peak",   -0.5,     0,       7),
    ("line_y_eq_x",      0,       1,       0),
    ("steepest_line",    0,      15.875,   0),
    ("highest_flat",     0,       0,      15.875),
    ("lowest_flat",      0,       0,     -16),
    ("B_moves_vertex",   1,       8,       0),
    ("ordinary_curve",   0.5,    -4,      -6),
    ("all_maximum",     15.875,  15.875,  15.875),
    ("all_minimum",    -16,     -16,     -16),
]


@cocotb.test(skip=GATE_LEVEL)
async def test_coefficients(dut):
    """Load each coefficient set over the UART, then capture a whole frame from the
    output pins. Checks the registers and every green pixel against the model, and
    saves the frame exactly as the chip drew it to output/. About 35 s per set."""
    await reset(dut)
    top = dut.user_project

    for name, A, B, C in COEFFICIENT_SETS:
        await load_coefficients(dut, A, B, C)

        stored = [r.value.to_signed() for r in
                  (top.coeff_inst.a_reg, top.coeff_inst.b_reg, top.coeff_inst.c_reg)]
        assert stored == [q53(A), q53(B), q53(C)], f"{name}: registers hold {stored}"

        # A whole new frame, drawn entirely with the new coefficients
        samples, offset = await capture_next_frame(dut)
        save_frame_png(f"output/coefficients_{name}.png", samples, offset)

        heights = curve_heights(A, B, C)
        wrong = []
        for row in range(480):
            want = set(expected_green(heights, row))
            got = set(green_on_row(samples, row, offset))
            wrong += [(x, row) for x in sorted(want ^ got)]
        green = sum(len(green_on_row(samples, row, offset)) for row in range(480))
        dut._log.info(f"{name:16s} A={A:<7} B={B:<7} C={C:<7} green pixels: {green}")
        assert not wrong, f"{name}: {len(wrong)} pixels differ from the model, e.g. (x, row) {wrong[:5]}"
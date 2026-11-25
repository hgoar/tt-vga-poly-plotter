# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# cocotb tests for the VGA polynomial plotter (rebuild) 
#
# Currently, the chip draws y = Ax^2 + Bx + C, where A, B, and C are preset values A = 3, B =-5 ans C = 2
# The current scale is at 32 pixels per integer value of x and y so x = -10 to 10 and y= -7.5 to 7.5 
# The origin is at the center of the 640 x 480 screen. 
# A, B and C are fixed in project.v for now, in Q5.3 (real value x 8)
#
# Currently there are 5 tests 
# test_hsync: Tests that the  HSync pulses every 800 clocks and lasts 96 clocks
# test_vsync: Tests that the VSync pulses every 525 lines and lasts 2 lines
# test_axes_and_grid: Line 1 has one 2-pixel white y-axis and grey grid lines every 64 pixels (2 units) either side of it
# test_curve: every green pixel on a whole frame matches the model; saves the frame, as the chip drew it, to output


import os
import struct
import zlib
 
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
GATE_LEVEL = os.environ.get("GATES") == "yes"

# ---------------------------------------------------------------------------
# Pins, colours and screen layout
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
SCALE        = 32      # pixels per unit
GRID         = 64      # grid line every 2 units
TICK         = 32      # tick mark every unit

# ---------------------------------------------------------------------------
# The curve model: the same maths as the chip
# ---------------------------------------------------------------------------
# Must match coeff_a, coeff_b, coeff_c in project.v (as real values)
A, B, C = 3, -5, 2
 
 
def q53(value):
    """Real coefficient -> the Q5.3 integer the chip stores (value x 8)."""
    stored = value * 8
    assert stored == int(stored) and -128 <= stored <= 127, f"{value} does not fit Q5.3"
    return int(stored)
 
 
def curve_heights(A, B, C):
    """Height of the curve in pixels above the x-axis, for columns 0..640.
 
    Mirrors the chip exactly. With a, b, c the Q5.3 values and p the column
    measured from the centre, the chip keeps 256 x the pixel height:
        256 * y = a*p^2 + 32*b*p + 1024*c
    then divides by 256 rounding down (an arithmetic shift) and clamps to 9 bits.
    Column 640 is included because each column is joined to the next one.
    """
    a, b, c = q53(A), q53(B), q53(C)
    heights = []
    for x in range(641):
        p = x - 320
        y = (a * p * p + 32 * b * p + 1024 * c) >> 8
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
    dut.ui_in.value = 0
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
 
    The left pixel of the white y-axis is column 319, so the offset is its
    sample index on line 1 minus 319.
    """
    await reset(dut)
    samples = await capture(dut, lines * LINE)
    line1 = [None if v is None else v & COLOUR for v in samples[LINE:2 * LINE]]
    white = [i for i, c in enumerate(line1) if c == WHITE]
    assert len(white) == 2, f"couldn't find the y-axis on line 1: white at {white}"
    return samples, white[0] - 319
 
 
def colour_at(samples, x, row, offset):
    """The colour bits at column x of a screen row, or None if unknown."""
    i = row * LINE + x + offset
    if 0 <= i < len(samples) and samples[i] is not None:
        return samples[i] & COLOUR
    return None
 
 
def columns_with(samples, row, offset, colour):
    """Columns on a screen row that show the given colour."""
    return [x for x in range(640) if colour_at(samples, x, row, offset) == colour]
 
 
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
    """Line 1: one 2-pixel white y-axis, grey grid lines every GRID pixels either side."""
    samples, offset = await capture_from_reset(dut, 2)
    row = 1                                         # not a tick or grid row
 
    white = columns_with(samples, row, offset, WHITE)
    assert white == [319, 320], f"y-axis at columns {white}, expected [319, 320]"
 
    grey = columns_with(samples, row, offset, GREY)
    expected_grid = [x for x in range(0, 640, GRID) if x not in (319, 320)]
    assert grey == expected_grid, f"grid at {grey}, expected {expected_grid}"
 
    others = [x for x in range(640)
              if colour_at(samples, x, row, offset) not in (0, WHITE, GREY, GREEN)]
    assert not others, f"unexpected colours at columns {others[:10]}"
 
 
@cocotb.test()
async def test_ticks(dut):
    """Tick marks every unit (TICK pixels) along both axes, 4 pixels either side."""
    samples, offset = await capture_from_reset(dut, 240)
    curve = curve_heights(A, B, C)
 
    # Along the x-axis: row 236 is 4 rows above it, inside the tick band.
    # Every TICK-th column is white, unless the curve passes through it.
    row = 236
    green = set(expected_green(curve, row))
    want = [x for x in range(0, 640, TICK) if x not in green] + [319, 320]
    got = columns_with(samples, row, offset, WHITE)
    assert sorted(set(want)) == got, f"x-axis ticks at {got}, expected {sorted(set(want))}"
 
    # Along the y-axis: row 16 is a tick row (16 + 16 = 32, a multiple of TICK).
    # The tick spans columns 315 to 323 around the axis.
    row = 16
    got = columns_with(samples, row, offset, WHITE)
    want = [x for x in range(315, 324) if x not in set(expected_green(curve, row))]
    assert got == want, f"y-axis tick on row {row} at {got}, expected {want}"

@cocotb.test(skip=GATE_LEVEL)
async def test_curve_frame(dut):
    """Whole frame: every green pixel matches the model (RTL only, about 35 s).
    Saves the frame exactly as the chip drew it to output/curve_frame.png."""
    heights = curve_heights(A, B, C)
    samples, offset = await capture_from_reset(dut, 481)
    save_frame_png("output/curve_frame.png", samples, offset)
 
    missing, extra = [], []
    for row in range(480):
        want = set(expected_green(heights, row))
        got = set(columns_with(samples, row, offset, GREEN))
        missing += [(x, row) for x in sorted(want - got)]
        extra += [(x, row) for x in sorted(got - want)]
    dut._log.info(f"curve pixels expected: {sum(len(expected_green(heights, r)) for r in range(480))}; "
                  f"missing {len(missing)}, extra {len(extra)}")
    assert not missing, f"{len(missing)} curve pixels missing, e.g. (x, row) {missing[:5]}"
    assert not extra, f"{len(extra)} green pixels not on the curve, e.g. (x, row) {extra[:5]}"

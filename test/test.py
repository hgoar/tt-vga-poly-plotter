# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# cocotb tests for the VGA polynomial plotter.
#
# The tests drive the chip's clock and reset, record what it puts on its
# output pins (uo_out) clock by clock, and check that against what the screen
# should show:
#   - test_hsync:            HSync pulses once every 800 clocks, 96 clocks long
#   - test_axes_and_grid:    on line 1, one 2-pixel white axis and grey grid
#                            lines every GRID pixels on each side of it
#   - test_points_first_row: the first row the curve reaches has its points in
#                            exactly the columns the formula predicts
#   - test_points_frame:     every plotted point on the whole screen matches the
#                            formula (RTL only; skipped in the gate-level test)
#
# All checks are relative to where the white axis appears, so they don't depend
# on exact clock alignment and also work for the gate-level (hardened) chip.


import os   # for the GATES environment variable for the gate-level test 
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly
 
# uo_out = {hsync, B0, G0, R0, vsync, B1, G1, R1}

HSYNC = 0x80        # bit 7 of uo_out is HSync (active low)
VSYNC = 0x08        # bit 3 of uo_out is VSync (active low)
COLOUR = 0x77      # the six colour bits
WHITE = 0x77       # RGB = 11 11 11
GREY = 0x70        # RGB = 01 01 01  (the low bit of each colour for the grid)
GREEN =0x22       # RGB = 00 11 00 (the colour of the plotted points))


# The curve y = A*X^2 + B*X + C, in pixels from the centre of the screen.
# These MUST match A_coefficient, B_coefficient and C_coefficient in project.v.
A,B,C = 3,-5,2



GRID = 64          # grid spacing in pixels (change if you change the design)
LINE = 800         # clocks per line
H_SYNC_WIDTH = 96  # clocks of HSync per line
 
 
async def reset(dut):
    """Start a 25 MHz clock and hold the design in reset for 10 cycles."""
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
 
 
async def capture(dut, n):
    """Return uo_out for the next n clocks (None where the value is unknown)."""
    samples = []
    for _ in range(n):
        await RisingEdge(dut.clk)
        await ReadOnly()
        v = dut.uo_out.value
        samples.append(int(v) if v.is_resolvable else None)
    return samples
 

# Sync timing
@cocotb.test()
async def test_hsync(dut):
    """HSync pulses once every 800 clocks and stays low for 96 clocks."""
    await reset(dut)
    s = await capture(dut, 3 * LINE)
    hs = [None if v is None else bool(v & HSYNC) for v in s]
 
    # Falling edges of HSync (high then low) mark the start of each sync pulse
    falls = [i for i in range(1, len(hs)) if hs[i - 1] is True and hs[i] is False]
    assert len(falls) >= 2, f"expected at least 2 HSync pulses, saw {len(falls)}"

     # The gap between two pulses is the length of one line
    assert falls[1] - falls[0] == LINE, f"line length {falls[1] - falls[0]} clocks, expected {LINE}"
 
    # Count how many clocks HSync stays low after the first falling edge
    width = 0
    for v in hs[falls[0]:]:
        if v is False:
            width += 1
        else:
            break
    assert width == H_SYNC_WIDTH, f"HSync pulse {width} clocks, expected {H_SYNC_WIDTH}"
 
    # VSync only pulses near the end of the frame, so it should stay high here
    assert all(v is not None and (v & VSYNC) for v in s), "VSync went low during the first lines"
 
 
@cocotb.test()
async def test_axes_and_grid(dut):
    """Line 1: one 2-pixel white axis, and grey grid lines every GRID pixels on each side."""
    await reset(dut)
    # Line 1 rather than line 0, because line 0 is a tick-mark row in this layout
    s = (await capture(dut, 2 * LINE))[LINE:]   # skip line 0, keep line 1
    assert all(v is not None for v in s), "uo_out has unknown (X) values"
    colour = [v & COLOUR for v in s]
 
    white = [i for i, c in enumerate(colour) if c == WHITE]
    grey = [i for i, c in enumerate(colour) if c == GREY]
    dut._log.info(f"white pixels at {white}")
    dut._log.info(f"grey pixels at {grey}")
 
    # The vertical axis: exactly two white pixels, side by side
    assert len(white) == 2 and white[1] == white[0] + 1, f"axis pixels {white}"
    left, right = white
    # The 640 visible pixels, counted from the axis. The capture can start a
    # clock or so off the start of the line, so wrap round the 800-clock line.
    visible = range(left - 319, left + 321)
    vis_colour = {p: colour[p % LINE] for p in visible}
    grey = [p for p in visible if vis_colour[p] == GREY]
 
    # Grid: lines exactly GRID apart on each side, the nearest within GRID of the axis
    lhs = [g for g in grey if g < left]
    rhs = [g for g in grey if g > right]
    assert lhs and rhs, "no grid lines on one side of the axis"
    for side, name in ((lhs, "left"), (rhs, "right")):
        gaps = [b - a for a, b in zip(side, side[1:])]
        assert all(g == GRID for g in gaps), f"{name} grid spacing {gaps}, expected {GRID}"
    assert left - lhs[-1] <= GRID and rhs[0] - right <= GRID, "grid not lined up with the axis"
    expected_lines = 640 // GRID - 1
    assert len(grey) >= expected_lines - 1, f"only {len(grey)} grid lines on line 1"
 
    # Everything else on the visible line is black
    others = [p for p in visible if p not in white and p not in grey and vis_colour[p] != 0]
    assert not others, f"unexpected coloured pixels at {others[:10]}"

    # ----------------------------------------------------------------------------
# The plotted points
# ----------------------------------------------------------------------------
 
def expected_points(row):
    """Columns that should be green on a screen row (0 = top).
 
    One point per column: column x is green on the row where its y lands.
    """
    height = 240 - row                         # height above the x-axis
    out = []
    for x in range(640):
        X = x - 320                            # column measured from the centre
        if (A * X * X) + (B * X) + C == height:
            out.append(x)
    return out
 
 
async def find_offset(dut, lines):
    """Reset, capture `lines` lines, and work out where column 0 is in the samples.
 
    The left axis pixel is column 319, so offset = (its sample index on line 1) - 319.
    """
    await reset(dut)
    s = await capture(dut, lines * LINE)
    line1 = [None if v is None else v & COLOUR for v in s[LINE:2 * LINE]]
    white = [i for i, c in enumerate(line1) if c == WHITE]
    assert len(white) == 2, f"couldn't find the axis on line 1: white at {white}"
    return s, white[0] - 319
 
 
def green_columns(samples, row, offset):
    """Columns that are green on a row, from the captured samples."""
    out = []
    for x in range(640):
        i = row * LINE + x + offset
        if 0 <= i < len(samples) and samples[i] is not None and samples[i] & COLOUR == GREEN:
            out.append(x)
    return out
 
 
@cocotb.test()
async def test_points_first_row(dut):
    """The first row the curve reaches: points exactly where the formula says."""
    row = next((r for r in range(1, 480) if expected_points(r)), None)
    assert row is not None, "the curve has no points on screen: check A, B and C"
    s, offset = await find_offset(dut, row + 2)
    want = expected_points(row)
    got = green_columns(s, row, offset)
    dut._log.info(f"row {row}: expected points at {want}, got {got}")
    assert got == want, f"points on row {row} are at {got}, expected {want}"
 
 # Skipped in the gate-level run (the Makefile sets GATES=yes there), because
# simulating every gate for a whole frame would take a very long time.
@cocotb.test(skip=os.environ.get("GATES") == "yes")
async def test_points_frame(dut):
    """Whole frame: every plotted point matches the formula (RTL only, ~20 s)."""
    s, offset = await find_offset(dut, 481)
    missing, extra, total = [], [], 0
    for row in range(480):
        want = set(expected_points(row))
        got = set(green_columns(s, row, offset))
        total += len(want)
        missing += [(x, row) for x in sorted(want - got)]
        extra += [(x, row) for x in sorted(got - want)]
    dut._log.info(f"points on screen: {total}; missing {len(missing)}; extra {len(extra)}")
    assert not missing, f"{len(missing)} points missing, e.g. (x, row) {missing[:5]}"
    assert not extra, f"{len(extra)} green pixels not on the curve, e.g. (x, row) {extra[:5]}"
# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the VGA plotter (axes, ticks and grid).
# They check the first two lines drawn after reset:
#   - HSync: one pulse every 800 clocks, 96 clocks long
#   - line 1: exactly one pair of white axis pixels, next to each other
#   - line 1: grey grid pixels every GRID columns on each side of the axis
# (line 1, not line 0, so that tick marks don't get in the way)
# The checks are relative (they don't depend on exact cycle alignment),
# so the same test also works for the gate-level simulation.
 
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly
 
# uo_out = {hsync, B0, G0, R0, vsync, B1, G1, R1}
HSYNC = 0x80
VSYNC = 0x08
COLOUR = 0x77      # the six colour bits
WHITE = 0x77       # RGB = 11 11 11
GREY = 0x70        # RGB = 01 01 01  (the low bit of each colour)
 
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
 
 
@cocotb.test()
async def test_hsync(dut):
    """HSync pulses once every 800 clocks and stays low for 96 clocks."""
    await reset(dut)
    s = await capture(dut, 3 * LINE)
    hs = [None if v is None else bool(v & HSYNC) for v in s]
 
    falls = [i for i in range(1, len(hs)) if hs[i - 1] is True and hs[i] is False]
    assert len(falls) >= 2, f"expected at least 2 HSync pulses, saw {len(falls)}"
    assert falls[1] - falls[0] == LINE, f"line length {falls[1] - falls[0]} clocks, expected {LINE}"
 
    width = 0
    for v in hs[falls[0]:]:
        if v is False:
            width += 1
        else:
            break
    assert width == H_SYNC_WIDTH, f"HSync pulse {width} clocks, expected {H_SYNC_WIDTH}"
 
    assert all(v is not None and (v & VSYNC) for v in s), "VSync went low during the first lines"
 
 
@cocotb.test()
async def test_axes_and_grid(dut):
    """Line 1: one 2-pixel white axis, and grey grid lines every GRID pixels on each side."""
    await reset(dut)
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
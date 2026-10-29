<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This project draws a set of axes on a 640 × 480 VGA display at 60 Hz, using a 25 MHz clock. It is the first stage of a curve plotter; the curve will be added on top of these axes later.

A VGA timing generator counts which pixel the screen is drawing (x from 0 to 799 and y from 0 to 524, including the blanking periods) and produces the HSync and VSync pulses the monitor needs. Outside the visible 640 × 480 area the colour outputs are held at black.

There is no frame buffer: every pixel's colour is worked out at the moment it is drawn, from its x and y position. The axes are drawn by comparing the pixel's position with fixed values: the vertical axis is columns 319–320 and the horizontal axis is rows 239–240, so they cross in the middle of the screen and are 2 pixels thick. Tick marks are drawn every 16 pixels along each axis, and grey grid lines every 64 pixels. Because 16 and 64 are powers of two, checking for a tick or grid line only needs the low bits of x or y to be zero, which takes a few gates instead of a full comparator.

Each pixel's colour comes from a priority list: axes and ticks (white) on top, then the grid (grey), then the background (black).


## How to test

1. Connect a Tiny VGA Pmod to the output pins and a VGA monitor to the Pmod.
2. Set the clock to 25 MHz.
3. Hold reset (rst_n low), then release it.
4. White axes with tick marks should appear crossing in the centre of the screen, over a grey grid on a black background.


## External hardware

- Tiny VGA Pmod (on the output pins uo[7:0])
- VGA monitor

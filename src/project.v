/*
 * VGA polynomial plotter: step 1, axes and grid.
 *
 * Draws a grey grid, white axes through the middle of the screen and tick marks
 * along the axes. The curve is added later in section 3.
 *
 *   1. SETTINGS   Colours, axis position and grid spacing.
 *   2. WIRING     The pins and the sync generator.
 *   3. THE CURVE  (empty for now: the forward-difference engine goes here)
 *   4. DRAWING    The colour of every pixel, from where it is.
 
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns / 1ps

 
module tt_um_hgoar_vga_plotter (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
 
    // ========================================================================
    // 1. SETTINGS
    // ========================================================================
 
    // Colours, 6'bRRGGBB
    localparam [5:0] BACKGROUND = 6'b000000;   // black
    localparam [5:0] GRID       = 6'b010101;   // dark grey
    localparam [5:0] AXIS       = 6'b111111;   // white
    localparam [5:0] CURVE      = 6'b001100;   // green (used once the curve is in)
 
    // Where the axes cross: the middle of the 640 x 480 screen
    localparam [9:0] ORIGIN_X = 10'd320;
    localparam [9:0] ORIGIN_Y = 10'd240;

     
 
    // ========================================================================
    // 2. WIRING
    // ========================================================================
 
    wire       hsync, vsync, video_active;
    wire [9:0] pix_x;   // 0 to 639 across
    wire [9:0] pix_y;   // 0 to 479 down

 
    hvsync_generator hvsync_gen (
        .clk(clk),
        .reset(~rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(video_active),
        .hpos(pix_x),
        .vpos(pix_y)
    );
 
    // ========================================================================
    // 3. THE CURVE
    //    The forward-difference engine will go here and produce in_curve.
    // ========================================================================
 
    wire in_curve = 1'b0;
 
    // ========================================================================
    // 4. DRAWING
    //    One question for each thing on screen: is this pixel on it?
    // ========================================================================
 
    // Axes: 2 pixels thick, crossing at the origin
    wire on_y_axis = (pix_x == 10'd319)|(pix_x == 10'd320);
    wire on_x_axis = (pix_y == 10'd239)|(pix_y == 10'd240);

 

    wire [9:0] grid_y  = pix_y + 10'd16;
    wire on_grid       = (pix_x[5:0] == 6'd0) | (grid_y[5:0] == 6'd0);
 
    // Tick marks every 16 pixels, 4 pixels either side of each axis
    wire near_x_axis = (pix_y >= ORIGIN_Y - 10'd5) & (pix_y < ORIGIN_Y + 10'd4);
    wire near_y_axis = (pix_x >= ORIGIN_X - 10'd5) & (pix_x < ORIGIN_X + 10'd4);
    wire on_tick     = (near_x_axis & (pix_x[3:0] == 4'd0)) |
                       (near_y_axis & (grid_y[3:0] == 4'd0));
 
    // The first line that matches wins, so higher lines are drawn on top
    reg [5:0] colour;
    always @(*) begin
        if (~video_active)               colour = 6'b000000;
        else if (in_curve)               colour = CURVE;
        else if (on_x_axis | on_y_axis)  colour = AXIS;
        else if (on_tick)                colour = AXIS;
        else if (on_grid)                colour = GRID;
        else                             colour = BACKGROUND;
    end
 
    // ---- to the pins, in the order the Tiny VGA Pmod expects
    wire [1:0] R = colour[5:4];
    wire [1:0] G = colour[3:2];
    wire [1:0] B = colour[1:0];
 
    assign uo_out  = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;
 
    wire _unused_ok = &{ena, uio_in, ui_in, 1'b0};
 
endmodule
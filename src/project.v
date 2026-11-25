/*
 * VGA polynomial plotter
 *
 * Draws the curve y = A*x^2 + B*x + C on a 640 x 480 VGA screen, over a grey
 * grid with white axes through the centre and tick marks along the axes.
 *
 * Scale: 32 pixels per unit, so the screen shows x from -10 to +10 and
 * y from -7.5 to +7.5. Grid lines are every 2 units (64 pixels) and tick
 * marks every 1 unit (32 pixels).
 *
 * The coefficients are in Q5.3 fixed point (8 bits: the real value x 8), so
 * they can range from -16 to +15.875 in steps of 0.125. For now they are fixed
 * at A = 3, B = -5, C = 2.
 *
 * The curve is calculated by forward differencing (a difference engine): one
 * column per clock, using two adders instead of multipliers. Each column is
 * joined to the next by lighting every pixel between their heights, so steep
 * parts of the curve have no gaps.
 *
 *   1. SETTINGS   Colours, axis position and the coefficients.
 *   2. WIRING     The pins and the sync generator.
 *   4. THE CURVE  Difference engine and joined curve.
 *   5. DRAWING    The colour of every pixel, from where it is.
 *
 * Copyright (c) 2024 Hermione Goar
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none


 
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

    localparam signed [7:0] coeff_a =  8'sd24;    //  3 x 8
    localparam signed [7:0] coeff_b = -8'sd40;    // -5 x 8
    localparam signed [7:0] coeff_c =  8'sd16;    //  2 x 8
 
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
    // 4. THE CURVE
    // ========================================================================
    
    // At the current scale of 32 pixels per unit, the screen shows x from -10 to 10
    // The engine starts at the leftmost pixel = -320 where x = -10 and steps one pixel per clock.
    // The coefficients widened to the width of each sum (copying the sign bit),
    // so every multiply and add below is done at that width and stays signed
    wire signed [24:0] a_25 = {{17{coeff_a[7]}}, coeff_a};
    wire signed [24:0] b_25 = {{17{coeff_b[7]}}, coeff_b};
    wire signed [24:0] c_25 = {{17{coeff_c[7]}}, coeff_c};
    wire signed [17:0] a_18 = {{10{coeff_a[7]}}, coeff_a};
    wire signed [17:0] b_18 = {{10{coeff_b[7]}}, coeff_b};

    // Multiplying by fixed numbers
    wire signed [24:0] Y0    = (a_25 * 25'sd102400) - (b_25 * 25'sd10240) + (c_25 * 25'sd1024);       
    // y = 3x^2 - 5x + 2
    //  x     y     col_1   col_2
    //  1     0       4       6
    //  2     4      10       6
    //  3    14      16       6
    //  4    30      22       6

    // First value of col_1 = y(-319h) - y(-320h)
    wire signed [17:0] col_1 = (a_18 * -18'sd639) + (b_18 * 18'sd32);   
    // For a quadratic, col_2 is always 2*A*h^2
    wire signed [17:0] col_2 = a_18 * 18'sd2;

    // current y value
    reg signed [24:0] y_calc; 
    // col_1 + col_2 
    reg signed [17:0] y_difference; 

   always @(posedge clk) begin
        if (~rst_n | (pix_x == 10'd799)) begin                 // back to the left edge, p = -320
            y_calc       <= Y0;
            y_difference <= col_1;
        end else begin                               // one column right
            y_calc       <= y_calc + {{7{y_difference[17]}}, y_difference};
            y_difference <= y_difference + col_2;
        end
    end
    wire signed [24:0] y_next = y_calc + {{7{y_difference[17]}}, y_difference};

    // Back to pixels: divide by 8 to convert to fixed point binary number aka real value 
    wire signed [24:0] y_calc_px = y_calc >>> 8;
    wire signed [24:0] y_next_px = y_next >>> 8;


    wire y_fits    = (y_calc_px[24:8] == {17{y_calc_px[24]}});
    wire next_fits = (y_next_px[24:8] == {17{y_next_px[24]}});

    wire signed [8:0] y_calc_vis = y_fits    ? y_calc_px[8:0] : (y_calc_px[24] ? -9'sd256 : 9'sd255);
    wire signed [8:0] y_next_vis = next_fits ? y_next_px[8:0] : (y_next_px[24] ? -9'sd256 : 9'sd255);

    // y = 240 - pix_y (center pix_y at y = 0) 
    // This pixel's height above the x-axis (-239 to +240): fits in 9 bits signed
    wire signed [8:0] y_value = 9'sd240 - $signed(pix_y[8:0]);


    // Join this columns y to the next colums y by lighting every pixel in between 
    // y_low = the lowest y value between this columns y and the next columns y 
    wire signed [8:0] y_low = (y_calc_vis < y_next_vis)? y_calc_vis : y_next_vis;
    // y_high = the highest y value between this columns y and the next columns y
    wire signed [8:0] y_high = (y_calc_vis > y_next_vis)? y_calc_vis : y_next_vis;
    
    // light all pixels between this y value and the next 
    wire in_curve = (y_value >= y_low) & (y_value <= y_high); 

    
 
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
    wire on_tick     = (near_x_axis & (pix_x[4:0] == 5'd0)) |
                       (near_y_axis & (grid_y[4:0] == 5'd0));
 
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
 
   reg [7:0] uo_reg;
    always @(posedge clk) begin
        if (~rst_n) uo_reg <= 8'h88;     // syncs high (inactive), colour black
        else        uo_reg <= {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
    end
    assign uo_out  = uo_reg;
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;
 
    wire _unused_ok = &{ena, uio_in, ui_in, grid_y[9:6], 1'b0};
 
endmodule
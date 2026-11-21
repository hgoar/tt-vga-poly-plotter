/*
 * VGA polynomial plotter: step 2, draw a curve.
 *
 * Draws a grey grid, white axes through the middle of the screen and tick marks
 * along the axes. In this version each pixel corresponds to an (x,y) position 
 * with a 1:1 ratio. These green points where pix_x = x and pix_y = y are then 
 * joined up to create the 'curve' 
 *   1. SETTINGS   Colours, axis position and grid spacing.
 *   2. WIRING     The pins and the sync generator.
 *   3. INTERACTIONS Lets the user change the zoom and pan to view the curve 
 *   4. THE CURVE  Difference engine + joined curve 
 *   5. DRAWING    The colour of every pixel, from where it is.
 
 * Copyright (c) 2024 Your Name
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

    // X and y measured from the centre of the screen, y upwards)
    localparam signed [26:0] A_coefficient = 27'sd3;
    localparam signed [26:0] B_coefficient= -27'sd5;
    localparam signed [26:0] C_coefficient = 27'sd2;

     
 
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
    // 3. INTERACTIONS
    // ========================================================================

    // The user controls in controls.v 
    wire [1:0]         zoom;
    wire signed [11:0] pan_x;
    wire signed [11:0] pan_y;
    wire               zoom_changed; 

     user_controls controls_inst (
        .clk(clk),
        .rst_n(rst_n),
        .vsync(vsync),
        .contrl(ui_in[5:0]),
        .zoom(zoom),
        .pan_x(pan_x),
        .pan_y(pan_y),
        .zoom_changed(zoom_changed)
    );

    // Coefficients sent over UART (115200 8N1) on ui[7]
    wire signed [7:0] a_coeff, b_coeff, c_coeff;

    coefficients coeff_inst (
        .clk(clk),
        .rst_n(rst_n),
        .rx(ui_in[7]),
        .a_coeff(a_coeff),
        .b_coeff(b_coeff),
        .c_coeff(c_coeff)
    );
 
    // ========================================================================
    // 4. THE CURVE
    // ========================================================================
    
    // With the zoom function h = units per pixel e.g at most zoomed in h = 1, at most zoomed out h = 8
    // so at most zoomed out x range is -2560 to +2560 
    // h can work as a shift of the zoom values 

    wire [1:0] shift   = 2'd3 - zoom;        // x h
    wire [2:0] shift_2 = {shift, 1'b0};      // x h^2 (2 * shift)

    // Y0: value of y at the left edge, x = -320h
    wire signed [26:0] Y0 = ((A_coefficient * 27'sd102400) <<< shift_2)+ ((B_coefficient * -27'sd320)   <<< shift) + C_coefficient;

    // y = 3x^2 - 5x + 2
    //  x     y     col_1   col_2
    //  1     0       4       6
    //  2     4      10       6
    //  3    14      16       6
    //  4    30      22       6

    // First value of col_1 = y(-319h) - y(-320h)
    wire signed [26:0] init_col_1 = ((A_coefficient * -27'sd639) <<< shift_2)
                                  + (B_coefficient <<< shift);

    // For a quadratic, col_2 is always 2*A*h^2
    wire signed [26:0] col_2 = (A_coefficient * 27'sd2) <<< shift_2;

    // current y value
    reg signed [26:0] y_calc; 
    // col_1 + col_2 
    reg signed [26:0] y_difference; 

    // 1 pix_x change per clock 
    always @(posedge clk) begin
        if (~rst_n | (pix_x == 10'd799)) begin   // end of a line: back to the left edge
            // y = y0 when x = -320
            y_calc <= Y0;
            // Y1 
            y_difference   <= init_col_1;
        end else begin                           // every other clock: one column right
            // Yx = Yx-1 + col_1
            y_calc <= y_calc + y_difference;
            // col_1 = col_1 + col_2 
            y_difference   <= y_difference + col_2;
        end
    end
    
    wire signed [26:0] y_next = y_calc + y_difference;

    // Graph units -> pixels: divide by h (arithmetic shift right)
    wire signed [26:0] y_calc_px = y_calc >>> shift;
    wire signed [26:0] y_next_px = y_next >>> shift;

    wire y_fits    = (y_calc_px[26:8] == {19{y_calc_px[26]}});
    wire next_fits = (y_next_px[26:8] == {19{y_next_px[26]}});

    wire signed [8:0] y_calc_vis = y_fits    ? y_calc_px[8:0] : (y_calc_px[26] ? -9'sd256 : 9'sd255);
    wire signed [8:0] y_next_vis = next_fits ? y_next_px[8:0] : (y_next_px[26] ? -9'sd256 : 9'sd255);

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
 
   reg [7:0] uo_reg;
    always @(posedge clk) begin
        if (~rst_n) uo_reg <= 8'h88;     // syncs high (inactive), colour black
        else        uo_reg <= {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
    end
    assign uo_out  = uo_reg;
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;
 
    wire _unused_ok = &{ena, uio_in, ui_in[6:2], grid_y[9:6], pan_x, pan_y, zoom_changed, a_coeff, b_coeff, c_coeff, 1'b0};
 
endmodule
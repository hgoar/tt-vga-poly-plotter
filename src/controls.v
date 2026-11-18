`default_nettype none



module user_controls (

    input  wire               clk,
    input  wire               rst_n,
    input  wire               vsync, 
    input  wire [5:0]         controls,
    output wire [1:0]         zoom,
    output wire signed [11:0] pan_x,
    output wire signed [11:0] pan_y,
    output wire               zoom_changed

); 

// fixed values for testing module creation 01 = 64 pix axis 
assign zoom = 2'd1; 
assign pan_x = 12'sd0; 
assign pan_y = 12'sd0; 
assign zoom_changed = 1'b0; 

wire _unused_ok = &{clk, rst_n, vsync, controls, 1'b0};

endmodule

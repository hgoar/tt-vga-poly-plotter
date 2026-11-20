`default_nettype none

module user_controls (

    input  wire               clk,
    input  wire               rst_n,
    input  wire               vsync, 
    input  wire [5:0]         contrl,
    output wire [1:0]         zoom,
    output wire signed [11:0] pan_x,
    output wire signed [11:0] pan_y,
    output wire               zoom_changed

); 
reg [5:0] contrl_sync_0, contrl_sync_1; 
always @ (posedge clk) begin
    contrl_sync_0 <= contrl;
    contrl_sync_1 <= contrl_sync_0;
end 
wire [5:0] btn = contrl_sync_1;

reg vsync_q; 
always @(posedge clk) begin
    vsync_q <= vsync;
end 
wire new_frame = vsync & ~vsync_q;

reg [1:0] zoom_contrl; 
always @(posedge clk) begin
    if (~rst_n) begin
        zoom_contrl <= 2'b00;
    
    end else if (new_frame) begin
        zoom_contrl <= btn[1:0];
    end
end 
wire zoom_in_press  = new_frame & btn[0] & ~zoom_contrl[0];
wire zoom_out_press = new_frame & btn[1] & ~zoom_contrl[1];


// fixed values for testing module creation 10 = 64 pix axis 

assign zoom = 2'd2;
assign pan_x = 12'sd0; 
assign pan_y = 12'sd0; 
assign zoom_changed = 1'b0; 

wire _unused_ok = &{zoom_in_press, zoom_out_press, btn[5:2], 1'b0};

endmodule

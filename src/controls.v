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

// Zoom register: 0 to 3, starts at 0 1 pixel per unit (this will have to change later so that zooming in is useful)

reg [1:0] zoom_level; 
reg       zoom_changed_q; 


always@(posedge clk) begin
    if (~rst_n) begin 
        zoom_level <= 2'b11;
        zoom_changed_q <= 1'b0;
    end else begin 
        zoom_changed_q <= 1'b0;
        if (zoom_in_press & ~zoom_out_press &(zoom_level != 2'b11)) begin
            zoom_level <= zoom_level + 2'b01; 
            zoom_changed_q <= 1'b1; 
        end else if (zoom_out_press & ~zoom_in_press & (zoom_level != 2'b00)) begin 
            zoom_level <= zoom_level -2'b01; 
            zoom_changed_q <= 1'b1; 
        end 
    end 
end 


assign zoom = zoom_level;
assign pan_x = 12'sd0; 
assign pan_y = 12'sd0; 
assign zoom_changed = zoom_changed_q; 

wire _unused_ok = &{btn[5:2], 1'b0};

endmodule

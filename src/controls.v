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

// 2 flip-flops to synchronise the inputs with the clock 
reg [5:0] contrl_sync_0, contrl_sync_1; 
always @ (posedge clk) begin
    contrl_sync_0 <= contrl;
    contrl_sync_1 <= contrl_sync_0;
end 
// btn is the synchronised inputs 
wire [5:0] btn = contrl_sync_1;

// vsync_q is vsync delayed by one clock 
reg vsync_q; 
always @(posedge clk) begin
    vsync_q <= vsync;
end 
// new_frame is true or HIGH at the end of each vsync pulse aka once per frame  
wire new_frame = vsync & ~vsync_q;

// zoom_contrl: The zoom inputs aka btn[1:0] from the previous frame
// the inputs go to zero when the buttons are not being pressed
// this means that if a button is held, the inputs will stay high, this ensures that the zoom
// only zooms in once per time the button is pressed, holding does nothing 
reg [1:0] zoom_contrl; 
always @(posedge clk) begin
    if (~rst_n) begin
        zoom_contrl <= 2'b00;
    
    end else if (new_frame) begin
        zoom_contrl <= btn[1:0];
    end
end 
// zoom_in_press only HIGH at the start of a new frame, if the zoom in button has been pressed and if 
// the button was not pressed last frame 
wire zoom_in_press  = new_frame & btn[0] & ~zoom_contrl[0];
wire zoom_out_press = new_frame & btn[1] & ~zoom_contrl[1];

// Zoom register: 0 to 3, starts at 0 1 pixel per unit (this will have to change later so that zooming in is useful)


// The current zoom level 
reg [1:0] zoom_level;
// If the zoom has changed, useful for scaling purposes 
reg       zoom_changed_q; 


always@(posedge clk) begin
    // at reset (by default) zoom is 1:1 (fully zoomed in) this scale will be changed later 
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
assign zoom_changed = zoom_changed_q; 

localparam signed [11:0] pan_step = 12'sd2;
localparam signed [11:0] pan_max  = 12'sd256;

reg signed [11:0] pan_x_reg; 
reg signed [11:0] pan_y_reg; 

always @(posedge clk) begin
    if (~rst_n | zoom_changed_q) begin
        pan_x_reg <= 12'sd0;
        pan_y_reg <= 12'sd0;
    end else if (new_frame) begin
        // left / right (both pressed = no move)
        if (btn[2] & ~btn[3] & (pan_x_reg > - pan_max))
            pan_x_reg <= pan_x_reg - pan_step;
        else if (btn[3] & ~btn[2] & (pan_x_reg < pan_max))
            pan_x_reg <= pan_x_reg + pan_step;

        // up / down: a separate if, so diagonals work
        if (btn[4] & ~btn[5] & (pan_y_reg < pan_max))
            pan_y_reg <= pan_y_reg + pan_step;
        else if (btn[5] & ~btn[4] & (pan_y_reg > -pan_max))
            pan_y_reg <= pan_y_reg - pan_step;
    end
end



assign pan_x = pan_x_reg;
assign pan_y = pan_y_reg; 


wire _unused_ok = 1'b0;

endmodule

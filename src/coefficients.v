/* 
* Coefficient registers, loaded from the input pins 
* 
* Two pins act as selecting the coefficient (ui[1:0]) and the value is set on uio[7:0]
* Then load is pressed (ui[2]), and the values are stored in the corresponding register
* 
* The values are fixed point binary (at the moment) ranging from -16 (10000.000) (-128 in regular binary) to +15.875 (01111.111) (127 in regular binary)
* After reset the registers hold the default curve, y= 3x^2 - 5x + 2
*/

`default_nettype none

module coefficients (
    input wire clk, 
    input wire rst_n, 
    input wire [7:0] value,
    input wire [1:0] select, 
    input wire load, 
    output wire signed [7:0] coeff_a, 
    output wire signed [7:0] coeff_b, 
    output wire signed [7:0] coeff_c
); 

// 2 flip-flops to synchronise the inputs with the clock 
reg input_sync_0, input_sync_1; 
always @ (posedge clk) begin
    input_sync_0 <= load;
    input_sync_1 <= input_sync_0;
end 

// load_last: the previous value of load 
// A pulse only when load goes from 0 to 1
// this means that if load is held, the value will only be stored once
reg load_last; 
always @(posedge clk) begin
    if (~rst_n) begin
        load_last <= 1'b0;
    end else begin
        load_last <= input_sync_1;
    end
end 
wire load_pressed = input_sync_1 & ~load_last; 


// The coefficient registers 
reg signed [7:0] a_coeff_reg; 
reg signed [7:0] b_coeff_reg; 
reg signed [7:0] c_coeff_reg; 

always @(posedge clk) begin 
    if (~rst_n) begin 
        a_coeff_reg <= 8'b00011000; // A = 3 : 00011.000
        b_coeff_reg <= 8'b11011000; // B = -5: 11011.000
        c_coeff_reg <= 8'b00010000; // C = 2 : 00010.000
    end else if (load_pressed) begin 
        case(select)
            2'b00: a_coeff_reg <= value;
            2'b01: b_coeff_reg <= value; 
            2'b10: c_coeff_reg <= value; 
            default: ; 
        endcase 
    end 
end 

assign coeff_a = a_coeff_reg; 
assign coeff_b = b_coeff_reg; 
assign coeff_c = c_coeff_reg; 

endmodule 


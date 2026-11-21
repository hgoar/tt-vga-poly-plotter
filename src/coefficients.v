`default_nettype none

module coefficients (
    input wire               clk, 
    input wire               rst_n, 
    input wire               rx,
    output wire signed [7:0] a_coeff, 
    output wire signed [7:0] b_coeff, 
    output wire signed [7:0] c_coeff
); 

    // connecting the UART 
    wire [7:0] rx_data; 
    wire       rx_valid; 
    wire       rx_err; 


    uart_rx uart_rx_inst (
        .clk(clk), 
        .rst_n(rst_n), 
        .rx(rx), 
        .data(rx_data), 
        .valid(rx_valid),
        .err(rx_err)
    ); 
    reg signed [7:0] a_reg; 
    reg signed [7:0] b_reg; 
    reg signed [7:0] c_reg; 

    // Stores which letter has arrived; user sends 'A' and then the value for A 
    // pending stores which coefficient the following value relates to 
    reg [1:0] pending; 

    always @(posedge clk) begin
        // A, B and C reset to my current curve values for 3x^2 -5x+2
        if (~rst_n) begin
            a_reg <= 8'b00011000; // A = 3 : 00011.000
            b_reg <= 8'b11011000; // B = -5: 11011.000
            c_reg <= 8'b00010000; // C = 2 : 00010.000
            pending <= 2'b00;
        end else if (rx_valid) begin
            if (pending == 2'b00) begin
                case(rx_data)
                8'b01000001: pending <= 2'b01;   // 'A' (65): next byte is A
                8'b01000010: pending <= 2'b10;   // 'B' (66): next byte is B
                8'b01000011: pending <= 2'b11;   // 'C' (67): next byte is C
                default:     pending <= 2'b00;   // anything else is ignored
                endcase
            end else begin 
                case(pending)
                    2'b01:   a_reg <= rx_data;
                    2'b10:   b_reg <= rx_data;
                    2'b11:   c_reg <= rx_data;
                    default: ;                      
                endcase 
                pending <= 2'b00; 
            end 
        end 
    end 
    assign a_coeff = a_reg; 
    assign b_coeff = b_reg; 
    assign c_coeff = c_reg; 

    wire _unused_ok = &{rx_err, 1'b0};

endmodule
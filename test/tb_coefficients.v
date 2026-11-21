// Waveform testbench for coefficients.v 
`default_nettype none
`timescale 1ns / 1ps

module tb_coefficients;
    reg         clk =   1'b0;
    reg         rst_n = 1'b0;
    reg         rx =    1'b1;  

    wire signed [7:0] a_coeff; 
    wire signed [7:0] b_coeff;
    wire signed [7:0] c_coeff;

    coefficients dut (
        .clk(clk), 
        .rst_n(rst_n),
        .rx(rx),
        .a_coeff(a_coeff),
        .b_coeff(b_coeff),
        .c_coeff(c_coeff)
    ); 

    always #20 clk = ~clk;

    localparam integer CLKS_PER_BIT = 217; 

        task send_coefficient(input [7:0] coeff);
        integer i;
        begin
            rx = 1'b0;                              // start bit
            repeat (CLKS_PER_BIT) @(posedge clk);   // hold for one bit time

            for (i = 0; i < 8; i = i + 1) begin
                rx = coeff[i];                      // data bit, LSB first
                repeat (CLKS_PER_BIT) @(posedge clk);
            end

            rx = 1'b1;                              // stop bit
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_coefficients.fst");
        $dumpvars(0, tb_coefficients);

        // reset: expect A = 3 : 00011.000, B = -5: 11011.000, C = 2 : 00010.000
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (500) @(posedge clk);


        // 'A' in ASCII (01000001) and then 2.5 (00010100): A changes, B and C remain unchanged 
        send_coefficient(8'b01000001);             
        send_coefficient(8'b00010100); 


        // 'B' in ASCII (01000010) and then -2 (11110000): B changes, A and C remain unchanged
        send_coefficient(8'b01000010);
        send_coefficient(8'b11110000);  

        // 'X' in ASCII (01011000) which should do nothing 
        send_coefficient(8'b01011000);

        // 'C' in ASCII (01000011) and then 1 (00001000): C changes, A and B remain unchanged
        send_coefficient(8'b01000011); 
        send_coefficient(8'b00001000); 

        repeat (500) @(posedge clk);

        $finish;
    end

endmodule 
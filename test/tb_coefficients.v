// Waveform testbench for coefficients.v 
`default_nettype none
`timescale 1ns / 1ps

module tb_coefficients;
    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  [7:0] value  = 8'b0;     // the coefficient value (Q5.3)
    reg  [1:0] select = 2'b00;    // 00 = A, 01 = B, 10 = C
    reg  load   = 1'b0;     // load not pressed

    wire signed [7:0] coeff_a;
    wire signed [7:0] coeff_b;
    wire signed [7:0] coeff_c;

    coefficients dut (
        .clk(clk), 
        .rst_n(rst_n),
        .value(value),
        .select(select), 
        .load(load),
        .coeff_a(coeff_a),
        .coeff_b(coeff_b),
        .coeff_c(coeff_c)
    ); 

    always #20 clk = ~clk;

    initial begin
        $dumpfile("tb_coefficients.fst");
        $dumpvars(0, tb_coefficients);

        // reset: expect A = 3 : 00011.000, B = -5: 11011.000, C = 2 : 00010.000
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // A = 2.5
        value <= 8'b00010100; 
        load <= 1'b1;
        repeat (10) @(posedge clk);
        load <= 1'b0; 
        
        // B = -2
        select <= 2'b01; 
        value <= 8'b11110000; 
        // check there is a delay until load is pressed 
        repeat (10) @(posedge clk);
        load <= 1'b1; 
        repeat (10) @(posedge clk);

        // C = 1
        select <= 2'b10; 
        value <= 8'b00001000;
        repeat (10) @(posedge clk); 
        load <= 1'b0; 
        repeat (10) @(posedge clk);
        load <= 1'b1; 


        repeat (20) @(posedge clk);

        $finish;
    end

endmodule 
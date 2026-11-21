`default_nettype none
`timescale 1ns / 1ps

module tb_uart_rx;

    reg         clk =   1'b0;
    reg         rst_n = 1'b0;
    reg         rx =    1'b1;
    wire [7:0]       data;
    wire valid;
    wire err; 
    
  
  
    uart_rx dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx         (rx),
        .data    (data),
        .valid    (valid), 
        .err (err)
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
        $dumpfile("tb_uart_rx.fst");
        $dumpvars(0, tb_uart_rx);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (500) @(posedge clk);


        // 'A' in ASCII (65 = 0x41). In the real protocol a letter is sent first
        // to say which coefficient comes next, so this checks the receiver
        // handles those bytes.
        send_coefficient(8'h41);              // 'A'
        // 2.5 in Q5.3: the value is stored x8, so 2.5 x 8 = 20 = 00010100.
        // Checks a positive fractional coefficient.
        send_coefficient(8'd20);              // 2.5 in Q5.3
        // -5 in Q5.3: -5 x 8 = -40. As an 8-bit two's complement number that is
        // 256 - 40 = 216 = 0xD8 = 11011000. Checks a negative value: the top
        // (sign) bit is 1, and it is the last bit sent, so a dropped or
        // reordered bit would give the wrong number.
        send_coefficient(8'hD8);              // -5 in Q5.3 (-40)
        repeat (500) @(posedge clk);

        $finish;
    end

endmodule
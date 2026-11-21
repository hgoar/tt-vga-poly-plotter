// uart_rx.v: 8N1 UART receiver, direct clock counting
// 25 MHz clock / 115200 baud = 217 clocks per bit
// Line idles high. Each byte: start bit (low), 8 data bits LSB first, stop bit (high).

`default_nettype none

module uart_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,        // serial input pin
    output reg  [7:0] data,      // last byte received
    output reg        valid,     // high for one clock when a new byte is in data
    output reg        err        // high for one clock if the stop bit was wrong
);

    localparam [7:0] CLKS_PER_BIT = 8'd217;   // one bit
    localparam [7:0] HALF_BIT     = 8'd108;   // half a bit: the middle

    localparam [1:0] IDLE  = 2'd0,
                     START = 2'd1,
                     DATA  = 2'd2,
                     STOP  = 2'd3;

    // Two flip-flops to synchronise the pin to the clock
    reg rx_s1, rx_s2;
    always @(posedge clk) begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
    end

    reg [1:0] state;
    reg [7:0] clk_cnt;     // clocks within the current bit (0 to 216)
    reg [2:0] bit_idx;     // which data bit (0 to 7)
    reg [7:0] shift_reg;   // the byte being built

    always @(posedge clk) begin
        if (~rst_n) begin
            state     <= IDLE;
            clk_cnt   <= 8'd0;
            bit_idx   <= 3'd0;
            shift_reg <= 8'd0;
            data      <= 8'd0;
            valid     <= 1'b0;
            err       <= 1'b0;
        end else begin
            valid <= 1'b0;                     // pulses: low unless set below
            err   <= 1'b0;

            case (state)
                // Wait for the line to go low: the start bit
                IDLE: begin
                    clk_cnt <= 8'd0;
                    bit_idx <= 3'd0;
                    if (~rx_s2) state <= START;
                end

                // Wait half a bit to reach the middle, check it is still low
                START: begin
                    if (clk_cnt == HALF_BIT - 8'd1) begin
                        clk_cnt <= 8'd0;
                        state   <= rx_s2 ? IDLE : DATA;   // high again = glitch
                    end else begin
                        clk_cnt <= clk_cnt + 8'd1;
                    end
                end

                // Every full bit after that: sample the middle of the next data bit
                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 8'd1) begin
                        clk_cnt   <= 8'd0;
                        shift_reg <= {rx_s2, shift_reg[7:1]};   // LSB arrives first
                        if (bit_idx == 3'd7) state <= STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else begin
                        clk_cnt <= clk_cnt + 8'd1;
                    end
                end

                // One more bit: the stop bit must be high
                STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 8'd1) begin
                        clk_cnt <= 8'd0;
                        state   <= IDLE;
                        if (rx_s2) begin
                            data  <= shift_reg;
                            valid <= 1'b1;
                        end else begin
                            err   <= 1'b1;         // framing error: byte dropped
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 8'd1;
                    end
                end
            endcase
        end
    end

endmodule
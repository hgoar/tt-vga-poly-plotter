`default_nettype none
`timescale 1ns / 1ps

// waveform testbench for controls.v 

module tb_zoom_controls ();

    reg        clk    = 1'b0;
    reg        rst_n  = 1'b0;
    reg        vsync  = 1'b1;
    reg  [5:0] contrl = 6'b0; 
    wire [1:0]         zoom;          
    wire signed [11:0] pan_x; 
    wire signed [11:0] pan_y; 
    wire               zoom_changed; 

    user_controls dut (
        .clk(clk),
        .rst_n(rst_n),
        .vsync(vsync),
        .contrl(contrl),
        .zoom(zoom),
        .pan_x(pan_x),
        .pan_y(pan_y), 
        .zoom_changed(zoom_changed)

    );
    always #20 clk = ~clk;
    task frame;
        begin
            vsync = 0; repeat (40)   @(posedge clk);
            vsync = 1; repeat (4000) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_zoom_controls.vcd");
        $dumpvars(0, tb_zoom_controls);
        
        frame;  
        rst_n = 1;  
        frame;
        
        contrl[0] = 1; 
        frame; 
        frame; 
        contrl[0] = 0; 
        frame;

        repeat (4) begin
            contrl[1] = 1; 
            frame; 
            frame; 
            contrl[1] = 0; 
            frame;
        end

        $finish;
    end
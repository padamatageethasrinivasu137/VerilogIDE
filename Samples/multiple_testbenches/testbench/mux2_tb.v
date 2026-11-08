`timescale 1ns/1ps
module mux2_tb;
    reg  clk = 0;
    reg  a, b, sel;
    wire y;

    mux2 dut (.a(a), .b(b), .sel(sel), .y(y));

    always #5 clk = ~clk;

    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, mux2_tb);
        $monitor("t=%0t a=%b b=%b sel=%b y=%b", $time, a, b, sel, y);
        a = 0; b = 0; sel = 0;
        repeat (16) begin
            @(posedge clk);
            {a, b, sel} = $random;
        end
        #10 $finish;
    end
endmodule

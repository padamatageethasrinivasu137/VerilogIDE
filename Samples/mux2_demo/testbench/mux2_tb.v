`timescale 1ns/1ps
module mux2_tb;
    reg  clk = 0;
    reg  [1:0]a; reg sel;
    wire y;

    mux2 dut (.a(a), .sel(sel), .y(y));

    always #5 clk = ~clk;

    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, mux2_tb);
        $monitor("t=%0t a[0]=%b a[1]=%b sel=%b y=%b", $time, a[0],a[1], sel, y);
        a[0] = 0; a[1] = 0; sel = 0;
        repeat (16) begin
            @(posedge clk);
            {a[0],a[1], sel} = $random;
        end
        #10 $finish;
    end
endmodule

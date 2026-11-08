`timescale 1ns/1ps

module test_project_tb;
    reg  a;
    reg  b;
    wire y;
    integer i;

    test_project dut (
        .a(a),
        .b(b),
        .y(y)
    );

    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, test_project_tb);
        a = 0;
        b = 0;
        for (i = 0; i < 32; i = i + 1) begin
            #10;
            a = $random;
            b = $random;
        end
        #20 $finish;
    end
endmodule

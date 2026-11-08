// 2-to-1 multiplexer
module mux2 (
    input  wire a,
    input  wire b,
    input  wire sel,
    output wire y
);
    assign y = sel ? b : a   // missing semicolon on purpose
endmodule

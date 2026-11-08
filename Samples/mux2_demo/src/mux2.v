`timescale 1ns/1ps

module mux2(
    input logic [1:0] a,
    input logic sel,
    output logic y
);


    assign y = sel ? a[1] : a[0];

endmodule
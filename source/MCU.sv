`timescale 1ns / 1ps

module MCU (
    input logic clk,
    input logic reset
);

    logic [31:0] instrCode, instrMemAddr;
    logic [ 2:0] strb;
    logic        busWe;
    logic [31:0] busAddr;
    logic [31:0] busWData;
    logic [31:0] busRData;

    ROM U_ROM (
        .addr(instrMemAddr),
        .data(instrCode)
    );

    CPU_RV32I U_RV32I (
        .clk         (clk),
        .reset       (reset),
        .instrCode   (instrCode),
        .instrMemAddr(instrMemAddr),
        .strb        (strb),
        .busWe       (busWe),
        .busAddr     (busAddr),
        .busWData    (busWData),
        .busRData    (busRData)
    );

    RAM U_RAM (
        .clk  (clk),
        .strb (strb),
        .we   (busWe),
        .addr (busAddr),
        .wData(busWData),
        .rData(busRData)
    );
endmodule

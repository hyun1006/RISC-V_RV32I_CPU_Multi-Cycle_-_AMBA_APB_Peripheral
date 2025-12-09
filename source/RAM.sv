`timescale 1ns / 1ps

module RAM (
    input  logic        clk,
    input  logic [ 2:0] strb,
    input  logic        we,
    input  logic [ 7:0] addr,
    input  logic [31:0] wData,
    output logic [31:0] rData
);
    logic [7:0] mem[0:2**8-1];

    always_ff @(posedge clk) begin
        if (we) begin
            mem[addr] <= mem[addr];
            case (strb)
                3'b000: begin  // Store Byte
                    mem[addr+0] <= wData[7:0];
                end
                3'b001: begin  // Store Half
                    mem[addr+0] <= wData[7:0];
                    mem[addr+1] <= wData[15:8];
                end
                3'b010: begin  // Store Word
                    mem[addr+0] <= wData[7:0];
                    mem[addr+1] <= wData[15:8];
                    mem[addr+2] <= wData[23:16];
                    mem[addr+3] <= wData[31:24];
                end
            endcase
        end
    end

    always_comb begin
        rData = 0;
        case (strb)
            3'b000: begin  // Load Byte
                rData[7:0]   = mem[addr+0];
                rData[15:8]  = {8{mem[addr+0][7]}};
                rData[23:16] = {8{mem[addr+0][7]}};
                rData[31:24] = {8{mem[addr+0][7]}};
            end

            3'b001: begin  // Load Half
                rData[7:0]   = mem[addr+0];
                rData[15:8]  = mem[addr+1];
                rData[23:16] = {8{mem[addr+1][7]}};
                rData[31:24] = {8{mem[addr+1][7]}};
            end
            3'b010: begin  // Load Word
                rData[7:0]   = mem[addr+0];
                rData[15:8]  = mem[addr+1];
                rData[23:16] = mem[addr+2];
                rData[31:24] = mem[addr+3];
            end
            3'b100: begin  // Load Byte Unsigned
                rData[7:0]   = mem[addr+0];
                rData[15:8]  = 8'b0;
                rData[23:16] = 8'b0;
                rData[31:24] = 8'b0;
            end
            3'b101: begin  // Load Half Unsigned
                rData[7:0]   = mem[addr+0];
                rData[15:8]  = mem[addr+1];
                rData[23:16] = 8'b0;
                rData[31:24] = 8'b0;
            end
        endcase
    end
endmodule

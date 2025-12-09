`timescale 1ns / 1ps

module UART_ph (
    // global signals
    input logic PCLK,
    input logic PRESET,

    // APB Interface Signals
    input  logic [ 3:0] PADDR,
    input  logic        PWRITE,
    input  logic        PENABLE,
    input  logic [31:0] PWDATA,
    input  logic        PSEL,
    output logic [31:0] PRDATA,
    output logic        PREADY,

    // External UART Pins
    input  logic ext_rx,  // 외부에서 들어오는 RX
    output logic ext_tx   // 외부로 나가는 TX
);

    logic [7:0] w_tx_data;  // APB -> UART
    logic [7:0] w_rx_data;  // UART -> APB
    logic       w_tx_start;  // APB -> UART
    logic       w_rx_done;  // UART-> APB
    logic       w_tx_busy;  // UART-> APB


    APB_SlaveIntf_UART U_APB_SlaveIntf_UART (
        // global signals
        .PCLK  (PCLK),
        .PRESET(PRESET),

        // APB Interface Signals
        .PADDR  (PADDR),
        .PWRITE (PWRITE),
        .PENABLE(PENABLE),
        .PWDATA (PWDATA),
        .PSEL   (PSEL),
        .PRDATA (PRDATA),
        .PREADY (PREADY),

        // UART
        .tx_data (w_tx_data),
        .rx_data (w_rx_data),
        .tx_start(w_tx_start),
        .rx_done (w_rx_done),
        .tx_busy (w_tx_busy)
    );

    uart_top U_uart_top (
        .PCLK    (PCLK),
        .PRESET  (PRESET),
        .rx      (ext_rx),
        .tx      (ext_tx),
        .tx_data (w_tx_data),
        .rx_data (w_rx_data),
        .tx_start(w_tx_start),
        .rx_done (w_rx_done),
        .tx_busy (w_tx_busy)
    );
endmodule


module APB_SlaveIntf_UART (
    // global signals
    input logic PCLK,
    input logic PRESET,

    // APB Interface Signals
    input  logic [ 3:0] PADDR,
    input  logic        PWRITE,
    input  logic        PENABLE,
    input  logic [31:0] PWDATA,
    input  logic        PSEL,
    output logic [31:0] PRDATA,
    output logic        PREADY,

    // UART
    input  logic [7:0] rx_data,   // From UART
    output logic [7:0] tx_data,   // To UART
    output logic       tx_start,  // To UART
    input  logic       rx_done,   // From UART
    input  logic       tx_busy    // From UART
);
    // Internal Registers
    logic [7:0] slv_reg0;  // 0x0000: TX_Data Register
    logic [7:0] slv_reg1;  // 0x0004: RX_Data Register
    logic [7:0] slv_reg2;  // 0x0008: Status Register

    logic rx_data_ready;

    assign tx_data = slv_reg0[7:0];

    always_ff @(posedge PCLK, posedge PRESET) begin
        if (PRESET) begin
            slv_reg0      <= 0;
            slv_reg1      <= 0;
            slv_reg2      <= 0;
            PREADY        <= 1'b0;
            tx_start      <= 1'b0;
            rx_data_ready <= 1'b0;
        end else begin
            PREADY         <= 1'b0;
            tx_start       <= 1'b0;

            slv_reg2[0]    <= tx_busy;  // 전송중임?
            slv_reg2[1]    <= rx_data_ready;  // 새 데이터 있음?
            slv_reg2[7:2] <= 0;


            if (rx_done) begin
                slv_reg1 <= rx_data;
                rx_data_ready <= 1'b1;
            end

            if (PSEL && PENABLE) begin
                PREADY <= 1'b1;

                if (PWRITE) begin
                    case (PADDR[3:2])
                        2'h0: begin
                            slv_reg0 <= PWDATA[7:0];
                            if (!tx_busy) begin
                                tx_start <= 1'b1;
                            end
                        end
                        2'h1: ;
                        2'h2: slv_reg2 <= PWDATA[7:0];
                        2'h3: ;
                    endcase
                end else begin
                    PRDATA <= 0;
                    case (PADDR[3:2])
                        2'h0: PRDATA <= {24'b0, slv_reg0};
                        2'h1: begin
                            PRDATA <= {24'b0, slv_reg1};
                            //rx_data_ready <= 1'b0;
                        end
                        2'h2: PRDATA <= {24'b0, slv_reg2};
                        2'h3: ;
                    endcase
                end
            end
        end
    end
endmodule


// =================================== UART 코드 =================================== //
module uart_top (
    input  logic PCLK,
    input  logic PRESET,
    input  logic rx,
    output logic tx,

    // --- Ports to APB Slave ---
    input  logic [7:0] tx_data,
    output logic [7:0] rx_data,
    input  logic       tx_start,
    output logic       rx_done,
    output logic       tx_busy
);

    baud_tick_gen U_BAUD_TICK (
        .PCLK    (PCLK),
        .PRESET  (PRESET),
        .o_b_tick(b_tick)
    );

    uart_rx U_UART_RX (
        .PCLK   (PCLK),
        .PRESET (PRESET),
        .rx     (rx),
        .b_tick (b_tick),
        .rx_data(rx_data),
        .rx_done(rx_done)
    );

    uart_tx U_UART_TX (
        .PCLK    (PCLK),
        .PRESET  (PRESET),
        .tx_start(tx_start),
        .tx_data (tx_data),
        .b_tick  (b_tick),
        .tx_busy (tx_busy),
        .tx      (tx)
    );
endmodule


module uart_tx (
    input  logic       PCLK,
    input  logic       PRESET,
    input  logic       tx_start,
    input  logic [7:0] tx_data,
    input  logic       b_tick,
    output logic       tx_busy,
    output logic       tx
);

    localparam [1:0] IDLE = 2'b00, TX_START = 2'b01, TX_DATA = 2'b10, TX_STOP = 2'b11;
    reg [1:0] state_reg, state_next;
    reg tx_busy_reg, tx_busy_next;
    reg tx_reg, tx_next;
    reg [7:0] data_buf_reg, data_buf_next;
    reg [3:0] b_tick_cnt_reg, b_tick_cnt_next;
    reg [2:0] bit_cnt_reg, bit_cnt_next;

    assign tx_busy = tx_busy_reg;
    //assign tx_busy = (state_reg != IDLE);  //수정
    assign tx = tx_reg;

    always @(posedge PCLK, posedge PRESET) begin
        if (PRESET) begin
            state_reg      <= IDLE;
            tx_busy_reg    <= 1'b0;
            tx_reg         <= 1'b1;
            data_buf_reg   <= 8'h00;
            b_tick_cnt_reg <= 4'b0000;
            bit_cnt_reg    <= 3'b000;
        end else begin
            state_reg      <= state_next;
            tx_busy_reg    <= tx_busy_next;
            tx_reg         <= tx_next;
            data_buf_reg   <= data_buf_next;
            b_tick_cnt_reg <= b_tick_cnt_next;
            bit_cnt_reg    <= bit_cnt_next;
        end
    end

    always @(*) begin
        state_next      = state_reg;
        tx_busy_next    = tx_busy_reg;
        tx_next         = tx_reg;
        data_buf_next   = data_buf_reg;
        b_tick_cnt_next = b_tick_cnt_reg;
        bit_cnt_next    = bit_cnt_reg;

        case (state_reg)
            IDLE: begin
                tx_next = 1'b1;
                tx_busy_next = 1'b0;
                if (tx_start) begin
                    b_tick_cnt_next = 0;  // modified
                    data_buf_next   = tx_data;
                    state_next      = TX_START;
                end
            end

            TX_START: begin
                tx_next = 1'b0;
                tx_busy_next = 1'b1;
                if (b_tick) begin
                    if (b_tick_cnt_reg == 15) begin
                        b_tick_cnt_next = 0;
                        bit_cnt_next    = 0;
                        state_next      = TX_DATA;
                    end else begin
                        b_tick_cnt_next = b_tick_cnt_reg + 1;
                    end
                end
            end

            TX_DATA: begin
                tx_next = data_buf_reg[0];
                if (b_tick) begin
                    if (b_tick_cnt_reg == 15) begin
                        if (bit_cnt_reg == 7) begin
                            b_tick_cnt_next = 0;
                            state_next = TX_STOP;
                        end else begin
                            b_tick_cnt_next = 0;
                            bit_cnt_next    = bit_cnt_reg + 1;
                            data_buf_next   = data_buf_reg >> 1;
                        end
                    end else begin
                        b_tick_cnt_next = b_tick_cnt_reg + 1;
                    end
                end
            end

            TX_STOP: begin
                tx_next = 1'b1;
                if (b_tick) begin
                    if (b_tick_cnt_reg == 15) begin
                        state_next = IDLE;
                    end else begin
                        b_tick_cnt_next = b_tick_cnt_reg + 1;
                    end
                end
            end
        endcase
    end
endmodule


module uart_rx (
    input  logic       PCLK,
    input  logic       PRESET,
    input  logic       rx,
    input  logic       b_tick,
    output logic [7:0] rx_data,
    output logic       rx_done
);

    localparam [1:0] IDLE = 2'b00, RX_START = 2'b01, RX_DATA = 2'b10, RX_STOP = 2'b11;
    logic [1:0] state_reg, state_next;

    logic rx_done_reg, rx_done_next;
    logic [7:0] data_buf_reg, data_buf_next;
    logic [4:0] b_tick_cnt_reg, b_tick_cnt_next;
    logic [2:0] bit_cnt_reg, bit_cnt_next;

    assign rx_data = data_buf_reg;
    assign rx_done = rx_done_reg;

    always @(posedge PCLK, posedge PRESET) begin
        if (PRESET) begin
            state_reg      <= IDLE;
            rx_done_reg    <= 0;
            data_buf_reg   <= 0;
            b_tick_cnt_reg <= 0;
            bit_cnt_reg    <= 0;
        end else begin
            state_reg      <= state_next;
            rx_done_reg    <= rx_done_next;
            data_buf_reg   <= data_buf_next;
            b_tick_cnt_reg <= b_tick_cnt_next;
            bit_cnt_reg    <= bit_cnt_next;
        end
    end


    always @(*) begin
        state_next      = state_reg;
        rx_done_next    = rx_done_reg;
        data_buf_next   = data_buf_reg;
        b_tick_cnt_next = b_tick_cnt_reg;
        bit_cnt_next    = bit_cnt_reg;

        case (state_reg)
            IDLE: begin
                rx_done_next = 1'b0;
                if (rx == 1'b0) begin
                    state_next = RX_START;
                end
            end

            RX_START: begin
                if (b_tick) begin
                    if (b_tick_cnt_reg == 23) begin
                        b_tick_cnt_next  = 0;
                        bit_cnt_next     = 0;
                        data_buf_next[7] = rx;
                        state_next       = RX_DATA;
                    end else begin
                        b_tick_cnt_next = b_tick_cnt_reg + 1;
                    end
                end
            end

            RX_DATA: begin
                if (b_tick) begin
                    if (b_tick_cnt_reg == 15) begin
                        b_tick_cnt_next = 0;  // if(bit_cnt_reg == 6)
                        data_buf_next = data_buf_reg >> 1;  // 안에서 위로
                        data_buf_next[7] = rx;  // 끌어올림
                        if (bit_cnt_reg == 6) begin  // 7 -> 6 으로 횟수 변경
                            // bit_cnt_next = 0;
                            state_next = RX_STOP;
                        end else begin
                            // b_tick_cnt_next = 0;
                            bit_cnt_next = bit_cnt_reg + 1;
                        end
                    end else begin
                        b_tick_cnt_next = b_tick_cnt_reg + 1;
                    end
                end
            end

            RX_STOP: begin
                if (b_tick) begin
                    if (b_tick_cnt_reg == 15) begin
                        b_tick_cnt_next = 0;
                        rx_done_next    = 1'b1;  // 추가하여 done 타이밍 문제 해결
                        state_next = IDLE;
                    end else begin
                        b_tick_cnt_next = b_tick_cnt_reg + 1;
                    end
                end
            end
        endcase
    end
endmodule


module baud_tick_gen (
    input  logic PCLK,
    input  logic PRESET,
    output logic o_b_tick
);

    // 100_000_0000 / baud*16
    parameter BAUD = 9600;
    parameter BAUD_TICK_COUNT = 100_000_000 / BAUD / 16;

    logic [$clog2(BAUD_TICK_COUNT)-1:0] counter_reg;
    logic b_tick_reg;

    assign o_b_tick = b_tick_reg;

    always @(posedge PCLK, posedge PRESET) begin
        if (PRESET) begin
            counter_reg <= 0;
            b_tick_reg  <= 1'b0;
        end else begin
            if (counter_reg == BAUD_TICK_COUNT - 1) begin
                counter_reg <= 0;
                b_tick_reg  <= 1'b1;
            end else begin
                counter_reg <= counter_reg + 1;
                b_tick_reg  <= 1'b0;
            end
        end
    end
endmodule

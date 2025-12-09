`timescale 1ns / 1ps

interface apb_master_if (
    input logic PCLK,
    input logic PRESET
);
    logic        transfer;
    logic        write;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic [31:0] rdata;
    logic        ready;
    logic        rx;
    logic        tx;
endinterface


class transaction;
    logic      [31:0] rdata;  // APB 읽기 결과 저장
    rand logic [31:0] addr;  // 주소 랜덤 생성
    rand logic [31:0] wdata;  // APB 쓰기 데이터 랜덤 생성

    // UART 검증
    rand logic [ 7:0] send_data;  // RX 검증 시 UART로 보낼 데이터
    logic      [ 7:0] received_data;  // TX 검증 시 UART에서 받은 데이터

    constraint c_addr {addr inside {32'h1000_4000, 32'h1000_4004};}

    // wdata 제약 조건: TX 주소일 때만 의미있는 값 생성
    constraint c_wdata_logic {
        if (addr == 32'h1000_4000) {
            wdata[31:8] == 0;
            wdata[7:0] inside {[8'h01 : 8'hFF]};  // 0 아닌 8비트 값
        } else {  // RX 주소이면 (쓰기 의미 없음)
            wdata == 32'h0;
        }
    }

    constraint c_send_data {send_data inside {[8'h01 : 8'hFF]};}

    task automatic print(string name);
        $display("[%s] APB_wdata:%h, UART_send:%h, UART_receive:%h, APB_rdata:%h", name, wdata[7:0], send_data, received_data,
                 rdata);
    endtask
endclass


class apbSignal;
    transaction t;
    virtual apb_master_if m_if;

    int pass_tx = 0, fail_tx = 0, total_tx = 0;
    int pass_rx = 0, fail_rx = 0, total_rx = 0;
    int pass_done = 0, fail_done = 0, total_done = 0;

    int BIT_PERIOD = 104160;

    parameter TX_ADDR = 32'h1000_4000;
    parameter RX_ADDR = 32'h1000_4004;
    parameter STAT_ADDR = 32'h1000_4008;

    function new(virtual apb_master_if m_if);
        this.m_if = m_if;
        this.t = new();
    endfunction

    // --- APB 태스크 ---
    task automatic apb_write(input logic [31:0] adr, input logic [31:0] dat);
        @(posedge m_if.PCLK);
        m_if.transfer <= 1'b1;
        m_if.write    <= 1'b1;
        m_if.addr     <= adr;
        m_if.wdata    <= dat;
        @(posedge m_if.PCLK);
        m_if.transfer <= 1'b0;
        wait (m_if.ready);
        @(posedge m_if.PCLK);
    endtask

    task automatic apb_read(input logic [31:0] adr);
        @(posedge m_if.PCLK);
        m_if.transfer <= 1'b1;
        m_if.write    <= 1'b0;
        m_if.addr     <= adr;
        @(posedge m_if.PCLK);
        m_if.transfer <= 1'b0;
        wait (m_if.ready);
        t.rdata = m_if.rdata;  // 결과 저장
        @(posedge m_if.PCLK);
    endtask

    // --- UART 태스크 ---
    task automatic uart_write(input logic [7:0] s_data);
        m_if.rx = 1'b0;
        #(BIT_PERIOD);  // Start
        for (int i = 0; i < 8; i++) begin
            m_if.rx = s_data[i];
            #(BIT_PERIOD);
        end  // Data
        m_if.rx = 1'b1;
        #(BIT_PERIOD);  // Stop
    endtask

    task automatic uart_read();  // m_if.tx 모니터링, 결과를 t.received_data에 저장
        //@(negedge m_if.tx);  // Start 대기
        #(BIT_PERIOD / 2);  // 중간 이동
        for (int i = 0; i < 8; i++) begin
            #(BIT_PERIOD);
            t.received_data[i] = m_if.tx;
        end  // Data
        #(BIT_PERIOD);  // Stop 위치
    endtask

    task automatic check();
        // TX 검증: APB wdata == UART received_data
        total_tx++;
        if (t.wdata[7:0] == t.received_data) begin
            pass_tx++;
            $display("PASS! TX: APB_wdata %h == UART_receivedData %h", t.wdata[7:0], t.received_data);
        end else begin
            fail_tx++;
            $display("FAIL.. TX: APB_wdata %h != UART_receivedData %h", t.wdata[7:0], t.received_data);
        end

        // RX 검증: UART send_data == APB rdata
        total_rx++;
        if (t.rdata[7:0] == t.send_data) begin
            pass_rx++;
            $display("PASS! RX: UART_send %h == APB_rdata %h", t.send_data, t.rdata[7:0]);
        end else begin
            fail_rx++;
            $display("FAIL.. RX: UART_send %h != APB_rdata %h", t.send_data, t.rdata[7:0]);
        end
        $display("");
    endtask


    task report();
        $display("=========== Test Report ===========");
        $display("==       | Total | Pass  | Fail  ==");
        $display("-----------------------------------");
        $display("== TX    | %5d | %5d | %5d ==", total_tx, pass_tx, fail_tx);
        $display("== RX    | %5d | %5d | %5d ==", total_rx, pass_rx, fail_rx);
        $display("== Done  | %5d | %5d | %5d ==", total_done, pass_done, fail_done);
        $display("===================================\n");
    endtask


    task automatic run(int loop);
        repeat (loop) begin
            t.randomize();
            apb_write(TX_ADDR, t.wdata);
            repeat (5) @(posedge m_if.PCLK);
            uart_read();

            uart_write(t.send_data);
            apb_read(RX_ADDR);

            check();

            apb_read(STAT_ADDR);
            total_done++;
            if (t.rdata[1] == 1) begin  // 1번 비트 확인
                $display("done PASS!");
                pass_done++;
            end else begin
                $display("done FAIL..");
                fail_done++;
            end
        end
        report();
    endtask  // run
endclass


module tb_master_uart ();
    localparam PCLK_PERIOD = 10;  // 100MHz

    logic        PCLK;
    logic        PRESET;
    logic [31:0] PADDR;
    logic        PWRITE;
    logic        PENABLE;
    logic [31:0] PWDATA;
    logic PSEL0, PSEL1, PSEL2, PSEL3, PSEL4;
    logic [31:0] PRDATA0, PRDATA1, PRDATA2, PRDATA3, PRDATA_UART;
    logic PREADY0, PREADY1, PREADY2, PREADY3, PREADY_UART;

    logic ext_rx;
    logic ext_tx;

    apb_master_if m_if (
        .PCLK  (PCLK),
        .PRESET(PRESET)
    );

    APB_Master dut_master (
        .PCLK    (PCLK),
        .PRESET  (PRESET),
        .PADDR   (PADDR),
        .PWRITE  (PWRITE),
        .PENABLE (PENABLE),
        .PWDATA  (PWDATA),
        .PSEL0   (PSEL0),
        .PSEL1   (PSEL1),
        .PSEL2   (PSEL2),
        .PSEL3   (PSEL3),
        .PSEL4   (PSEL4),
        .PRDATA0 (PRDATA0),
        .PRDATA1 (PRDATA1),
        .PRDATA2 (PRDATA2),
        .PRDATA3 (PRDATA3),
        .PRDATA4 (PRDATA_UART),
        .PREADY0 (PREADY0),
        .PREADY1 (PREADY1),
        .PREADY2 (PREADY2),
        .PREADY3 (PREADY3),
        .PREADY4 (PREADY_UART),
        .transfer(m_if.transfer),
        .write   (m_if.write),
        .addr    (m_if.addr),
        .wdata   (m_if.wdata),
        .rdata   (m_if.rdata),
        .ready   (m_if.ready)
    );

    UART_ph dut_uart (
        .PCLK   (PCLK),
        .PRESET (PRESET),
        .PADDR  (PADDR[3:0]),
        .PWRITE (PWRITE),
        .PENABLE(PENABLE),
        .PWDATA (PWDATA),
        .PSEL   (PSEL4),
        .PRDATA (PRDATA_UART),
        .PREADY (PREADY_UART),
        .ext_rx (m_if.rx),
        .ext_tx (m_if.tx)
    );

    assign PSEL0   = 1'b0;
    assign PSEL1   = 1'b0;
    assign PSEL2   = 1'b0;
    assign PSEL3   = 1'b0;
    assign PRDATA0 = 32'h0;
    assign PRDATA1 = 32'h0;
    assign PRDATA2 = 32'h0;
    assign PRDATA3 = 32'h0;
    assign PREADY0 = 1'b0;
    assign PREADY1 = 1'b0;
    assign PREADY2 = 1'b0;
    assign PREADY3 = 1'b0;

    // --- UART RX 핀 Idle 상태 설정 ---
    initial begin
        ext_rx = 1'b1;
    end

    initial begin
        PCLK = 1'b0;
        forever #(PCLK_PERIOD / 2) PCLK = ~PCLK;
    end

    initial begin
        PRESET = 1'b1;
        repeat (3) @(posedge PCLK);
        PRESET = 1'b0;
    end

    // --- 테스트 실행 ---
    initial begin
        apbSignal apbSignalTester;
        apbSignalTester = new(m_if);
        repeat (3) @(posedge PCLK);

        $display("\n\n--- Start UART TX/RX Reg Test ---");
        apbSignalTester.run(50);

        repeat (2) @(posedge PCLK);
        $display("--- Test Finished ---\n\n");
        $finish;
    end
endmodule



// `timescale 1ns / 1ps

// interface apb_master_if (
//     input logic PCLK,
//     input logic PRESET
// );
//     logic        transfer;
//     logic        write;
//     logic [31:0] addr;
//     logic [31:0] wdata;
//     logic [31:0] rdata;
//     logic        ready;
//     logic        rx;
//     logic        tx;
// endinterface


// class transaction;
//     logic      [31:0] rdata;  // 읽기 결과 저장
//     rand logic [31:0] addr;  // 주소 랜덤 생성 (TX 또는 RX)
//     rand logic [31:0] wdata;  // 쓰기 데이터 랜덤 생성

//     constraint c_addr {addr inside {32'h1000_4000, 32'h1000_4004};}

//     // wdata 제약 조건: TX 주소일 때만 의미있는 값 생성
//     constraint c_wdata_logic {
//         if (addr == 32'h1000_4000) {  // TX 주소이면
//             wdata[31:8] == 0;
//             wdata[7:0] inside {[8'h01 : 8'hFF]};  // 0 아닌 8비트 값
//         } else {  // RX 주소이면 (쓰기 의미 없음)
//             wdata == 32'h0;  // 0으로 고정
//         }
//     }

//     task automatic print(string name);
//         $display("[%s], addr = %h, wdata = %h, rdata = %h", name, addr, wdata, rdata);
//     endtask
// endclass


// class apbSignal;
//     transaction t;
//     virtual apb_master_if m_if;

//     function new(virtual apb_master_if m_if);
//         this.m_if = m_if;
//         this.t    = new();
//     endfunction

//     // APB 쓰기 태스크
//     task automatic send();
//         m_if.transfer <= 1'b1;
//         m_if.write    <= 1'b1;  // 항상 쓰기
//         m_if.addr     <= t.addr;  // 랜덤 주소 (TX or RX)
//         m_if.wdata    <= t.wdata;  // 랜덤 데이터 (RX 주소면 0)
//         t.print(" SEND  ");
//         @(posedge m_if.PCLK);
//         m_if.transfer <= 1'b0;
//         @(posedge m_if.PCLK);
//         wait (m_if.ready);
//         @(posedge m_if.PCLK);
//     endtask

//     // APB 읽기 태스크
//     task automatic receive();
//         m_if.transfer <= 1'b1;
//         m_if.write    <= 1'b0;  // 항상 읽기
//         m_if.addr     <= t.addr;  // send에서 사용한 주소와 동일
//         t.print("RECEIVE");
//         @(posedge m_if.PCLK);
//         m_if.transfer <= 1'b0;
//         @(posedge m_if.PCLK);
//         wait (m_if.ready);
//         t.rdata = m_if.rdata;  // 읽은 데이터 저장
//         @(posedge m_if.PCLK);
//     endtask


//     task automatic compare();
//         if (t.addr == 32'h1000_4000) begin  // TX Register 주소이면  (0x10004000)
//             if (t.rdata == t.wdata)  // 쓴 값과 읽은 값 비교
//                 $display("PASS! TX_REG Match (Addr: %h, SendData: 0x%h, ReceivedData: 0x%h)\n", t.addr, t.wdata, t.rdata);
//             else $display("FAIL. TX_REG Mismatch (Addr: %h, SendData: 0x%h, ReceivedData: 0x%h)\n", t.addr, t.wdata, t.rdata);
//         end else begin  // RX Register 주소이면 (0x10004004)
//             // 읽기이므로 값 비교 없이 정보만 표시
//             $display("INFO: Read RX_REG (Addr: %h, ReceivedData: 0x%h)\n", t.addr, t.rdata);
//         end
//     endtask


//     task automatic run(int loop);
//         repeat (loop) begin
//             t.randomize();
//             send();
//             receive();
//             compare();

//             repeat (2) @(posedge m_if.PCLK);
//         end
//     endtask
// endclass


// module tb_master_uart ();
//     localparam PCLK_PERIOD = 10;  // 100MHz

//     logic        PCLK;
//     logic        PRESET;
//     logic [31:0] PADDR;
//     logic        PWRITE;
//     logic        PENABLE;
//     logic [31:0] PWDATA;
//     logic PSEL0, PSEL1, PSEL2, PSEL3, PSEL4;
//     logic [31:0] PRDATA0, PRDATA1, PRDATA2, PRDATA3, PRDATA_UART;
//     logic PREADY0, PREADY1, PREADY2, PREADY3, PREADY_UART;

//     logic ext_rx;
//     logic ext_tx;

//     apb_master_if m_if (
//         .PCLK  (PCLK),
//         .PRESET(PRESET)
//     );

//     APB_Master dut_master (
//         .PCLK    (PCLK),
//         .PRESET  (PRESET),
//         .PADDR   (PADDR),
//         .PWRITE  (PWRITE),
//         .PENABLE (PENABLE),
//         .PWDATA  (PWDATA),
//         .PSEL0   (PSEL0),
//         .PSEL1   (PSEL1),
//         .PSEL2   (PSEL2),
//         .PSEL3   (PSEL3),
//         .PSEL4   (PSEL4),
//         .PRDATA0 (PRDATA0),
//         .PRDATA1 (PRDATA1),
//         .PRDATA2 (PRDATA2),
//         .PRDATA3 (PRDATA3),
//         .PRDATA4 (PRDATA_UART),
//         .PREADY0 (PREADY0),
//         .PREADY1 (PREADY1),
//         .PREADY2 (PREADY2),
//         .PREADY3 (PREADY3),
//         .PREADY4 (PREADY_UART),
//         .transfer(m_if.transfer),
//         .write   (m_if.write),
//         .addr    (m_if.addr),
//         .wdata   (m_if.wdata),
//         .rdata   (m_if.rdata),
//         .ready   (m_if.ready)
//     );

//     UART_ph dut_uart (
//         .PCLK   (PCLK),
//         .PRESET (PRESET),
//         .PADDR  (PADDR[3:0]),
//         .PWRITE (PWRITE),
//         .PENABLE(PENABLE),
//         .PWDATA (PWDATA),
//         .PSEL   (PSEL4),
//         .PRDATA (PRDATA_UART),
//         .PREADY (PREADY_UART),
//         .ext_rx (ext_rx),
//         .ext_tx (ext_tx)
//     );

//     assign PSEL0   = 1'b0;
//     assign PSEL1   = 1'b0;
//     assign PSEL2   = 1'b0;
//     assign PSEL3   = 1'b0;
//     assign PRDATA0 = 32'h0;
//     assign PRDATA1 = 32'h0;
//     assign PRDATA2 = 32'h0;
//     assign PRDATA3 = 32'h0;
//     assign PREADY0 = 1'b0;
//     assign PREADY1 = 1'b0;
//     assign PREADY2 = 1'b0;
//     assign PREADY3 = 1'b0;

//     // --- UART RX 핀 Idle 상태 설정 ---
//     initial begin
//         ext_rx = 1'b1;
//     end

//     initial begin
//         PCLK = 1'b0;
//         forever #(PCLK_PERIOD / 2) PCLK = ~PCLK;
//     end

//     // --- 리셋 ---
//     initial begin
//         PRESET = 1'b1;
//         repeat (3) @(posedge PCLK);
//         PRESET = 1'b0;
//     end

//     // --- 테스트 실행 ---
//     initial begin
//         apbSignal apbSignalTester;
//         apbSignalTester = new(m_if);

//         @(negedge PRESET);
//         repeat (3) @(posedge PCLK);

//         $display("\n\n--- Start UART TX/RX Reg Test ---");
//         apbSignalTester.run(50);

//         repeat (2) @(posedge PCLK);
//         $display("--- Test Finished ---\n\n");
//         $finish;
//     end
// endmodule

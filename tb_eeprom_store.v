`timescale 1ns/1ps
// eeprom_store + i2c_byte_master against a behavioural 24LC32 model:
//  1. LOAD a pre-written image: all 30 template slots (4-bit packed), means and counts reach the matcher RAM.
//  2. SAVE person 1 (4 templates): data, ack polling during the write cycle, header written last,
//     other persons' data untouched.
//  3. Blank EEPROM -> status NEW. 4. No EEPROM on the bus -> status ERR (no hang).
module tb_eeprom_store;
    reg clk = 0; always #20 clk = ~clk;
    wire sda, scl, sda_oe;
    pullup (sda);
    assign sda = sda_oe ? 1'b0 : 1'bz;
    eeprom_model #(.T_WC_NS(100000)) rom (.sda(sda), .scl(scl));

    reg reload = 0, save_req = 0; reg [1:0] save_id = 0; reg [3:0] c0 = 0, c1 = 0, c2 = 0;
    wire io_busy, io_we, io_mean_we, io_cnt_we; wire [13:0] io_raddr, io_waddr; wire [7:0] io_wdata, io_mean_val;
    wire [5:0] io_mean_slot; wire [1:0] io_cnt_id, busy_id; wire [3:0] io_cnt_val; wire [2:0] status;
    reg [7:0] ram [0:16383]; reg [7:0] rdata; reg [7:0] means [0:63]; reg [3:0] cnt [0:3];
    always @(posedge clk) begin
        if (io_we) ram[io_waddr] <= io_wdata;
        rdata <= ram[io_raddr];
        if (io_mean_we) means[io_mean_slot] <= io_mean_val;
        if (io_cnt_we) cnt[io_cnt_id] <= io_cnt_val;
    end
    eeprom_store #(.DIV(3), .BOOT_DELAY(50)) dut (.clk(clk), .scl(scl), .sda_oe(sda_oe), .sda_i(sda),
        .reload(reload), .io_busy(io_busy), .io_raddr(io_raddr), .io_rdata(rdata), .io_we(io_we),
        .io_waddr(io_waddr), .io_wdata(io_wdata), .io_mean_we(io_mean_we), .io_mean_slot(io_mean_slot),
        .io_mean_val(io_mean_val), .io_cnt_we(io_cnt_we), .io_cnt_id(io_cnt_id), .io_cnt_val(io_cnt_val),
        .save_req(save_req), .save_id(save_id), .cur_cnt0(c0), .cur_cnt1(c1), .cur_cnt2(c2),
        .status(status), .busy_id(busy_id));

    // second store on a bus with nothing attached
    wire sda2, scl2, sda_oe2; pullup (sda2); assign sda2 = sda_oe2 ? 1'b0 : 1'bz;
    wire io_busy2; wire [2:0] status2;
    eeprom_store #(.DIV(3), .BOOT_DELAY(50)) dut2 (.clk(clk), .scl(scl2), .sda_oe(sda_oe2), .sda_i(sda2),
        .reload(1'b0), .io_busy(io_busy2), .io_raddr(), .io_rdata(8'd0), .io_we(), .io_waddr(), .io_wdata(),
        .io_mean_we(), .io_mean_slot(), .io_mean_val(), .io_cnt_we(), .io_cnt_id(), .io_cnt_val(),
        .save_req(1'b0), .save_id(2'd0), .cur_cnt0(4'd0), .cur_cnt1(4'd0), .cur_cnt2(4'd0),
        .status(status2), .busy_id());

    // 4-bit cell value of template t, cell p; RAM holds it as {nibble,4'b1000}
    function [3:0] nib(input integer t, input integer pix);  nib  = (t * 7 + pix * 5 + 3) & 15; endfunction
    function [3:0] nib2(input integer t, input integer pix); nib2 = (t * 11 + pix * 3 + 9) & 15; endfunction
    function [7:0] ramv(input [3:0] n); ramv = {n, 4'b1000}; endfunction
    integer t, p, sl, errors, sum, a, k;
    initial begin
        // pre-written image: counts 10, 7, 2 (template index = person*10 + slot)
        rom.mem[0] = 8'hA5; rom.mem[1] = 8'h02; rom.mem[2] = 10; rom.mem[3] = 7; rom.mem[4] = 2;
        for (t = 0; t < 30; t = t + 1) for (k = 0; k < 128; k = k + 1) rom.mem[16 + t*128 + k] = {nib(t, 2*k), nib(t, 2*k+1)};
        errors = 0;
        wait (io_busy === 1'b0);
        if (status !== 3'd1) $fatal(1, "load status %0d, expected OK", status);
        if (cnt[0] !== 10 || cnt[1] !== 7 || cnt[2] !== 2) $fatal(1, "counts %0d %0d %0d", cnt[0], cnt[1], cnt[2]);
        for (t = 0; t < 30; t = t + 1) begin
            sum = 0;
            for (p = 0; p < 256; p = p + 1) begin
                a = (((t/10) * 16 + (t % 10)) << 8) + p;
                if (ram[a] !== ramv(nib(t, p))) errors = errors + 1;
                sum = sum + ramv(nib(t, p));
            end
            if (means[(t/10)*16 + (t%10)] !== (sum >> 8)) begin errors = errors + 1; $display("mean t=%0d got %0d want %0d", t, means[(t/10)*16+(t%10)], sum >> 8); end
        end
        if (errors) $fatal(1, "%0d load mismatches", errors);
        $display("load OK: 30 template slots, means, counts");

        // --- save person 1 with 9 new templates (slots 0..8; slot 9 of person 1 must stay as it was) ---
        for (sl = 0; sl < 10; sl = sl + 1) for (p = 0; p < 256; p = p + 1) ram[((16 + sl) << 8) + p] = ramv(nib2(sl, p));
        c0 = 10; c1 = 9; c2 = 2;
        @(negedge clk); save_id = 1; save_req = 1; @(negedge clk); save_req = 0;
        repeat (20) @(negedge clk);
        if (io_busy !== 1'b1 || status !== 3'd4 || busy_id !== 2'd1) $fatal(1, "save did not start (busy=%b status=%0d)", io_busy, status);
        wait (io_busy === 1'b0);
        if (status !== 3'd1) $fatal(1, "save status %0d", status);
        for (sl = 0; sl < 10; sl = sl + 1) for (k = 0; k < 128; k = k + 1) begin
            t = 10 + sl;
            if (sl < 9) begin if (rom.mem[16 + t*128 + k] !== {nib2(sl, 2*k), nib2(sl, 2*k+1)}) errors = errors + 1; end
            else        begin if (rom.mem[16 + t*128 + k] !== {nib(t, 2*k), nib(t, 2*k+1)}) errors = errors + 1; end   // slot 9 untouched
        end
        for (t = 0; t < 10; t = t + 1) for (k = 0; k < 128; k = k + 1) begin
            if (rom.mem[16 + t*128 + k] !== {nib(t, 2*k), nib(t, 2*k+1)}) errors = errors + 1;
            if (rom.mem[16 + (20+t)*128 + k] !== {nib(20+t, 2*k), nib(20+t, 2*k+1)}) errors = errors + 1;
        end
        if (rom.mem[0] !== 8'hA5 || rom.mem[1] !== 8'h02 || rom.mem[2] !== 10 || rom.mem[3] !== 9 || rom.mem[4] !== 2)
            errors = errors + 1;
        if (errors) $fatal(1, "%0d save mismatches (hdr %h %h %0d %0d %0d)", errors, rom.mem[0], rom.mem[1], rom.mem[2], rom.mem[3], rom.mem[4]);
        $display("save OK: person 1 written (%0d EEPROM byte writes), others untouched, header updated last", rom.writes_total);

        // --- blank EEPROM -> NEW ---
        for (a = 0; a < 4096; a = a + 1) rom.mem[a] = 8'hFF;
        @(negedge clk); reload = 1; @(negedge clk); reload = 0;
        repeat (20) @(negedge clk);
        wait (io_busy === 1'b0);
        if (status !== 3'd2) $fatal(1, "blank EEPROM status %0d (want NEW=2)", status);
        $display("blank EEPROM -> NEW");

        // --- no device on the bus -> ERR ---
        wait (io_busy2 === 1'b0);
        if (status2 !== 3'd3) $fatal(1, "missing EEPROM status %0d (want ERR=3)", status2);
        $display("PASS: tb_eeprom_store - load, save with ack polling, header last, blank = NEW, absent device = ERR");
        $finish;
    end
    initial begin #2000000000; $fatal(1, "eeprom test timeout"); end
endmodule

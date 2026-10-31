`timescale 1ns/1ps
// System test with synthetic "faces" streamed through
//   face_crop_16x16 -> live_face_matcher <-> eeprom_store <-> EEPROM model
//   -> presence_tracker -> attendance_latch
// Persons: 0 = A (wide eyes, full beard), 1 = B (narrow eyes, stubble, big hair),
// 2 = S (close eyes, nose shadow), 3 = stranger, 9 = blank wall. Images are procedural
// stand-ins, so this checks the LOGIC (enrol, save, power-cycle persistence, match,
// lock, hold, rescan, reject, write protection), not real-face accuracy.
//
// Two runs share one EEPROM image file (a real power cycle):
//   vvp tb_pipeline.vvp +PHASE=1   enrol A, B, S on blank EEPROM -> saved -> eeprom_image.hex
//   vvp tb_pipeline.vvp +PHASE=2   "power on" with that image, NO enrolment, all three recognised
module tb_pipeline;
    reg clk = 0;
    always #20 clk = ~clk;
    reg reset = 1;
    reg frame_start = 0, pixel_valid = 0;
    reg [8:0] px = 0; reg [7:0] py = 0; reg [11:0] prgb = 0;
    reg key0 = 0, key1 = 0, key2 = 0, enrol_en = 0;
    reg [15:0] threshold = 16'h0800;   // synthetic faces are noise-light, so scores are far below real-camera scores
    integer phase;

    wire tv, tb; wire [7:0] ra, rd;
    face_crop_16x16 crop (.clk(clk), .reset(reset), .frame_start(frame_start), .pixel_valid(pixel_valid),
        .pixel_x(px), .pixel_y(py), .pixel_rgb444(prgb), .template_valid(tv), .template_bank(tb),
        .sample_rd_addr(ra), .sample_rd_data(rd));

    wire io_busy, io_we, io_mean_we, io_cnt_we; wire [13:0] io_raddr, io_waddr; wire [7:0] io_rdata, io_wdata, io_mean_val;
    wire [5:0] io_mean_slot; wire [1:0] io_cnt_id, busy_id; wire [3:0] io_cnt_val; wire [2:0] mem_status;
    wire enrol_done; wire [1:0] enrol_done_id;
    wire rv, rface, eh; wire [1:0] rid, es; wire [15:0] s0, s1, s2, con; wire [3:0] c0, c1, c2;
    live_face_matcher #(.CONTRAST_MIN(2560), .ENROL_STRIDE(3)) m (.clk(clk), .reset(reset), .template_valid(tv),
        .sample_rd_addr(ra), .sample_rd_data(rd), .enrol_en(enrol_en),
        .enrol_key0(key0), .enrol_key1(key1), .enrol_key2(key2), .threshold(threshold),
        .io_busy(io_busy), .io_raddr(io_raddr), .io_rdata(io_rdata), .io_we(io_we), .io_waddr(io_waddr),
        .io_wdata(io_wdata), .io_mean_we(io_mean_we), .io_mean_slot(io_mean_slot), .io_mean_val(io_mean_val),
        .io_cnt_we(io_cnt_we), .io_cnt_id(io_cnt_id), .io_cnt_val(io_cnt_val),
        .enrol_done(enrol_done), .enrol_done_id(enrol_done_id),
        .result_valid(rv), .result_id(rid), .result_face(rface),
        .score0(s0), .score1(s1), .score2(s2), .contrast(con),
        .count0(c0), .count1(c1), .count2(c2), .enrol_held(eh), .enrol_sel(es));

    wire sda, scl, sda_oe;
    pullup (sda);
    assign sda = sda_oe ? 1'b0 : 1'bz;
    eeprom_model #(.T_WC_NS(100000)) rom (.sda(sda), .scl(scl));
    eeprom_store #(.DIV(3), .BOOT_DELAY(50)) store (.clk(clk), .scl(scl), .sda_oe(sda_oe), .sda_i(sda),
        .reload(1'b0), .io_busy(io_busy), .io_raddr(io_raddr), .io_rdata(io_rdata), .io_we(io_we),
        .io_waddr(io_waddr), .io_wdata(io_wdata), .io_mean_we(io_mean_we), .io_mean_slot(io_mean_slot),
        .io_mean_val(io_mean_val), .io_cnt_we(io_cnt_we), .io_cnt_id(io_cnt_id), .io_cnt_val(io_cnt_val),
        .save_req(enrol_done), .save_id(enrol_done_id), .cur_cnt0(c0), .cur_cnt1(c1), .cur_cnt2(c2),
        .status(mem_status), .busy_id(busy_id));

    wire [1:0] mode, lid; wire unk, lp; wire [7:0] hl;
    presence_tracker #(.HOLD_FRAMES(20), .LOCK_ACC(12), .HIT_INC(2), .UNK_FRAMES(20)) t (.clk(clk), .reset(reset),
        .frame_start(frame_start), .result_valid(rv), .result_id(rid), .result_face(rface), .enrol_held(eh),
        .busy(io_busy), .mode(mode), .locked_id(lid), .unk_show(unk), .lock_pulse(lp), .hold_left(hl));
    wire [2:0] flags; wire ev, dup; wire [1:0] evid;
    attendance_latch att (.clk(clk), .reset(reset), .recognition_valid(lp), .recognized_id(lid),
        .attendance_flags(flags), .event_pulse(ev), .event_student_id(evid), .dup_pulse(dup));

    reg [5:0] img [0:76799];
    integer lock_events, last_lock_id, saves_seen, ev_count, dup_count;
    initial begin ev_count = 0; dup_count = 0; end
    always @(posedge clk) begin if (ev) ev_count = ev_count + 1; if (dup) dup_count = dup_count + 1; end
    always @(posedge clk) if (lp) begin lock_events = lock_events + 1; last_lock_id = lid; end
    always @(posedge clk) if (enrol_done) saves_seen = saves_seen + 1;

    function integer iabs(input integer v); iabs = v < 0 ? -v : v; endfunction

    task render(input integer person, input integer light, input integer shift);
        integer x, y, dx, dy, g, eye, hairy, nz;
        begin
            for (y = 0; y < 240; y = y + 1) for (x = 0; x < 320; x = x + 1) begin
                dx = x - 160 - shift; dy = y - 120;
                nz = ($random & 3) - 1;
                if (person == 9) g = 34 + light + nz;
                else if (person == 3) begin                         // stranger: very different layout
                    g = 48;
                    if ((dx*dx)/(80*80.0) + (dy*dy)/(88*88.0) < 1.0) g = 30;
                    if (iabs(iabs(dx) - 52) < 12 && iabs(dy - 10) < 12) g = 6;
                    if (iabs(dx) < 40 && dy > -70 && dy < -50) g = 6;
                    g = g + light + nz;
                end else begin
                    g = 48;
                    if ((dx*dx)/(80*80.0) + (dy*dy)/(88*88.0) < 1.0) g = 34;
                    hairy = (person == 1) ? -58 : (person == 2 ? -50 : -52);
                    if (dy < hairy && (dx*dx)/(84*84.0) + (dy*dy)/(92*92.0) < 1.0) g = 8;
                    eye = (person == 0) ? 30 : (person == 1 ? 40 : 20);
                    if (iabs(iabs(dx) - eye) < 9 && iabs(dy + 22) < 6) g = 10;
                    if (iabs(dx) < ((person == 1) ? 22 : 30) && dy > 38 && dy < 46) g = 14;
                    if (person == 0 && dy > 50 && (dx*dx)/(78*78.0) + (dy*dy)/(88*88.0) < 1.0) g = 12;
                    if (person == 1 && dy > 56 && iabs(dx) < 34 && (dx*dx)/(78*78.0) + (dy*dy)/(88*88.0) < 1.0) g = 22;
                    if (person == 2 && iabs(dx) < 8 && dy > -10 && dy < 25) g = 20;
                    g = g + light + nz;
                end
                if (g < 0) g = 0; if (g > 60) g = 60;
                img[y*320 + x] = g;
            end
        end
    endtask

    integer fx, fy, fg;
    task send_frame;
        begin
            @(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0;
            for (fy = 0; fy < 240; fy = fy + 1) for (fx = 0; fx < 320; fx = fx + 1) begin
                px = fx; py = fy; fg = img[fy*320 + fx] / 4;
                prgb = {fg[3:0], fg[3:0], fg[3:0]};
                pixel_valid = 1; @(negedge clk); pixel_valid = 0; @(negedge clk);
            end
            repeat (20) @(negedge clk);
        end
    endtask
    task frames(input integer person, input integer light, input integer n);
        integer i;
        begin for (i = 0; i < n; i = i + 1) begin render(person, light, ($random & 3) - 1); send_frame; end end
    endtask
    task settle;   // frames of wall until the EEPROM is idle and the tracker is back in SCAN
        integer i;
        begin
            i = 0;
            while ((io_busy || mode == 3) && i < 80) begin frames(9, 0, 1); i = i + 1; end
            frames(9, 0, 3);
            if (io_busy) $fatal(1, "EEPROM still busy");
        end
    endtask
    task lock_test(input integer person, input integer light, input integer want, input [255:0] name);
        integer n2;
        begin
            lock_events = 0;
            for (n2 = 0; n2 < 18 && mode != 2'd1; n2 = n2 + 1) frames(person, light, 1);
            $display("%0s: lock after %0d frames, scores A=%0d B=%0d S=%0d", name, n2, s0, s1, s2);
            if (mode !== 2'd1 || lid !== want) $fatal(1, "%0s not locked (mode=%0d id=%0d A=%0d B=%0d S=%0d con=%0d)", name, mode, lid, s0, s1, s2, con);
            if (lock_events != 1) $fatal(1, "%0s lock events %0d", name, lock_events);
            for (n2 = 0; n2 < 30 && mode == 2'd1; n2 = n2 + 1) frames(9, 0, 1);      // let the hold expire
            if (mode !== 2'd0) $fatal(1, "%0s: never left LOCK", name);
        end
    endtask
    task enrol(input integer person, input integer which);
        begin
            saves_seen = 0;
            case (which) 0: key0 = 1; 1: key1 = 1; default: key2 = 1; endcase
            frames(person, 0, 45);
            case (which) 0: key0 = 0; 1: key1 = 0; default: key2 = 0; endcase
            frames(9, 0, 1);
            settle;
            if (saves_seen != 1) $fatal(1, "person %0d: %0d save requests (want 1)", which, saves_seen);
            if (mem_status !== 3'd1) $fatal(1, "person %0d: EEPROM status %0d after save", which, mem_status);
        end
    endtask

    integer n, k, i;
    initial begin
        lock_events = 0; last_lock_id = -1; saves_seen = 0;
        if (!$value$plusargs("PHASE=%d", phase)) phase = 1;
        if (phase == 2) $readmemh("eeprom_image.hex", rom.mem);
        repeat (4) @(negedge clk); reset = 0;
        // ---- power-up: the saved faces are loaded automatically ----
        wait (io_busy === 1'b1);
        wait (io_busy === 1'b0);
        repeat (5) @(negedge clk);
        if (phase == 1) begin
            if (mem_status !== 3'd2) $fatal(1, "blank EEPROM should read NEW, got %0d", mem_status);
            if (c0 || c1 || c2) $fatal(1, "counts not zero on blank EEPROM");
        end else begin
            if (mem_status !== 3'd1) $fatal(1, "saved image did not load OK (status %0d)", mem_status);
            if (c0 !== 4'd10 || c1 !== 4'd10 || c2 !== 4'd10) $fatal(1, "loaded counts %0d %0d %0d (want 10 10 10)", c0, c1, c2);
            $display("power-on: loaded %0d/%0d/%0d templates from the EEPROM image", c0, c1, c2);
        end
        frames(9, 0, 3);
        if (mode !== 0 || lock_events != 0) $fatal(1, "locked on blank wall");
        if (rface !== 1'b0) $fatal(1, "blank wall passed contrast gate (contrast=%0d)", con);

        if (phase == 1) begin
            // Write protection: with SW17 down the enrol keys do nothing at all.
            frames(0, 0, 3);
            key0 = 1; frames(0, 0, 25); key0 = 0; frames(9, 0, 2);
            if (c0 || saves_seen != 0 || io_busy) $fatal(1, "key acted while enrol_en was off");
            $display("write protection OK: key ignored with enrol enable off");
            enrol_en = 1;
            enrol(0, 0); if (c0 !== 4'd10) $fatal(1, "A count %0d", c0);
            enrol(1, 1); if (c1 !== 4'd10) $fatal(1, "B count %0d", c1);
            enrol(2, 2); if (c2 !== 4'd10) $fatal(1, "S count %0d", c2);
            if (c0 !== 4'd10) $fatal(1, "A templates lost while enrolling others");
            if (rom.mem[0] !== 8'hA5 || rom.mem[1] !== 8'h02 || rom.mem[2] !== 10 || rom.mem[3] !== 10 || rom.mem[4] !== 10)
                $fatal(1, "EEPROM header %h %h %0d %0d %0d", rom.mem[0], rom.mem[1], rom.mem[2], rom.mem[3], rom.mem[4]);
            $display("enrolled and saved: A=%0d B=%0d S=%0d, EEPROM header counts %0d %0d %0d", c0, c1, c2, rom.mem[2], rom.mem[3], rom.mem[4]);
            // A tap with no captured sample changes nothing (stored data kept).
            saves_seen = 0;
            key1 = 1; @(negedge clk); @(negedge clk); key1 = 0; frames(9, 0, 2);
            if (c1 !== 4'd10 || saves_seen != 0) $fatal(1, "a tap changed person B (count %0d, saves %0d)", c1, saves_seen);
            enrol_en = 0;
        end

        // ---- recognition (same checks before and after the power cycle) ----
        lock_test(0, 0, 0, "A");
        if (flags !== 3'b001) $fatal(1, "attendance flags after A: %b", flags);
        lock_test(1, 6, 1, "B (+6 brightness)");
        lock_test(2, 0, 2, "S");
        if (flags !== 3'b111) $fatal(1, "attendance flags after S: %b", flags);
        if (ev_count != 3 || dup_count != 0) $fatal(1, "attendance events %0d dups %0d after first locks (want 3, 0)", ev_count, dup_count);
        // Already marked: A is seen again -> locks and shows ALREADY MARKED, but no second attendance event.
        lock_test(0, 0, 0, "A again");
        if (ev_count != 3 || dup_count != 1 || flags !== 3'b111) $fatal(1, "second lock of A: events %0d dups %0d flags %b", ev_count, dup_count, flags);
        $display("already marked: A locked again, dup pulses=%0d, attendance events still %0d", dup_count, ev_count);
        // dropped frames: every third frame is a wall
        for (n = 0; n < 12 && mode != 2'd1; n = n + 1) begin frames(2, -5, 2); frames(9, 0, 1); end
        if (mode !== 2'd1 || lid !== 2) $fatal(1, "S not locked with dropped frames");
        for (n = 0; n < 30 && mode == 2'd1; n = n + 1) frames(9, 0, 1);
        // stranger must never lock
        lock_events = 0;
        frames(3, 0, 35);
        $display("stranger: A=%0d B=%0d S=%0d id=%0d unk=%0d", s0, s1, s2, rid, unk);
        if (lock_events != 0 || mode === 2'd1) $fatal(1, "stranger locked");
        if (!unk) $fatal(1, "UNKNOWN not shown for stranger");
        frames(9, 0, 3);
        if (unk) $fatal(1, "UNKNOWN stuck after the face left");
        // reset clears attendance but keeps templates
        reset = 1; repeat (3) @(negedge clk); reset = 0;
        if (flags !== 3'b000) $fatal(1, "reset kept flags");
        if (c0 !== 4'd10 || c1 !== 4'd10 || c2 !== 4'd10) $fatal(1, "reset cleared templates");

        if (phase == 1) begin
            $writememh("eeprom_image.hex", rom.mem);
            $display("PASS: tb_pipeline PHASE=1 - blank EEPROM, write protection, enrol+save A/B/S, tap harmless, recognition, stranger rejected; image written");
        end else
            $display("PASS: tb_pipeline PHASE=2 - power-on load of the saved image, A/B/S recognised with NO enrolment, stranger rejected");
        $finish;
    end
    initial begin #12000000000; $fatal(1, "pipeline timeout"); end
endmodule

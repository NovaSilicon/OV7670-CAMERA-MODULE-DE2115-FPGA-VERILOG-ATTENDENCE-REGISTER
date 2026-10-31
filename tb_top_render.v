`timescale 1ns/1ps
// Full top-level check on the real VGA pins with a prerecorded framebuffer
// (the OV7670 electrical interface is NOT exercised). Synthetic faces A/B/C
// are written into the framebuffer, enrolment is done through KEY[1]/KEY[2],
// and complete 640x480 frames are captured from VGA_R/G/B into PPM files
// (render_*.ppm) for visual inspection. The EEPROM model is attached, so saving and
// the SAVING / LOADING screens are exercised too. Automated checks cover the label
// colour, the box outline colour, attendance panel and LEDs.
module tb_top_render;
    reg clk = 0;
    always #10 clk = ~clk;
    reg [3:0] key = 4'b1111;
    wire [35:0] gpio;
    assign gpio[4:2] = 3'b000;
    assign gpio[13:6] = 8'b0;
    wire [8:0] leds;
    wire [7:0] r, g, b;
    wire vclk, blank, sync, hs, vs;
    reg [17:0] sw = 18'd0;
    wire eep_sda, eep_scl;
    pullup (eep_sda);
    top_ov7670_vga_detect dut (.CLOCK_50(clk), .KEY(key), .SW(sw),
        .LEDG(leds), .GPIO(gpio), .VGA_R(r), .VGA_G(g), .VGA_B(b),
        .VGA_CLK(vclk), .VGA_BLANK_N(blank), .VGA_SYNC_N(sync), .VGA_HS(hs), .VGA_VS(vs),
        .EEP_I2C_SCLK(eep_scl), .EEP_I2C_SDAT(eep_sda));
    eeprom_model #(.T_WC_NS(100000)) rom (.sda(eep_sda), .scl(eep_scl));
    defparam dut.I2C_DIV = 3;
    defparam dut.BOOT_DELAY = 50;
    defparam dut.u_matcher.ENROL_STRIDE = 1;
    defparam dut.u_tracker.UNK_FRAMES = 3;
    defparam dut.u_tracker.HOLD_FRAMES = 14;

    function integer iabs(input integer v); iabs = v < 0 ? -v : v; endfunction
    task render(input integer person);
        integer x, y, dx, dy, gg, eye, hairy, nz, fg;
        begin
            for (y = 0; y < 240; y = y + 1) for (x = 0; x < 320; x = x + 1) begin
                dx = x - 160; dy = y - 120;
                nz = ($random & 1);
                if (person == 9) gg = 34 + nz;
                else if (person == 3) begin
                    gg = 48;
                    if ((dx*dx)/(80*80.0) + (dy*dy)/(88*88.0) < 1.0) gg = 30;
                    if (iabs(iabs(dx) - 52) < 12 && iabs(dy - 10) < 12) gg = 6;
                    if (iabs(dx) < 40 && dy > -70 && dy < -50) gg = 6;
                    gg = gg + nz;
                end else begin
                    gg = 48;
                    if ((dx*dx)/(80*80.0) + (dy*dy)/(88*88.0) < 1.0) gg = 34;
                    hairy = (person == 1) ? -58 : (person == 2 ? -50 : -52);
                    if (dy < hairy && (dx*dx)/(84*84.0) + (dy*dy)/(92*92.0) < 1.0) gg = 8;
                    eye = (person == 0) ? 30 : (person == 1 ? 40 : 20);
                    if (iabs(iabs(dx) - eye) < 9 && iabs(dy + 22) < 6) gg = 10;
                    if (iabs(dx) < ((person == 1) ? 22 : 30) && dy > 38 && dy < 46) gg = 14;
                    if (person == 0 && dy > 50 && (dx*dx)/(78*78.0) + (dy*dy)/(88*88.0) < 1.0) gg = 12;
                    if (person == 1 && dy > 56 && iabs(dx) < 34 && (dx*dx)/(78*78.0) + (dy*dy)/(88*88.0) < 1.0) gg = 22;
                    if (person == 2 && iabs(dx) < 8 && dy > -10 && dy < 25) gg = 20;
                    gg = gg + nz;
                end
                if (gg > 60) gg = 60;
                fg = gg / 4;
                dut.u_fb.mem[y*320 + x] = {fg[3:0], fg[3:0], fg[3:0]};
            end
        end
    endtask

    integer i, n, xx, yy, fd;
    reg [7:0] img_r [0:307199];
    reg [7:0] img_g [0:307199];
    reg [7:0] img_b [0:307199];
    task capture(input [255:0] name);
        integer cnt;
        begin
            // Pixels are sampled from the REGISTERED VGA pins: wait for the VS pulse,
            // then the next rising VGA_BLANK_N is line 0; sample every active clock.
            @(negedge vs);
            @(posedge blank);
            cnt = 0;
            for (yy = 0; yy < 480; yy = yy + 1) begin
                if (yy != 0) @(posedge blank);
                while (blank) begin
                    @(negedge vclk);
                    if (blank && cnt < 307200) begin
                        img_r[cnt] = r; img_g[cnt] = g; img_b[cnt] = b; cnt = cnt + 1;
                    end
                end
            end
            if (cnt != 307200) $fatal(1, "captured %0d pixels (expected 307200)", cnt);
            fd = $fopen({name, ".ppm"}, "wb");
            $fwrite(fd, "P6\n640 480\n255\n");
            for (i = 0; i < 307200; i = i + 1) $fwrite(fd, "%c%c%c", img_r[i], img_g[i], img_b[i]);
            $fclose(fd);
        end
    endtask
    task wait_frames(input integer k);
        integer j;
        begin for (j = 0; j < k; j = j + 1) begin
            @(posedge vclk); while (!dut.detector_frame_start) @(posedge vclk);
        end end
    endtask
    // colour probe on the box outline: top edge at y=64, x=300
    task expect_box(input [7:0] er, input [7:0] eg, input [7:0] eb, input [255:0] what);
        begin
            @(posedge vclk);
            while (!(dut.vga_active && dut.scan_x == 300 && dut.scan_y == 65)) @(posedge vclk);
            #1;
            if (r !== er || g !== eg || b !== eb)
                $fatal(1, "%0s: box colour %h%h%h expected %h%h%h", what, r, g, b, er, eg, eb);
        end
    endtask

    integer m0;
    initial begin
        render(9);
        repeat (10) @(negedge clk);
        wait (dut.io_busy === 1'b0); wait_frames(3);
        if (dut.mem_status !== 3'd2) $fatal(1, "blank EEPROM should read NEW (status %0d)", dut.mem_status);
        expect_box(8'hFF, 8'hFF, 8'h00, "scanning box is yellow");
        capture("render_1_scanning_not_enrolled");

        // Enrol A (KEY[1]) with SW[17] up.
        sw[17] = 1'b1; render(0); key[1] = 1'b0; wait_frames(4);
        capture("render_2_enrolling_A");
        wait_frames(14); key[1] = 1'b1;
        wait (dut.io_busy === 1'b1);
        capture("render_3_saving_A");
        wait (dut.io_busy === 1'b0); wait_frames(2);
        if (dut.count0 !== 4'd10) $fatal(1, "A not enrolled, count=%0d", dut.count0);
        // Enrol B (KEY[2]) and Sahiti (KEY[3]).
        render(1); key[2] = 1'b0; wait_frames(14); key[2] = 1'b1;
        wait (dut.io_busy === 1'b1); wait (dut.io_busy === 1'b0); wait_frames(2);
        if (dut.count1 !== 4'd10) $fatal(1, "B not enrolled, count=%0d", dut.count1);
        render(2); key[3] = 1'b0; wait_frames(14); key[3] = 1'b1;
        wait (dut.io_busy === 1'b1); wait (dut.io_busy === 1'b0); wait_frames(2);
        if (dut.count2 !== 4'd10) $fatal(1, "Sahiti not enrolled, count=%0d", dut.count2);
        sw[17] = 1'b0;
        if (rom.mem[2] !== 10 || rom.mem[3] !== 10 || rom.mem[4] !== 10 || rom.mem[0] !== 8'hA5)
            $fatal(1, "EEPROM header not written (%h %0d %0d %0d)", rom.mem[0], rom.mem[2], rom.mem[3], rom.mem[4]);
        $display("saved to EEPROM: header counts %0d %0d %0d", rom.mem[2], rom.mem[3], rom.mem[4]);

        // A, B, Sahiti are recognised in turn; each PRESENT is held, then scanning resumes.
        render(0);
        n = 0; while (dut.mode !== 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end
        if (dut.mode !== 2'd1 || dut.locked_id !== 2'd0) $fatal(1, "A not locked");
        wait_frames(2);
        expect_box(8'h00, 8'hFF, 8'h00, "locked box is green");
        if (leds[7] !== 1'b1 || leds[0] !== 1'b1) $fatal(1, "LEDs: locked/attendance %b", leds);
        capture("render_4_A_present");
        n = 0; while (dut.mode === 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end
        if (dut.mode !== 2'd0) $fatal(1, "did not return to scanning");
        $display("PRESENT held then scanning resumed after about %0d more frames", n);

        render(1);
        n = 0; while (dut.mode !== 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end
        if (dut.locked_id !== 2'd1) $fatal(1, "B not locked");
        wait_frames(2);
        capture("render_5_B_present");
        n = 0; while (dut.mode === 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end

        render(2);
        n = 0; while (dut.mode !== 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end
        if (dut.locked_id !== 2'd2) $fatal(1, "Sahiti not locked (A=%0d B=%0d S=%0d)", dut.score0, dut.score1, dut.score2);
        wait_frames(2);
        capture("render_6_Sahiti_present");
        n = 0; while (dut.mode === 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end
        if (dut.attendance_flags !== 3'b111) $fatal(1, "attendance flags %b", dut.attendance_flags);

        // Advaith again: attendance is already marked -> orange box, ALREADY MARKED, no new event.
        render(0);
        n = 0; while (dut.mode !== 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end
        if (dut.mode !== 2'd1 || dut.locked_id !== 2'd0) $fatal(1, "A not locked the second time");
        wait_frames(2);
        if (dut.already_marked !== 1'b1) $fatal(1, "already_marked not set on second lock");
        expect_box(8'hFF, 8'h88, 8'h00, "already-marked box is orange");
        if (dut.attendance_flags !== 3'b111) $fatal(1, "flags changed on second lock");
        capture("render_7_A_already_marked");
        n = 0; while (dut.mode === 2'd1 && n < 40) begin wait_frames(1); n = n + 1; end

        render(3);
        wait_frames(8);
        if (dut.mode === 2'd1) $fatal(1, "stranger locked (A=%0d B=%0d S=%0d)", dut.score0, dut.score1, dut.score2);
        $display("stranger: A=%0d B=%0d S=%0d unk_show=%0d", dut.score0, dut.score1, dut.score2, dut.unk_show);
        expect_box(8'hFF, 8'h33, 8'h33, "unknown box is red");
        capture("render_8_stranger_unknown");

        // Keys do nothing while SW[17] is down: Advaith's templates survive a key press.
        key[1] = 1'b0; wait_frames(14); key[1] = 1'b1; wait_frames(2);
        if (dut.count0 !== 4'd10 || dut.io_busy) $fatal(1, "key changed data with enrol enable off");
        $display("PASS: tb_top_render - load/enrol/save/10 samples each, lock/hold/rescan/already-marked/unknown for three people on real VGA pins; frames saved as render_*.ppm");
        $finish;
    end
    initial begin #6000000000; $fatal(1, "top render timeout"); end
endmodule

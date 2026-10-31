`timescale 1ns/1ps
// Unit test of the frame-rate presence logic with scripted matcher results.
module tb_presence_tracker;
    reg clk = 0; always #20 clk = ~clk;
    reg reset = 1, frame_start = 0, result_valid = 0, result_face = 0, enrol_held = 0, busy = 0;
    reg [1:0] result_id = 3;
    wire [1:0] mode, locked_id; wire unk_show, lock_pulse; wire [7:0] hold_left;
    presence_tracker #(.HOLD_FRAMES(10), .LOCK_ACC(12), .HIT_INC(2), .UNK_FRAMES(5)) dut (.clk(clk), .reset(reset),
        .frame_start(frame_start), .result_valid(result_valid), .result_id(result_id), .result_face(result_face),
        .enrol_held(enrol_held), .busy(busy), .mode(mode), .locked_id(locked_id), .unk_show(unk_show),
        .lock_pulse(lock_pulse), .hold_left(hold_left));
    integer pulses = 0, changes_outside = 0;
    always @(posedge clk) if (lock_pulse) pulses = pulses + 1;
    // mode/locked_id/unk_show may only change on the clock after frame_start
    reg fs_d = 0; reg [1:0] mode_d = 0, lid_d = 0; reg unk_d = 0;
    always @(posedge clk) begin
        fs_d <= frame_start; mode_d <= mode; lid_d <= locked_id; unk_d <= unk_show;
        if (!fs_d && !reset && (mode !== mode_d || locked_id !== lid_d || unk_show !== unk_d)) changes_outside = changes_outside + 1;
    end
    // One frame: matcher result arrives mid-frame, next frame_start consumes it.
    task frame(input has, input [1:0] id, input face);
        begin
            @(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0;
            repeat (50) @(negedge clk);
            if (has) begin result_valid = 1; result_id = id; result_face = face; @(negedge clk); result_valid = 0; end
            repeat (10) @(negedge clk);
        end
    endtask
    integer i, n;
    initial begin
        repeat (3) @(negedge clk); reset = 0;
        // 5 hits are not enough (score 10 < 12), the 6th is.
        for (i = 0; i < 6; i = i + 1) frame(1, 0, 1);
        if (mode !== 0) $fatal(1, "locked too early");
        frame(1, 0, 1);      // consumes the 6th result
        if (mode !== 1 || locked_id !== 0) $fatal(1, "no lock after 6 hits (mode=%0d)", mode);
        if (pulses != 1) $fatal(1, "lock pulses %0d", pulses);
        // Hold: exactly HOLD_FRAMES frame_starts, regardless of results.
        n = 0;
        while (mode == 1 && n < 30) begin frame(1, 1, 1); n = n + 1; end
        if (mode !== 0) $fatal(1, "never released");
        if (n < 9 || n > 11) $fatal(1, "hold lasted %0d frames, expected about 10", n);
        $display("hold = %0d frames", n);
        // Alternating hit/miss (50%% hits, +2/-1) still locks person 1.
        for (i = 0; i < 30 && mode != 1; i = i + 1) begin frame(1, 1, 1); frame(0, 3, 0); end
        if (mode !== 1 || locked_id !== 1) $fatal(1, "alternating hits did not lock");
        n = 0; while (mode == 1 && n < 30) begin frame(0, 3, 0); n = n + 1; end
        // Unknown face (contrast ok, id 3) for 5 frames -> UNKNOWN, then clears with a blank frame.
        for (i = 0; i < 7; i = i + 1) frame(1, 3, 1);
        if (!unk_show || mode !== 0) $fatal(1, "UNKNOWN not shown");
        frame(1, 3, 0); frame(1, 3, 0);
        if (unk_show) $fatal(1, "UNKNOWN stuck");
        // Two people alternating never locks (each score keeps being reduced).
        for (i = 0; i < 40; i = i + 1) frame(1, i[0] ? 2'd1 : 2'd0, 1);
        if (mode === 1) $fatal(1, "flip-flopping identity locked");
        // Enrolling pauses scanning.
        enrol_held = 1; frame(1, 0, 1); frame(1, 0, 1);
        if (mode !== 2) $fatal(1, "not in ENROL mode");
        enrol_held = 0; frame(0, 3, 0); frame(0, 3, 0);
        if (mode !== 0) $fatal(1, "ENROL mode stuck");
        // EEPROM busy pauses scanning (mode 3) and clears the votes.
        busy = 1; frame(1, 0, 1); frame(1, 0, 1);
        if (mode !== 3) $fatal(1, "not in BUSY mode");
        busy = 0; frame(0, 3, 0); frame(0, 3, 0);
        if (mode !== 0) $fatal(1, "BUSY mode stuck");
        // Third person (ID2) locks too, and a clear winner beats a weaker rival.
        for (i = 0; i < 10 && mode != 1; i = i + 1) frame(1, 2, 1);
        if (mode !== 1 || locked_id !== 2) $fatal(1, "ID2 did not lock (mode=%0d id=%0d)", mode, locked_id);
        n = 0; while (mode == 1 && n < 30) begin frame(0, 3, 0); n = n + 1; end
        if (changes_outside != 0) $fatal(1, "%0d display-state changes happened mid-frame", changes_outside);
        $display("PASS: tb_presence_tracker - lock needs consistent hits, hold %0d frames, dropped frames tolerated, UNKNOWN set/clear, flip-flop never locks, ID2 locks, BUSY/ENROL pause, no mid-frame changes", 10);
        $finish;
    end
    initial begin #50000000; $fatal(1, "tracker timeout"); end
endmodule

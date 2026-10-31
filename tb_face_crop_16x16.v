`timescale 1ns/1ps
// Checks the cell-averaged cropper: a synthetic frame whose gray level is a known
// function of the 16x16 cell must come back exactly (averaging of uniform cells),
// pixels outside the box must not leak in, a noisy cell must average out, and the
// double-buffer must hand over a complete bank only at the next frame_start.
module tb_face_crop_16x16;
    reg clk = 0; always #20 clk = ~clk;
    reg reset = 1, frame_start = 0, pixel_valid = 0;
    reg [8:0] px = 0; reg [7:0] py = 0; reg [11:0] prgb = 0;
    wire tv, tb; reg [7:0] ra = 0; wire [7:0] rd;
    face_crop_16x16 dut (.clk(clk), .reset(reset), .frame_start(frame_start), .pixel_valid(pixel_valid),
        .pixel_x(px), .pixel_y(py), .pixel_rgb444(prgb), .template_valid(tv), .template_bank(tb),
        .sample_rd_addr(ra), .sample_rd_data(rd));
    integer x, y, cx, cy, g, errors, tvs, frame;
    reg [7:0] seen [0:255];
    always @(posedge clk) if (tv) tvs <= tvs + 1;

    task send_frame(input integer mode);
        begin
            @(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0;
            for (y = 0; y < 240; y = y + 1) for (x = 0; x < 320; x = x + 1) begin
                px = x; py = y;
                if (x >= 64 && x < 256 && y >= 32 && y < 208) begin
                    cx = (x - 64) / 12; cy = (y - 32) / 11;
                    g = (cx + cy) * 2;                       // 0..60, uniform per cell
                    if (mode == 1 && cx == 5 && cy == 5)     // noisy cell: alternate 20 / 40
                        g = ((x + y) % 2) ? 40 : 20;
                end else g = 60;                             // bright border must not leak in
                prgb = {g[5:2], g[5:2], g[5:2]};
                // R+2G+B = 4*(g/4): quantised to multiples of 4 by the 4-bit channels
                pixel_valid = 1; @(negedge clk); pixel_valid = 0; @(negedge clk);
            end
        end
    endtask
    task read_bank;
        integer a;
        begin
            for (a = 0; a < 256; a = a + 1) begin
                ra = a; repeat (3) @(negedge clk); seen[a] = rd;
            end
        end
    endtask
    initial begin
        tvs = 0; errors = 0;
        repeat (4) @(negedge clk); reset = 0;
        // The first frame_start only primes the cropper (it may have started mid-frame).
        send_frame(0);                       // frame 0 is complete but not handed over until the next frame_start
        if (tvs != 0) $fatal(1, "template_valid before the next frame_start");
        @(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0;   // end of frame 0
        repeat (3) @(negedge clk);
        if (tvs != 1) $fatal(1, "complete frame 0 not handed over (tvs=%0d)", tvs);
        send_frame(1);                       // frame 1 with a noisy cell
        @(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0;
        repeat (3) @(negedge clk);
        if (tvs != 2) $fatal(1, "expected two template_valid pulses in total, got %0d", tvs);
        read_bank;
        for (cy = 0; cy < 16; cy = cy + 1) for (cx = 0; cx < 16; cx = cx + 1) begin
            g = ((cx + cy) * 2);
            g = (g / 4) * 4;                            // channel quantisation
            // expected = 4*gray_sum/... : cell value = gray_sum*31/1024*... (gray_sum = 4*(g/4)*... )
            // gray_sum = R + 2G + B = 4*q with q = g/4  -> value ~= 4*gray_sum/132... compute directly:
            // cell sum = 132 * (4*q); value = (sum*31)>>10
            g = ((132 * 4 * (g / 4)) * 31) >> 10;
            if (cx == 5 && cy == 5) begin
                // alternating q = 5 / 10  (g=20 -> q=5, g=40 -> q=10): mean sum = 66*20 + 66*40 = 3960
                g = (3960 * 31) >> 10;
            end
            if (seen[cy*16 + cx] !== g[7:0]) begin
                errors = errors + 1;
                if (errors < 6) $display("cell (%0d,%0d): got %0d expected %0d", cx, cy, seen[cy*16+cx], g);
            end
        end
        if (errors != 0) $fatal(1, "%0d cells wrong", errors);
        $display("PASS: tb_face_crop_16x16 - 256 cell averages exact, border does not leak, noisy cell averaged, banks handed over once per complete frame");
        $finish;
    end
    initial begin #400000000; $fatal(1, "crop timeout"); end
endmodule

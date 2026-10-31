// Frame-rate presence tracker: turns noisy per-frame matcher results into a
// stable PRESENT event that is held on screen for HOLD_FRAMES frames.
//
// All state changes happen at frame_start, so the label never changes mid-frame.
//
//   SCAN  : each frame adds to a leaky score for the person the matcher named
//           (+HIT_INC, the other persons' scores -1, floor 0). A frame with no accepted
//           result counts as a miss for everyone. When a score reaches LOCK_ACC the
//           person is LOCKED. A face-like crop that is never accepted raises
//           unk_count, so the label shows UNKNOWN once it reaches UNK_FRAMES.
//   LOCK  : the locked person is shown as PRESENT for HOLD_FRAMES frames
//           (60 Hz => 90 frames ~ 1.5 s) and results are ignored, then the
//           tracker returns to SCAN with cleared scores ("detecting again").
//   ENROL : while an enrol key is held; scanning is paused and cleared.
//   BUSY  : while the EEPROM is loading or saving; scanning is paused and cleared.
//
// lock_pulse (1 clock, at the frame_start of the lock) feeds attendance_latch.
module presence_tracker #(
    parameter integer HOLD_FRAMES = 90,
    parameter integer LOCK_ACC    = 12,
    parameter integer HIT_INC     = 2,
    parameter integer UNK_FRAMES  = 20
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       frame_start,
    input  wire       result_valid,
    input  wire [1:0] result_id,
    input  wire       result_face,
    input  wire       enrol_held,
    input  wire       busy,
    output reg  [1:0] mode,        // 0 = SCAN, 1 = LOCK, 2 = ENROL, 3 = BUSY
    output reg  [1:0] locked_id,
    output reg        unk_show,
    output reg        lock_pulse,
    output reg  [7:0] hold_left
);
    reg       have_res;
    reg [1:0] last_id;
    reg       last_face;
    reg [4:0] acc0, acc1, acc2, unk;

    function [4:0] bump(input [4:0] a, input hit);
        reg [5:0] up;
        begin
            up = a + HIT_INC;
            if (hit) bump = (up > 6'd31) ? 5'd31 : up[4:0];
            else     bump = (a != 5'd0) ? a - 5'd1 : 5'd0;
        end
    endfunction

    wire hit0 = have_res && (last_id == 2'd0);
    wire hit1 = have_res && (last_id == 2'd1);
    wire hit2 = have_res && (last_id == 2'd2);
    wire [4:0] n0 = bump(acc0, hit0);
    wire [4:0] n1 = bump(acc1, hit1);
    wire [4:0] n2 = bump(acc2, hit2);
    wire face_unmatched = have_res && last_face && !hit0 && !hit1 && !hit2;
    wire [4:0] nu = face_unmatched ? (unk != 5'd31 ? unk + 5'd1 : unk) : 5'd0;
    wire lock0 = (n0 >= LOCK_ACC) && (n0 >= n1) && (n0 >= n2);
    wire lock1 = (n1 >= LOCK_ACC) && (n1 > n0) && (n1 >= n2);
    wire lock2 = (n2 >= LOCK_ACC) && (n2 > n0) && (n2 > n1);

    initial begin
        mode = 0; locked_id = 2'd3; unk_show = 0; lock_pulse = 0; hold_left = 0;
        have_res = 0; last_id = 3; last_face = 0; acc0 = 0; acc1 = 0; acc2 = 0; unk = 0;
    end

    always @(posedge clk) begin
        lock_pulse <= 1'b0;
        if (reset) begin
            mode <= 2'd0; locked_id <= 2'd3; unk_show <= 1'b0; hold_left <= 8'd0;
            have_res <= 1'b0; last_id <= 2'd3; last_face <= 1'b0;
            acc0 <= 5'd0; acc1 <= 5'd0; acc2 <= 5'd0; unk <= 5'd0;
        end else begin
            if (result_valid) begin
                have_res <= 1'b1; last_id <= result_id; last_face <= result_face;
            end
            if (frame_start) begin
                have_res <= 1'b0;                       // consume this frame's result
                if (busy || enrol_held) begin
                    mode <= busy ? 2'd3 : 2'd2;
                    acc0 <= 5'd0; acc1 <= 5'd0; acc2 <= 5'd0; unk <= 5'd0; unk_show <= 1'b0;
                end else if (mode == 2'd1) begin
                    if (hold_left > 8'd1) hold_left <= hold_left - 8'd1;
                    else begin
                        mode <= 2'd0; hold_left <= 8'd0; locked_id <= 2'd3;
                        acc0 <= 5'd0; acc1 <= 5'd0; acc2 <= 5'd0; unk <= 5'd0; unk_show <= 1'b0;
                    end
                end else begin
                    mode <= 2'd0;
                    acc0 <= n0; acc1 <= n1; acc2 <= n2; unk <= nu;
                    unk_show <= (nu >= UNK_FRAMES);
                    if (lock0 || lock1 || lock2) begin
                        mode <= 2'd1;
                        locked_id <= lock0 ? 2'd0 : (lock1 ? 2'd1 : 2'd2);
                        hold_left <= HOLD_FRAMES;
                        lock_pulse <= 1'b1;
                        unk_show <= 1'b0;
                    end
                end
            end
        end
    end
endmodule

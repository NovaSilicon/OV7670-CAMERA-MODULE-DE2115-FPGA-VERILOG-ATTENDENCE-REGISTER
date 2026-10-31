// Session attendance flags. Each accepted student ID is recorded once until
// reset, so repeated camera frames cannot create duplicate attendance events.
// Enrolled IDs 0, 1 and 2 can set flags; ID 3 (unknown) never does.
module attendance_latch (
    input  wire       clk,
    input  wire       reset,
    input  wire       recognition_valid,
    input  wire [1:0] recognized_id,
    output reg  [2:0] attendance_flags,
    output reg        event_pulse,
    output reg  [1:0] event_student_id,
    output reg        dup_pulse           // an enrolled person was recognised again after attendance was already marked
);
    always @(posedge clk) begin
        if (reset) begin
            attendance_flags <= 3'b000;
            event_pulse <= 1'b0;
            event_student_id <= 2'b11;
            dup_pulse <= 1'b0;
        end else begin
            event_pulse <= 1'b0;
            dup_pulse <= 1'b0;
            if (recognition_valid && (recognized_id < 2'd3)) begin   // enrolled IDs 0/1/2 only; unknown ID3 never marks attendance
                if (!attendance_flags[recognized_id]) begin
                    attendance_flags[recognized_id] <= 1'b1;
                    event_pulse <= 1'b1;
                    event_student_id <= recognized_id;
                end else begin
                    dup_pulse <= 1'b1;        // already marked: never a second attendance event
                end
            end
        end
    end
endmodule

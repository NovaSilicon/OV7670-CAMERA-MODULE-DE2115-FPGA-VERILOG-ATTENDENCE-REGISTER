`timescale 1ns/1ps
module tb_attendance_latch;
    reg clk = 0, reset = 1, valid = 0;
    reg [1:0] id = 2'd3;
    wire [2:0] flags;
    wire event_pulse;
    wire [1:0] event_id;
    wire dup_pulse;
    integer dups;
    always #20 clk = ~clk;
    attendance_latch dut (.clk(clk), .reset(reset), .recognition_valid(valid),
        .recognized_id(id), .attendance_flags(flags), .event_pulse(event_pulse),
        .event_student_id(event_id), .dup_pulse(dup_pulse));
    integer events;
    // One recognition_valid pulse; counts event_pulse over the following cycles.
    task result;
        input [1:0] rid;
        begin
            events = 0; dups = 0;
            @(negedge clk); id = rid; valid = 1;
            @(negedge clk); valid = 0;
            // event_pulse is registered: visible right after the valid cycle.
            if (event_pulse) events = events + 1;
            if (dup_pulse) dups = dups + 1;
            @(negedge clk);
            if (event_pulse) events = events + 1;
            if (dup_pulse) dups = dups + 1;
            id = 2'd3;
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); reset = 0;
        if (flags !== 3'b000) $fatal(1, "Flags not clear after reset: %b", flags);
        // ID ignored unless recognition_valid is high.
        id = 2'd0; repeat (3) @(negedge clk);
        if (flags !== 3'b000 || event_pulse) $fatal(1, "ID without valid marked attendance");
        // Unknown result (ID3) must not mark anyone.
        result(2'd3);
        if (flags !== 3'b000 || events != 0 || dups != 0) $fatal(1, "Unknown marked attendance");
        // First ID0 event.
        result(2'd0);
        if (flags !== 3'b001 || events != 1 || event_id !== 2'd0 || dups != 0) $fatal(1, "ID0 event: flags=%b events=%0d", flags, events);
        // Duplicate ID0 gives no new event.
        result(2'd0);
        if (flags !== 3'b001 || events != 0) $fatal(1, "Duplicate ID0 produced event");
        if (dups != 1) $fatal(1, "Duplicate ID0 gave %0d dup pulses (want 1)", dups);
        // Unknown after a present member does not clear or add anything.
        result(2'd3);
        if (flags !== 3'b001 || events != 0) $fatal(1, "Unknown changed attendance");
        // ID2 (third person) is a real enrolled person now.
        result(2'd2);
        if (flags !== 3'b101 || events != 1 || event_id !== 2'd2) $fatal(1, "ID2 event: flags=%b events=%0d", flags, events);
        result(2'd2);
        if (flags !== 3'b101 || events != 0) $fatal(1, "Duplicate ID2 produced event");
        // ID1 event.
        result(2'd1);
        if (flags !== 3'b111 || events != 1 || event_id !== 2'd1) $fatal(1, "ID1 event: flags=%b events=%0d", flags, events);
        result(2'd1);
        if (flags !== 3'b111 || events != 0) $fatal(1, "Duplicate ID1 produced event");
        // Reset clears the session.
        @(negedge clk); reset = 1;
        @(negedge clk);
        if (flags !== 3'b000 || event_pulse || event_id !== 2'd3) $fatal(1, "Reset did not clear session");
        reset = 0;
        // After reset the same member can be marked again (new session); ID1 first this time.
        result(2'd1);
        if (flags !== 3'b010 || events != 1) $fatal(1, "ID1-first after reset: flags=%b", flags);
        result(2'd0);
        if (flags !== 3'b011 || events != 1) $fatal(1, "ID0 second after reset: flags=%b", flags);
        $display("PASS: attendance latch: ID0/ID1 events, duplicate suppression with ALREADY-MARKED pulse, unknown ignored, ID2 (third person) marked once, reset");
        $finish;
    end
    initial begin #2000000; $fatal(1, "Timeout"); end
endmodule

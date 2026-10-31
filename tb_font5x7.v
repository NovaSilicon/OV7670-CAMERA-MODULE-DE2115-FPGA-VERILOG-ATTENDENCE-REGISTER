`timescale 1ns/1ps
// Checks the new R and S glyphs against independently written literals, and
// that previously existing glyphs are unchanged by the move into font5x7.
module tb_font5x7;
    reg [7:0] c = 8'd0;
    wire [34:0] bits;
    font5x7 dut (.c(c), .bits(bits));
    task expect_glyph;
        input [7:0] ch;
        input [34:0] expected;
        begin
            c = ch; #1;
            if (bits !== expected)
                $fatal(1, "Glyph '%c' mismatch: got %h expected %h", ch, bits, expected);
        end
    endtask
    integer lit;
    integer i;
    initial begin
        // New glyphs, row by row (R = 11110 10001 10001 11110 10100 10010 10001).
        expect_glyph("R", {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001});
        expect_glyph("S", {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110});
        // Existing glyphs must be bit-identical to the original overlay.
        expect_glyph("A", {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001});
        expect_glyph("N", {5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001});
        expect_glyph("W", {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010});
        expect_glyph("6", {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110});
        // Space and unsupported characters are blank.
        expect_glyph(" ", 35'd0);
        expect_glyph("Z", 35'd0);
        // Every character needed by the attendance strings must be non-blank.
        for (i = 0; i < 16; i = i + 1) begin
            case (i)
                0: c="A"; 1: c="D"; 2: c="V"; 3: c="I"; 4: c="T"; 5: c="H"; 6: c="N"; 7: c="E";
                8: c="P"; 9: c="R"; 10: c="S"; 11: c="O"; 12: c="M"; 13: c="K"; 14: c="U"; default: c="W";
            endcase
            #1;
            if (bits === 35'd0) $fatal(1, "Needed glyph '%c' is blank", c);
        end
        // Every character used by the box label, enrolment prompts and hex read-out.
        begin : label_chars
            reg [8*160-1:0] txt;
            integer j;
            txt = "ENROLLING NAME1 NAME2 DETECTING UNKNOWN PRESENT FACE IN BOX HOLD KEY SAMPLE OF DONE RELEASE 26ABC00XX 0123456789 ABCDEF / : V P ALREADY MARKED";
            for (j = 0; j < 160; j = j + 1) begin
                c = txt[j*8 +: 8]; #1;
                if (c != 8'h20 && c != 8'h00 && bits === 35'd0) $fatal(1, "Label glyph '%c' is blank", c);
            end
        end
        $display("PASS: font ROM: new R/S glyphs exact, existing glyphs unchanged, space blank, all attendance and label characters present");
        $finish;
    end
endmodule

// Guide box + label attached to its top-left corner + status text at the bottom.
//
// Layout in the 640x480 raster (box = 2x the source-pixel box):
//   label  : 2 rows x 24 chars, directly above the box, left edges aligned
//   box    : 4-pixel outline, colour shows the state
//   status : right of the attendance panel (3 rows) and one bottom row
//
// mode 0 SCAN  : yellow  "DETECTING"  (red "UNKNOWN" once a face-like crop is rejected)
// mode 1 LOCK  : green   "<NAME>" / "PRESENT <reg no>"  (orange "ALREADY MARKED" if attendance was already taken)
// mode 2 ENROL : cyan    "ENROLLING <NAME>" / "SAMPLE n OF 10"
// mode 3 BUSY  : magenta "LOADING SAVED FACES" or "SAVING <NAME>" (EEPROM access)
module box_label_overlay #(
    parameter integer BOX_X = 64,
    parameter integer BOX_Y = 32,
    parameter integer BOX_W = 192,
    parameter integer BOX_H = 176
) (
    input  wire [9:0]  pixel_x,
    input  wire [8:0]  pixel_y,
    input  wire        active,
    input  wire [1:0]  mode,
    input  wire [1:0]  locked_id,
    input  wire        unk_show,
    input  wire        already,      // the locked person's attendance had already been marked
    input  wire [1:0]  enrol_sel,
    input  wire [3:0]  count0,
    input  wire [3:0]  count1,
    input  wire [3:0]  count2,
    input  wire [15:0] score0,
    input  wire [15:0] score1,
    input  wire [15:0] score2,
    input  wire [15:0] threshold,
    input  wire [15:0] contrast,
    input  wire [2:0]  mem_status,   // 0 LOADING, 1 OK, 2 NEW, 3 ERR, 4 SAVING
    input  wire [1:0]  busy_id,
    output wire        box_edge,
    output wire        label_panel,
    output wire        label_text,
    output wire        status_panel,
    output wire        status_text,
    output reg  [11:0] accent       // state colour (box outline and label text)
);
    localparam integer LX = BOX_X * 2;
    localparam integer LY = BOX_Y * 2 - 34;
    localparam integer BX0 = BOX_X * 2;
    localparam integer BY0 = BOX_Y * 2;
    localparam integer BX1 = (BOX_X + BOX_W) * 2 - 1;
    localparam integer BY1 = (BOX_Y + BOX_H) * 2 - 1;

    function [7:0] hexch(input [3:0] n);
        hexch = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h41 + {4'b0, n} - 8'd10);
    endfunction
    function [7:0] dig(input [3:0] n);
        dig = 8'h30 + {4'b0, n};
    endfunction
    function [15:0] num2(input [3:0] n);       // 0..10 as two characters ("  " + digit, or "10")
        num2 = (n >= 4'd10) ? {8'h31, 8'h30} : {8'h20, 8'h30 + {4'b0, n}};
    endfunction

    wire [3:0] sel_count = (enrol_sel == 2'd0) ? count0 : (enrol_sel == 2'd1) ? count1 : count2;
    wire       any_missing = (count0 == 4'd0) || (count1 == 4'd0) || (count2 == 4'd0);
    reg [191:0] line1, line2;
    always @* begin
        accent = 12'hFF0;
        line1 = "DETECTING               ";
        line2 = "FACE IN BOX             ";
        if (any_missing)
            line2 = "SW17 UP THEN KEY1/2/3   ";
        if (unk_show) begin
            accent = 12'hF33;
            line1 = "UNKNOWN                 ";
        end
        if (mode == 2'd1) begin
            accent = 12'h0F0;
            case (locked_id)
                2'd0: begin line1 = "ADVAITH V               "; line2 = "PRESENT 26MVD0050       "; end
                2'd1: begin line1 = "NAVANEETH V P           "; line2 = "PRESENT 26MVD0040       "; end
                default: begin line1 = "SAHITI                  "; line2 = "PRESENT 26MVD0036       "; end
            endcase
            if (already) begin
                accent = 12'hF80;
                line2 = "ALREADY MARKED          ";
            end
        end
        if (mode == 2'd2) begin
            accent = 12'h0FF;
            case (enrol_sel)
                2'd0: line1 = "ENROLLING ADVAITH       ";
                2'd1: line1 = "ENROLLING NAVANEETH     ";
                default: line1 = "ENROLLING SAHITI        ";
            endcase
            line2 = {"SAMPLE ", num2(sel_count), " OF 10         "};
            if (sel_count >= 4'd10)
                line2 = "DONE: RELEASE KEY       ";
        end
        if (mode == 2'd3) begin
            accent = 12'hF8F;
            if (mem_status == 3'd4) begin
                case (busy_id)
                    2'd0: line1 = "SAVING ADVAITH          ";
                    2'd1: line1 = "SAVING NAVANEETH        ";
                    default: line1 = "SAVING SAHITI           ";
                endcase
                line2 = "DO NOT POWER OFF        ";
            end else begin
                line1 = "LOADING SAVED FACES     ";
                line2 = "PLEASE WAIT             ";
            end
        end
    end

    reg [63:0] mem_txt;
    always @* begin
        case (mem_status)
            3'd0: mem_txt = "MEM LOAD";
            3'd1: mem_txt = "MEM OK  ";
            3'd2: mem_txt = "MEM NEW ";
            3'd3: mem_txt = "MEM ERR ";
            default: mem_txt = "MEM SAVE";
        endcase
    end
    wire [135:0] r1 = {"SA ", hexch(score0[15:12]), hexch(score0[11:8]), hexch(score0[7:4]), hexch(score0[3:0]),
                       "  T ", hexch(threshold[15:12]), hexch(threshold[11:8]), hexch(threshold[7:4]), hexch(threshold[3:0]), "  "};
    wire [135:0] r2 = {"SN ", hexch(score1[15:12]), hexch(score1[11:8]), hexch(score1[7:4]), hexch(score1[3:0]),
                       "  C ", hexch(contrast[15:12]), hexch(contrast[11:8]), hexch(contrast[7:4]), hexch(contrast[3:0]), "  "};
    wire [135:0] r3 = {"SS ", hexch(score2[15:12]), hexch(score2[11:8]), hexch(score2[7:4]), hexch(score2[3:0]),
                       "  ", mem_txt};
    wire [303:0] bottom = {"A", num2(count0), " N", num2(count1), " S", num2(count2),
                           "  SW17:ENROL  SW3:RESET    "};

    wire p1, t1, p2, t2, p3, t3, p4, t4, p5, t5, p6, t6;
    text_row #(.N(24), .X0(LX), .Y0(LY))      u_l1 (.pixel_x(pixel_x), .pixel_y(pixel_y), .active(active), .message(line1), .panel_on(p1), .text_on(t1));
    text_row #(.N(24), .X0(LX), .Y0(LY + 16)) u_l2 (.pixel_x(pixel_x), .pixel_y(pixel_y), .active(active), .message(line2), .panel_on(p2), .text_on(t2));
    text_row #(.N(17), .X0(352), .Y0(416))    u_s1 (.pixel_x(pixel_x), .pixel_y(pixel_y), .active(active), .message(r1), .panel_on(p3), .text_on(t3));
    text_row #(.N(17), .X0(352), .Y0(432))    u_s2 (.pixel_x(pixel_x), .pixel_y(pixel_y), .active(active), .message(r2), .panel_on(p4), .text_on(t4));
    text_row #(.N(17), .X0(352), .Y0(448))    u_s3 (.pixel_x(pixel_x), .pixel_y(pixel_y), .active(active), .message(r3), .panel_on(p5), .text_on(t5));
    text_row #(.N(38), .X0(16), .Y0(464))     u_s4 (.pixel_x(pixel_x), .pixel_y(pixel_y), .active(active), .message(bottom), .panel_on(p6), .text_on(t6));
    assign label_panel  = p1 | p2;
    assign label_text   = t1 | t2;
    assign status_panel = p3 | p4 | p5 | p6;
    assign status_text  = t3 | t4 | t5 | t6;

    wire in_rect = active && (pixel_x >= BX0) && (pixel_x <= BX1) && (pixel_y >= BY0) && (pixel_y <= BY1);
    wire inner   = (pixel_x >= BX0 + 4) && (pixel_x <= BX1 - 4) && (pixel_y >= BY0 + 4) && (pixel_y <= BY1 - 4);
    assign box_edge = in_rect && !inner;
endmodule

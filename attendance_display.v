// Three-member session attendance panel.
// Row 0 = ID0 ADVAITH, row 1 = ID1 NAVANEETH, row 2 = ID2 SAHITI; each shows
// PRESENT or NOT MARKED. NOT MARKED means "no attendance event since reset", not
// confirmed absence.
//
// The flags are sampled into shown_flags only at frame_start (or cleared by
// reset), so the text cannot change in the middle of a displayed frame.
// Coordinates are the 640x480 VGA raster; the panel is 20 characters of 16x16
// cells, 3 rows (320 x 48 pixels) at (PANEL_X, PANEL_Y).
module attendance_display #(
    parameter [9:0] PANEL_X = 10'd304,
    parameter [8:0] PANEL_Y = 9'd16
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        frame_start,
    input  wire [9:0]  pixel_x,
    input  wire [8:0]  pixel_y,
    input  wire        active,
    input  wire [2:0]  attendance_flags,
    output wire        panel_on,
    output wire        text_on
);
    localparam [9:0] PANEL_W = 10'd320;
    localparam [8:0] PANEL_H = 9'd48;

    reg [2:0] shown_flags = 3'b000;
    always @(posedge clk) begin
        if (reset) shown_flags <= 3'b000;
        else if (frame_start) shown_flags <= attendance_flags;
    end

    wire in_x = (pixel_x >= PANEL_X) && (pixel_x < PANEL_X + PANEL_W);
    wire in_y = (pixel_y >= PANEL_Y) && (pixel_y < PANEL_Y + PANEL_H);
    assign panel_on = active && in_x && in_y;

    wire [9:0] dx = pixel_x - PANEL_X;
    wire [8:0] dy = pixel_y - PANEL_Y;
    wire [4:0] character_index = dx[8:4];
    wire [2:0] column = dx[3:1];
    wire [2:0] row = dy[3:1];

    reg [159:0] message;
    always @* begin
        case (dy[5:4])
            2'd0:    message = shown_flags[0] ? "NAME1   PRESENT   " : "NAME1   NOT MARKED";
            2'd1:    message = shown_flags[1] ? "NAME2 PRESENT   " : "NAME2 NOT MARKED";
            default: message = shown_flags[2] ? "NAME3    PRESENT   " : "NAME3    NOT MARKED";
        endcase
    end
    wire [7:0] character = message[159-character_index*8 -: 8];
    wire [34:0] bits;
    font5x7 u_font (.c(character), .bits(bits));
    assign text_on = panel_on && column<5 && row<7 && bits[34-row*5-column];
endmodule

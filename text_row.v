// One row of N characters, each in a 16x16 cell (5x7 glyph drawn at 2x).
// Coordinates are the 640x480 VGA raster. panel_on covers the whole row (black
// background); text_on is high on glyph pixels.
module text_row #(
    parameter integer N  = 24,
    parameter integer X0 = 0,
    parameter integer Y0 = 0
) (
    input  wire [9:0]       pixel_x,
    input  wire [8:0]       pixel_y,
    input  wire             active,
    input  wire [N*8-1:0]   message,      // first character in the most significant byte
    output wire             panel_on,
    output wire             text_on
);
    wire in_x = (pixel_x >= X0) && (pixel_x < X0 + N*16);
    wire in_y = (pixel_y >= Y0) && (pixel_y < Y0 + 16);
    assign panel_on = active && in_x && in_y;
    wire [9:0] dx = in_x ? pixel_x - X0 : 10'd0;
    wire [8:0] dy = in_y ? pixel_y - Y0 : 9'd0;
    wire [5:0] idx = dx[9:4];
    wire [2:0] column = dx[3:1];
    wire [2:0] row = dy[3:1];
    wire [7:0] character = message[(N-1-idx)*8 +: 8];
    wire [34:0] bits;
    font5x7 u_font (.c(character), .bits(bits));
    assign text_on = panel_on && column < 5 && row < 7 && bits[34 - row*5 - column];
endmodule

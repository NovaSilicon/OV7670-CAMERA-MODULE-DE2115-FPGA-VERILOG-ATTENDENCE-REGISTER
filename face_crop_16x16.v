// Cell-averaged 16x16 grayscale sampler for a FIXED guide box.
//
// The guide box is BOX_W x BOX_H source pixels (16 cells of CELL_W x CELL_H
// pixels in each direction) at (BOX_X, BOX_Y) in the 320x240 framebuffer
// coordinates. Every source pixel inside the box is added into its cell; the
// completed cell sum is divided by CELL_W*CELL_H and stored as an 8-bit value
// (gray 0..60 scaled x4, so 0..239). Averaging ~130 pixels per cell removes the
// heavy sensor noise that a single-point sample would keep, and makes the
// result tolerant of a few pixels of misalignment.
//
// Two 256-byte banks are ping-ponged: one is written while the other (the
// previous complete frame) is read by the matcher. template_valid pulses for
// one clock at frame_start when the bank just finished holds all 256 cells.
// sample_rd_data is a REGISTERED read (data valid 2 clocks after the address
// register changes), so the memory maps onto a block RAM.
module face_crop_16x16 #(
    parameter integer BOX_X  = 64,
    parameter integer BOX_Y  = 32,
    parameter integer CELL_W = 12,
    parameter integer CELL_H = 11
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        frame_start,
    input  wire        pixel_valid,      // one pulse per source pixel
    input  wire [8:0]  pixel_x,
    input  wire [7:0]  pixel_y,
    input  wire [11:0] pixel_rgb444,
    output reg         template_valid,
    output reg         template_bank,
    input  wire [7:0]  sample_rd_addr,
    output reg  [7:0]  sample_rd_data
);
    localparam integer BOX_W = 16 * CELL_W;
    localparam integer BOX_H = 16 * CELL_H;

    reg [7:0]  sample_mem [0:511];
    reg [12:0] cell_acc   [0:15];
    reg        write_bank;
    reg        have_frame;
    reg [8:0]  cells_done;
    reg [3:0]  sx_r, cx_r;          // position of the NEXT in-box pixel in its row
    reg [3:0]  line_sy, line_cy;    // row-within-cell / cell-row of the current line

    wire in_x   = (pixel_x >= BOX_X) && (pixel_x < BOX_X + BOX_W);
    wire in_y   = (pixel_y >= BOX_Y) && (pixel_y < BOX_Y + BOX_H);
    wire in_box = pixel_valid && in_x && in_y;
    wire first_col = (pixel_x == BOX_X);
    wire row0      = (pixel_y == BOX_Y);

    wire [3:0] ux  = first_col ? 4'd0 : sx_r;
    wire [3:0] ucx = first_col ? 4'd0 : cx_r;
    wire       last_sy = (line_sy == CELL_H - 1);
    wire [3:0] nsy = row0 ? 4'd0 : (last_sy ? 4'd0 : line_sy + 4'd1);
    wire [3:0] ncy = row0 ? 4'd0 : (last_sy ? line_cy + 4'd1 : line_cy);
    wire [3:0] usy = first_col ? nsy : line_sy;
    wire [3:0] ucy = first_col ? ncy : line_cy;
    wire       last_ux = (ux == CELL_W - 1);

    wire [3:0] red   = pixel_rgb444[11:8];
    wire [3:0] green = pixel_rgb444[7:4];
    wire [3:0] blue  = pixel_rgb444[3:0];
    wire [5:0] gray  = {2'b00, red} + {1'b0, green, 1'b0} + {2'b00, blue};   // 0..60

    wire        cell_first = (ux == 4'd0) && (usy == 4'd0);
    wire        cell_last  = last_ux && (usy == CELL_H - 1);
    wire [12:0] acc_prev   = cell_acc[ucx];
    wire [12:0] sum_next   = (cell_first ? 13'd0 : acc_prev) + {7'b0, gray};
    // sum / (CELL_W*CELL_H) * 4 ~= sum*31/1024 for the default 12x11 cell.
    wire [17:0] sum31      = {sum_next, 5'b0} - {5'b0, sum_next};
    wire [7:0]  cell_val   = sum31[17:10];

    always @(posedge clk) begin
        sample_rd_data <= sample_mem[{template_bank, sample_rd_addr}];
        if (in_box && cell_last)
            sample_mem[{write_bank, ucy, ucx}] <= cell_val;
    end

    always @(posedge clk) begin
        if (reset) begin
            template_valid <= 1'b0;
            template_bank  <= 1'b0;
            write_bank     <= 1'b0;
            have_frame     <= 1'b0;
            cells_done     <= 9'd0;
            sx_r <= 4'd0; cx_r <= 4'd0; line_sy <= 4'd0; line_cy <= 4'd0;
        end else begin
            template_valid <= 1'b0;
            if (frame_start) begin
                if (have_frame && cells_done == 9'd256) begin
                    template_valid <= 1'b1;
                    template_bank  <= write_bank;
                end
                write_bank <= ~write_bank;
                have_frame <= 1'b1;
                cells_done <= 9'd0;
            end else if (in_box) begin
                cell_acc[ucx] <= sum_next;
                sx_r    <= last_ux ? 4'd0 : ux + 4'd1;
                cx_r    <= last_ux ? ucx + 4'd1 : ucx;
                line_sy <= usy;
                line_cy <= ucy;
                if (cell_last) cells_done <= cells_done + 9'd1;
            end
        end
    end
endmodule

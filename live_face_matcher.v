// Live-enrolled three-person matcher on 16x16 crops, with a template RAM that can be
// loaded from / saved to the EEPROM through the io_* port (see eeprom_store.v).
//
// ENROL: while an enrol key is held (and enrol_en is on), one complete crop is copied
// into that person's next template slot every ENROL_STRIDE frames, up to SLOTS (10)
// slots. Templates are stored with 4-bit precision (value>>4, mid-bin on read-back), exactly as
// they are kept in the EEPROM, so behaviour is identical before and after a power cycle.
// A new press starts overwriting from slot 0 but the old templates stay valid
// until the first new sample arrives, and any old slots beyond the new count are
// dropped only when the key is released (enrol_done pulse -> EEPROM save). A tap with
// no captured sample changes nothing.
//
// MATCH (every frame): score = sum over 256 cells of | (s - mean_s) - (t - mean_t) | for
// each stored template (zero-mean SAD, cancels a global brightness offset); per person
// the lowest template score is kept. A result is accepted only if
//     contrast >= CONTRAST_MIN          (blank wall / skin close-up is not a face)
//     best score <= threshold           (close to an enrolled person)
//     second-best person's score > 1.25 x best + 64   (clearly one person)
// otherwise the id is 3 (unknown). Lower score = better.
//
// One pixel takes 3 clocks, a frame is about 20,000 clocks = 0.8 ms at 25 MHz.
module live_face_matcher #(
    parameter integer CONTRAST_MIN = 2560,
    parameter integer ENROL_STRIDE = 10
) (
    input  wire        clk,
    input  wire        reset,                 // resets the state machine only; templates are kept
    input  wire        template_valid,
    output reg  [7:0]  sample_rd_addr,
    input  wire [7:0]  sample_rd_data,
    input  wire        enrol_en,              // enrol keys are ignored unless this is high
    input  wire        enrol_key0,            // active-high, already synchronised
    input  wire        enrol_key1,
    input  wire        enrol_key2,
    input  wire [15:0] threshold,
    // template memory port used by eeprom_store
    input  wire        io_busy,
    input  wire [13:0] io_raddr,
    output wire [7:0]  io_rdata,
    input  wire        io_we,
    input  wire [13:0] io_waddr,
    input  wire [7:0]  io_wdata,
    input  wire        io_mean_we,
    input  wire [5:0]  io_mean_slot,
    input  wire [7:0]  io_mean_val,
    input  wire        io_cnt_we,
    input  wire [1:0]  io_cnt_id,
    input  wire [3:0]  io_cnt_val,
    output reg         enrol_done,            // 1-clock pulse when an enrolment key is released after capturing
    output reg  [1:0]  enrol_done_id,
    output reg         result_valid,
    output reg  [1:0]  result_id,             // 0, 1, 2 or 3 (unknown)
    output reg         result_face,
    output reg  [15:0] score0,
    output reg  [15:0] score1,
    output reg  [15:0] score2,
    output reg  [15:0] contrast,
    output reg  [3:0]  count0,                // templates stored per person (0..10)
    output reg  [3:0]  count1,
    output reg  [3:0]  count2,
    output wire        enrol_held,
    output wire [1:0]  enrol_sel
);
    localparam [2:0] S_IDLE = 3'd0, S_SUM = 3'd1, S_DEV = 3'd2, S_COPY = 3'd3,
                     S_SLOT = 3'd4, S_MATCH = 3'd5, S_FINAL = 3'd6;
    localparam [17:0] SENTINEL = 18'h3FFFF;
    localparam [3:0]  SLOTS = 4'd10;

    reg [2:0]  state;
    reg [1:0]  ph;
    reg [7:0]  p;
    reg [15:0] sum;
    reg [7:0]  mean;
    reg [15:0] dev;
    reg [17:0] total, best0, best1, best2;
    reg [5:0]  slot;                          // {person[1:0], sample[3:0]}
    reg [47:0] tvalid;
    reg [7:0]  tmean [0:63];
    reg [7:0]  tmpl  [0:16383];
    reg [13:0] tmpl_raddr;
    reg [15:0] qsum;                          // sum of the 4-bit-quantised sample being copied
    reg [7:0]  tmpl_q;
    reg        capture_req;
    reg [3:0]  stride_wait;
    reg [3:0]  wcount0, wcount1, wcount2;     // samples captured in the current enrolment press
    reg        captured0, captured1, captured2;
    reg        e0_d, e1_d, e2_d;

    // keys only count while enabled and while the EEPROM is idle
    wire k0 = enrol_key0 & enrol_en & ~io_busy;
    wire k1 = enrol_key1 & enrol_en & ~io_busy;
    wire k2 = enrol_key2 & enrol_en & ~io_busy;
    assign enrol_held = k0 | k1 | k2;
    assign enrol_sel  = k0 ? 2'd0 : (k1 ? 2'd1 : 2'd2);
    wire [3:0] sel_w = (enrol_sel == 2'd0) ? wcount0 : (enrol_sel == 2'd1) ? wcount1 : wcount2;
    wire sel_rise = (enrol_sel == 2'd0) ? (k0 && !e0_d) : (enrol_sel == 2'd1) ? (k1 && !e1_d) : (k2 && !e2_d);

    // Template memory: one write port (enrol copy or EEPROM load), one registered read port
    // (matching, or EEPROM save while the matcher is paused).
    wire        copy_we = (state == S_COPY) && (ph == 2'd2);
    wire        t_we    = copy_we | io_we;
    wire [13:0] t_waddr = io_we ? io_waddr : {slot, p};
    wire [7:0]  q_cell  = {sample_rd_data[7:4], 4'b1000};
    wire [7:0]  t_wdata = io_we ? io_wdata : q_cell;
    wire [13:0] t_raddr = io_busy ? io_raddr : tmpl_raddr;
    always @(posedge clk) begin
        if (t_we) tmpl[t_waddr] <= t_wdata;
        tmpl_q <= tmpl[t_raddr];
    end
    assign io_rdata = tmpl_q;

    wire [15:0] sum_n = sum + {8'b0, sample_rd_data};
    wire [7:0]  dev_abs = sample_rd_data >= mean ? sample_rd_data - mean : mean - sample_rd_data;
    wire [15:0] dev_n = dev + {8'b0, dev_abs};

    wire signed [10:0] sd = $signed({3'b0, sample_rd_data}) - $signed({3'b0, tmpl_q});
    wire signed [10:0] dm = $signed({3'b0, mean}) - $signed({3'b0, tmean[slot]});
    wire signed [10:0] zd = sd - dm;
    wire [10:0] zabs = zd[10] ? -zd : zd;
    wire [17:0] total_n = total + {7'b0, zabs};

    // winner / runner-up among the three persons
    wire [1:0]  idmin = (best0 <= best1 && best0 <= best2) ? 2'd0 : ((best1 <= best2) ? 2'd1 : 2'd2);
    wire [17:0] min_s = (idmin == 2'd0) ? best0 : (idmin == 2'd1) ? best1 : best2;
    wire [17:0] oth_a = (idmin == 2'd0) ? best1 : best0;
    wire [17:0] oth_b = (idmin == 2'd2) ? best1 : best2;
    wire [17:0] second_s = (oth_a <= oth_b) ? oth_a : oth_b;
    wire [17:0] gap_s = second_s - min_s;
    wire [17:0] thr18 = {2'b00, threshold};
    wire [17:0] margin18 = {2'b0, min_s[17:2]} + 18'd64;
    wire face_ok = (dev >= CONTRAST_MIN);
    wire accept = face_ok && (min_s <= thr18) && (gap_s > margin18);

    function [47:0] slot_mask(input [1:0] id, input [4:0] cnt);   // slots < cnt of person id
        reg [31:0] m;
        begin
            m = (32'd1 << cnt) - 32'd1;
            slot_mask = {32'd0, m[15:0]} << (id * 16);
        end
    endfunction

    initial begin
        state = S_IDLE; ph = 0; p = 0; tvalid = 48'd0; count0 = 0; count1 = 0; count2 = 0;
        capture_req = 0; stride_wait = 0; e0_d = 0; e1_d = 0; e2_d = 0;
        wcount0 = 0; wcount1 = 0; wcount2 = 0; captured0 = 0; captured1 = 0; captured2 = 0;
        enrol_done = 0; enrol_done_id = 0;
        result_valid = 0; result_id = 2'd3; result_face = 0;
        score0 = 16'hFFFF; score1 = 16'hFFFF; score2 = 16'hFFFF; contrast = 0;
    end

    always @(posedge clk) begin
        e0_d <= k0; e1_d <= k1; e2_d <= k2;
        result_valid <= 1'b0;
        enrol_done <= 1'b0;

        // ---- EEPROM load: counts and means arrive through io_* ----
        if (io_mean_we) tmean[io_mean_slot] <= io_mean_val;
        if (io_cnt_we) begin
            tvalid <= (tvalid & ~slot_mask(io_cnt_id, 5'd16)) | slot_mask(io_cnt_id, {1'b0, io_cnt_val});
            if (io_cnt_id == 2'd0) count0 <= io_cnt_val;
            if (io_cnt_id == 2'd1) count1 <= io_cnt_val;
            if (io_cnt_id == 2'd2) count2 <= io_cnt_val;
        end

        // ---- a fresh press restarts the capture sequence (old templates are kept for now) ----
        if (sel_rise) begin
            stride_wait <= 4'd0;
            if (enrol_sel == 2'd0) begin wcount0 <= 4'd0; captured0 <= 1'b0; end
            if (enrol_sel == 2'd1) begin wcount1 <= 4'd0; captured1 <= 1'b0; end
            if (enrol_sel == 2'd2) begin wcount2 <= 4'd0; captured2 <= 1'b0; end
        end

        // ---- release of an enrol key: trim to the new sample count and request the save ----
        if (e0_d && !k0 && captured0) begin
            tvalid <= (tvalid & ~slot_mask(2'd0, 5'd16)) | slot_mask(2'd0, {1'b0, wcount0});
            count0 <= wcount0; captured0 <= 1'b0; enrol_done <= 1'b1; enrol_done_id <= 2'd0;
        end
        if (e1_d && !k1 && captured1) begin
            tvalid <= (tvalid & ~slot_mask(2'd1, 5'd16)) | slot_mask(2'd1, {1'b0, wcount1});
            count1 <= wcount1; captured1 <= 1'b0; enrol_done <= 1'b1; enrol_done_id <= 2'd1;
        end
        if (e2_d && !k2 && captured2) begin
            tvalid <= (tvalid & ~slot_mask(2'd2, 5'd16)) | slot_mask(2'd2, {1'b0, wcount2});
            count2 <= wcount2; captured2 <= 1'b0; enrol_done <= 1'b1; enrol_done_id <= 2'd2;
        end

        if (reset || io_busy) begin
            state <= S_IDLE; ph <= 2'd0; p <= 8'd0; capture_req <= 1'b0;
            sample_rd_addr <= 8'd0;
        end else begin
            case (state)
            S_IDLE: if (template_valid) begin
                p <= 8'd0; ph <= 2'd0; sum <= 16'd0; state <= S_SUM;
                capture_req <= enrol_held && (sel_w < SLOTS) && (stride_wait == 4'd0);
                if (enrol_held && stride_wait != 4'd0) stride_wait <= stride_wait - 4'd1;
            end

            S_SUM: case (ph)
                2'd0: begin sample_rd_addr <= p; ph <= 2'd1; end
                2'd1: ph <= 2'd2;
                default: begin
                    sum <= sum_n; ph <= 2'd0; p <= p + 8'd1;
                    if (p == 8'd255) begin
                        mean <= sum_n[15:8]; dev <= 16'd0; p <= 8'd0; state <= S_DEV;
                    end
                end
            endcase

            S_DEV: case (ph)
                2'd0: begin sample_rd_addr <= p; ph <= 2'd1; end
                2'd1: ph <= 2'd2;
                default: begin
                    dev <= dev_n; ph <= 2'd0; p <= p + 8'd1;
                    if (p == 8'd255) begin
                        contrast <= dev_n;
                        p <= 8'd0;
                        if (capture_req && dev_n >= CONTRAST_MIN) begin
                            slot <= {enrol_sel, sel_w[3:0]};
                            qsum <= 16'd0;
                            state <= S_COPY;
                        end else if (enrol_held) begin
                            state <= S_FINAL;               // no matching while enrolling
                            best0 <= SENTINEL; best1 <= SENTINEL; best2 <= SENTINEL;
                        end else begin
                            slot <= 6'd0; best0 <= SENTINEL; best1 <= SENTINEL; best2 <= SENTINEL;
                            state <= S_SLOT;
                        end
                    end
                end
            endcase

            S_COPY: case (ph)
                2'd0: begin sample_rd_addr <= p; ph <= 2'd1; end
                2'd1: ph <= 2'd2;
                default: begin
                    ph <= 2'd0; p <= p + 8'd1;
                    qsum <= qsum + {8'd0, q_cell};
                    if (p == 8'd255) begin
                        tmean[slot] <= (qsum + {8'd0, q_cell}) >> 8;
                        tvalid[slot] <= 1'b1;
                        if (slot[5:4] == 2'd0) begin wcount0 <= wcount0 + 4'd1; captured0 <= 1'b1; count0 <= wcount0 + 4'd1; end
                        if (slot[5:4] == 2'd1) begin wcount1 <= wcount1 + 4'd1; captured1 <= 1'b1; count1 <= wcount1 + 4'd1; end
                        if (slot[5:4] == 2'd2) begin wcount2 <= wcount2 + 4'd1; captured2 <= 1'b1; count2 <= wcount2 + 4'd1; end
                        stride_wait <= ENROL_STRIDE - 1;
                        best0 <= SENTINEL; best1 <= SENTINEL; best2 <= SENTINEL;
                        state <= S_FINAL;
                    end
                end
            endcase

            S_SLOT: begin
                if (slot == 6'd48) state <= S_FINAL;
                else if (tvalid[slot]) begin
                    p <= 8'd0; ph <= 2'd0; total <= 18'd0; state <= S_MATCH;
                end else slot <= slot + 6'd1;
            end

            S_MATCH: case (ph)
                2'd0: begin sample_rd_addr <= p; tmpl_raddr <= {slot, p}; ph <= 2'd1; end
                2'd1: ph <= 2'd2;
                default: begin
                    total <= total_n; ph <= 2'd0; p <= p + 8'd1;
                    if (p == 8'd255) begin
                        if (slot[5:4] == 2'd0 && total_n < best0) best0 <= total_n;
                        if (slot[5:4] == 2'd1 && total_n < best1) best1 <= total_n;
                        if (slot[5:4] == 2'd2 && total_n < best2) best2 <= total_n;
                        slot <= slot + 6'd1; state <= S_SLOT;
                    end
                end
            endcase

            S_FINAL: begin
                score0 <= (|best0[17:16]) ? 16'hFFFF : best0[15:0];
                score1 <= (|best1[17:16]) ? 16'hFFFF : best1[15:0];
                score2 <= (|best2[17:16]) ? 16'hFFFF : best2[15:0];
                result_face <= (contrast >= CONTRAST_MIN);
                result_id   <= (!enrol_held && accept) ? idmin : 2'd3;
                result_valid <= 1'b1;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

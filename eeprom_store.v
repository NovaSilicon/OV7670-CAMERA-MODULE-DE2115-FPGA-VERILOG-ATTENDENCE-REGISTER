// Non-volatile storage of the enrolled face templates in the DE2-115 on-board
// 32 Kbit I2C EEPROM (device address 0xA0/0xA1, 16-bit word address).
//
// EEPROM image (4096 bytes available, 3856 used):
//   0x000..0x00F  header: [0]=0xA5 magic, [1]=0x02 version, [2..4]=template count of
//                 person 0..2 (0..10), rest 0
//   0x010...      30 templates x 128 bytes, 4 bits per cell (two cells per byte, high
//                 nibble first): person0 slot0..9, person1 slot0..9, person2 slot0..9.
//                 The matcher keeps the same 4-bit precision in its RAM (value>>4, read
//                 back as {nibble,4'b1000}), so saving and loading lose nothing.
//
// LOAD  (after BOOT_DELAY clocks, and on `reload`): read the whole image in one
//       sequential read, write the templates into the matcher RAM (io_*), compute the
//       per-template mean, and set the person counts. Blank/unknown image -> status NEW.
// SAVE  (save_req): write that person's templates in 8-byte writes (smaller than any
//       EEPROM page, ack-polled for the internal write cycle), then rewrite the header
//       last, so an interrupted save never advertises data that was not written.
// While loading or saving io_busy is high and the matcher is paused.
// status: 0 LOADING, 1 OK, 2 NEW (EEPROM blank), 3 ERR (no ack / timeout), 4 SAVING
module eeprom_store #(
    parameter integer DIV        = 62,
    parameter [6:0]   DEV        = 7'h50,
    parameter integer BOOT_DELAY = 2500000          // 0.1 s at 25 MHz
) (
    input  wire        clk,
    output wire        scl,
    output wire        sda_oe,
    input  wire        sda_i,
    input  wire        reload,
    output reg         io_busy,
    output reg  [13:0] io_raddr,
    input  wire [7:0]  io_rdata,
    output reg         io_we,
    output reg  [13:0] io_waddr,
    output reg  [7:0]  io_wdata,
    output reg         io_mean_we,
    output reg  [5:0]  io_mean_slot,
    output reg  [7:0]  io_mean_val,
    output reg         io_cnt_we,
    output reg  [1:0]  io_cnt_id,
    output reg  [3:0]  io_cnt_val,
    input  wire        save_req,
    input  wire [1:0]  save_id,
    input  wire [3:0]  cur_cnt0,
    input  wire [3:0]  cur_cnt1,
    input  wire [3:0]  cur_cnt2,
    output reg  [2:0]  status,
    output reg  [1:0]  busy_id
);
    localparam [5:0]
        S_BOOT = 6'd0,  S_IDLE = 6'd1,  S_WAIT0 = 6'd2,  S_WAIT1 = 6'd3,
        L_START = 6'd4, L_CTRLW = 6'd5, L_CHK1 = 6'd6,   L_AH = 6'd7,    L_AL = 6'd8,
        L_RSTART = 6'd9, L_CTRLR = 6'd10, L_CHK2 = 6'd11, L_RD = 6'd12,  L_GOT = 6'd13,
        L_STOP = 6'd14, L_FIN = 6'd15, L_C0 = 6'd16, L_C1 = 6'd17, L_C2 = 6'd18,
        W_BEGIN = 6'd20, W_START = 6'd21, W_CTRL = 6'd22, W_CHK1 = 6'd23, W_AH = 6'd24,
        W_AL = 6'd25, W_FETCH = 6'd26, W_FETCH2 = 6'd27, W_DATA = 6'd28, W_BYTE = 6'd29,
        W_STOP = 6'd30, P_START = 6'd31, P_CTRL = 6'd32, P_CHK = 6'd33, P_STOP = 6'd34,
        P_STOPN = 6'd35, W_NEXT = 6'd36, S_DONE = 6'd37, S_ERR = 6'd38, S_ERRSTOP = 6'd39, L_DONE = 6'd40,
        L_GOT2 = 6'd41, W_FETCHB = 6'd42, W_FETCHB2 = 6'd43;
    localparam [2:0] C_START = 3'd1, C_STOP = 3'd2, C_WRITE = 3'd3, C_RACK = 3'd4, C_RNACK = 3'd5;
    localparam integer IMAGE_BYTES = 3856;

    reg        m_cv;
    reg  [2:0] m_cmd;
    reg  [7:0] m_wd;
    wire       m_busy, m_ack;
    wire [7:0] m_rd;
    i2c_byte_master #(.DIV(DIV)) u_i2c (
        .clk(clk), .cmd_valid(m_cv), .cmd(m_cmd), .wdata(m_wd),
        .busy(m_busy), .rdata(m_rd), .ack(m_ack), .scl(scl), .sda_oe(sda_oe), .sda_i(sda_i)
    );

    reg [5:0]  st, ret;
    reg [31:0] delay;
    reg [11:0] n;
    reg [1:0]  tid;
    reg [3:0]  tsl;
    reg [7:0]  tpix;
    reg [3:0]  hbuf;
    reg [15:0] tsum;
    reg [7:0]  h0, h1;
    reg [3:0]  scnt0, scnt1, scnt2;       // counts currently stored in the EEPROM header
    reg        pend;
    reg [1:0]  pend_id;
    reg [1:0]  sid;
    reg [3:0]  ssl;
    reg [3:0]  sv_cnt;
    reg [4:0]  chunk;
    reg [3:0]  bi;
    reg [15:0] wa;
    reg        hdr_mode;
    reg [7:0]  poll;
    reg [3:0]  pc;                         // plain counter helper

    function [7:0] hdr_byte(input [3:0] i, input [3:0] a, input [3:0] b, input [3:0] c);
        case (i)
            4'd0: hdr_byte = 8'hA5;
            4'd1: hdr_byte = 8'h02;
            4'd2: hdr_byte = {4'd0, a};
            4'd3: hdr_byte = {4'd0, b};
            4'd4: hdr_byte = {4'd0, c};
            default: hdr_byte = 8'h00;
        endcase
    endfunction
    function [3:0] min10(input [7:0] v);
        min10 = (v > 8'd10) ? 4'd10 : v[3:0];
    endfunction
    wire [4:0] tbase = (sid == 2'd0) ? 5'd0 : (sid == 2'd1) ? 5'd10 : 5'd20;
    wire [4:0] tidx  = tbase + {1'b0, ssl};

    initial begin
        st = S_BOOT; ret = S_IDLE; delay = 32'd0; io_busy = 1'b1; status = 3'd0; busy_id = 2'd3;
        m_cv = 1'b0; m_cmd = 3'd0; m_wd = 8'd0;
        io_raddr = 13'd0; io_we = 1'b0; io_waddr = 13'd0; io_wdata = 8'd0;
        io_mean_we = 1'b0; io_mean_slot = 5'd0; io_mean_val = 8'd0;
        io_cnt_we = 1'b0; io_cnt_id = 2'd0; io_cnt_val = 4'd0;
        n = 12'd0; tid = 2'd0; tsl = 4'd0; hbuf = 4'd0; tpix = 8'd0; tsum = 16'd0; h0 = 8'd0; h1 = 8'd0;
        scnt0 = 4'd0; scnt1 = 4'd0; scnt2 = 4'd0; pend = 1'b0; pend_id = 2'd0;
        sid = 2'd0; ssl = 4'd0; sv_cnt = 4'd0; chunk = 5'd0; bi = 4'd0; wa = 16'd0;
        hdr_mode = 1'b0; poll = 8'd0; pc = 4'd0;
    end

    always @(posedge clk) begin
        io_we <= 1'b0; io_mean_we <= 1'b0; io_cnt_we <= 1'b0; m_cv <= 1'b0;
        if (save_req) begin pend <= 1'b1; pend_id <= save_id; end

        case (st)
        S_BOOT: begin
            delay <= delay + 32'd1;
            if (delay >= BOOT_DELAY) st <= L_START;
        end

        S_IDLE: begin
            if (reload) begin
                io_busy <= 1'b1; status <= 3'd0; st <= L_START;
            end else if (pend && !save_req) begin
                pend <= 1'b0;
                io_busy <= 1'b1; status <= 3'd4; busy_id <= pend_id; sid <= pend_id;
                sv_cnt <= (pend_id == 2'd0) ? cur_cnt0 : (pend_id == 2'd1) ? cur_cnt1 : cur_cnt2;
                ssl <= 4'd0; chunk <= 5'd0; hdr_mode <= 1'b0;
                st <= W_BEGIN;
            end
        end

        // ---- generic wait for the byte engine ----
        S_WAIT0: st <= S_WAIT1;
        S_WAIT1: if (!m_busy) st <= ret;

        // ---------------- LOAD ----------------
        L_START:  begin m_cmd <= C_START; m_cv <= 1'b1; ret <= L_CTRLW; st <= S_WAIT0; n <= 12'd0;
                        tid <= 2'd0; tsl <= 4'd0; tpix <= 8'd0; tsum <= 16'd0; end
        L_CTRLW:  begin m_cmd <= C_WRITE; m_wd <= {DEV, 1'b0}; m_cv <= 1'b1; ret <= L_CHK1; st <= S_WAIT0; end
        L_CHK1:   if (!m_ack) st <= S_ERRSTOP; else begin
                      m_cmd <= C_WRITE; m_wd <= 8'h00; m_cv <= 1'b1; ret <= L_AH; st <= S_WAIT0; end
        L_AH:     begin m_cmd <= C_WRITE; m_wd <= 8'h00; m_cv <= 1'b1; ret <= L_AL; st <= S_WAIT0; end
        L_AL:     begin m_cmd <= C_START; m_cv <= 1'b1; ret <= L_CTRLR; st <= S_WAIT0; end
        L_CTRLR:  begin m_cmd <= C_WRITE; m_wd <= {DEV, 1'b1}; m_cv <= 1'b1; ret <= L_CHK2; st <= S_WAIT0; end
        L_CHK2:   if (!m_ack) st <= S_ERRSTOP; else st <= L_RD;
        L_RD:     begin m_cmd <= (n == IMAGE_BYTES - 1) ? C_RNACK : C_RACK; m_cv <= 1'b1;
                        ret <= L_GOT; st <= S_WAIT0; end
        L_GOT: begin
            if (n < 12'd16) begin
                if (n == 12'd0) h0 <= m_rd;
                if (n == 12'd1) h1 <= m_rd;
                if (n == 12'd2) scnt0 <= min10(m_rd);
                if (n == 12'd3) scnt1 <= min10(m_rd);
                if (n == 12'd4) scnt2 <= min10(m_rd);
                n <= n + 12'd1;
                st <= (n == IMAGE_BYTES - 1) ? L_STOP : L_RD;
            end else begin
                // high nibble = cell tpix
                io_we <= 1'b1; io_waddr <= {tid, tsl, tpix}; io_wdata <= {m_rd[7:4], 4'b1000};
                tsum <= tsum + {8'd0, m_rd[7:4], 4'b1000};
                st <= L_GOT2;
            end
        end
        L_GOT2: begin
            // low nibble = cell tpix+1
            io_we <= 1'b1; io_waddr <= {tid, tsl, tpix[7:1], 1'b1}; io_wdata <= {m_rd[3:0], 4'b1000};
            tpix <= tpix + 8'd2;
            if (tpix == 8'd254) begin
                io_mean_we <= 1'b1; io_mean_slot <= {tid, tsl};
                io_mean_val <= (tsum + {8'd0, m_rd[3:0], 4'b1000}) >> 8;
                tsum <= 16'd0;
                if (tsl == 4'd9) begin tsl <= 4'd0; tid <= tid + 2'd1; end
                else tsl <= tsl + 4'd1;
            end else tsum <= tsum + {8'd0, m_rd[3:0], 4'b1000};
            n <= n + 12'd1;
            st <= (n == IMAGE_BYTES - 1) ? L_STOP : L_RD;
        end
        L_STOP:   begin m_cmd <= C_STOP; m_cv <= 1'b1; ret <= L_FIN; st <= S_WAIT0; end
        L_FIN: begin
            if (h0 == 8'hA5 && h1 == 8'h02) begin
                status <= 3'd1; st <= L_C0;
            end else begin
                scnt0 <= 4'd0; scnt1 <= 4'd0; scnt2 <= 4'd0;
                status <= 3'd2; io_busy <= 1'b0; st <= S_IDLE;
            end
        end
        L_C0: begin io_cnt_we <= 1'b1; io_cnt_id <= 2'd0; io_cnt_val <= scnt0; st <= L_C1; end
        L_C1: begin io_cnt_we <= 1'b1; io_cnt_id <= 2'd1; io_cnt_val <= scnt1; st <= L_C2; end
        L_C2: begin io_cnt_we <= 1'b1; io_cnt_id <= 2'd2; io_cnt_val <= scnt2; st <= L_DONE; end
        L_DONE: begin io_busy <= 1'b0; st <= S_IDLE; end            // one cycle after the last count write

        // ---------------- SAVE ----------------
        W_BEGIN: begin
            if (hdr_mode) wa <= {12'd0, chunk[0], 3'b000};            // header chunk 0 -> 0x00, chunk 1 -> 0x08
            else          wa <= 16'd16 + {4'd0, tidx, 7'd0} + {8'd0, chunk, 3'b000};
            if (!hdr_mode && sv_cnt == 4'd0) begin                    // nothing to store: header only
                hdr_mode <= 1'b1; chunk <= 5'd0;
                if (sid == 2'd0) scnt0 <= 4'd0;
                if (sid == 2'd1) scnt1 <= 4'd0;
                if (sid == 2'd2) scnt2 <= 4'd0;
            end else st <= W_START;
        end
        W_START:  begin m_cmd <= C_START; m_cv <= 1'b1; ret <= W_CTRL; st <= S_WAIT0; bi <= 4'd0; end
        W_CTRL:   begin m_cmd <= C_WRITE; m_wd <= {DEV, 1'b0}; m_cv <= 1'b1; ret <= W_CHK1; st <= S_WAIT0; end
        W_CHK1:   if (!m_ack) st <= S_ERRSTOP; else begin
                      m_cmd <= C_WRITE; m_wd <= wa[15:8]; m_cv <= 1'b1; ret <= W_AH; st <= S_WAIT0; end
        W_AH:     begin m_cmd <= C_WRITE; m_wd <= wa[7:0]; m_cv <= 1'b1; ret <= W_AL; st <= S_WAIT0; end
        W_AL:     st <= hdr_mode ? W_DATA : W_FETCH;
        // one EEPROM byte = two RAM cells: fetch the first (high nibble), then the second
        W_FETCH:  begin io_raddr <= {sid, ssl, chunk[3:0], bi[2:0], 1'b0}; st <= W_FETCH2; end
        W_FETCH2: st <= W_FETCHB;
        W_FETCHB: begin hbuf <= io_rdata[7:4]; io_raddr <= {sid, ssl, chunk[3:0], bi[2:0], 1'b1}; st <= W_FETCHB2; end
        W_FETCHB2: st <= W_DATA;
        W_DATA: begin
            m_cmd <= C_WRITE; m_cv <= 1'b1; ret <= W_BYTE; st <= S_WAIT0;
            if (hdr_mode) m_wd <= hdr_byte({chunk[0], bi[2:0]}, scnt0, scnt1, scnt2);
            else          m_wd <= {hbuf, io_rdata[7:4]};
        end
        W_BYTE: begin
            bi <= bi + 4'd1;
            if (bi == 4'd7) st <= W_STOP; else st <= hdr_mode ? W_DATA : W_FETCH;
        end
        W_STOP:   begin m_cmd <= C_STOP; m_cv <= 1'b1; ret <= P_START; st <= S_WAIT0; poll <= 8'd0; end
        // ack polling: the EEPROM does not acknowledge while its internal write cycle runs
        P_START:  begin m_cmd <= C_START; m_cv <= 1'b1; ret <= P_CTRL; st <= S_WAIT0; end
        P_CTRL:   begin m_cmd <= C_WRITE; m_wd <= {DEV, 1'b0}; m_cv <= 1'b1; ret <= P_CHK; st <= S_WAIT0; end
        P_CHK: begin
            if (m_ack) st <= P_STOP;
            else if (poll == 8'd250) st <= S_ERRSTOP;
            else begin poll <= poll + 8'd1; st <= P_STOPN; end
        end
        P_STOP:   begin m_cmd <= C_STOP; m_cv <= 1'b1; ret <= W_NEXT; st <= S_WAIT0; end
        P_STOPN:  begin m_cmd <= C_STOP; m_cv <= 1'b1; ret <= P_START; st <= S_WAIT0; end
        W_NEXT: begin
            if (hdr_mode) begin
                if (chunk == 5'd1) st <= S_DONE;
                else begin chunk <= chunk + 5'd1; st <= W_BEGIN; end
            end else begin
                if (chunk == 5'd15) begin
                    chunk <= 5'd0;
                    if ({1'b0, ssl} + 5'd1 >= {1'b0, sv_cnt}) begin
                        hdr_mode <= 1'b1;
                        if (sid == 2'd0) scnt0 <= sv_cnt;
                        if (sid == 2'd1) scnt1 <= sv_cnt;
                        if (sid == 2'd2) scnt2 <= sv_cnt;
                    end else ssl <= ssl + 4'd1;
                end else chunk <= chunk + 5'd1;
                st <= W_BEGIN;
            end
        end
        S_DONE: begin status <= 3'd1; io_busy <= 1'b0; busy_id <= 2'd3; st <= S_IDLE; end

        // ---------------- error ----------------
        S_ERRSTOP: begin m_cmd <= C_STOP; m_cv <= 1'b1; ret <= S_ERR; st <= S_WAIT0; end
        S_ERR:     begin status <= 3'd3; io_busy <= 1'b0; busy_id <= 2'd3; st <= S_IDLE; end
        default:   st <= S_IDLE;
        endcase
    end
endmodule

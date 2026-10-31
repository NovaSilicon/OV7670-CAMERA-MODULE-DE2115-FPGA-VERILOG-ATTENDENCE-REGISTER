// DE2-115 camera attendance demo: supplied OV7670 camera path (unchanged) +
// fixed guide box with cell-averaged 16x16 crop + live on-board enrolment of three
// people (KEY[1], KEY[2], KEY[3] with SW[17] up) + templates stored permanently in
// the on-board EEPROM + presence tracker that locks a name, holds PRESENT on the box
// label for ~1.5 s and then scans again.
module top_ov7670_vga_detect #(
    parameter integer I2C_DIV    = 62,        // EEPROM bus: 25 MHz / (4*62) ~ 100 kHz
    parameter integer BOOT_DELAY = 2500000    // 0.1 s before the saved faces are loaded
) (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [17:0] SW,
    output wire [8:0]  LEDG,
    inout  wire [35:0] GPIO,
    output wire [7:0]  VGA_R,
    output wire [7:0]  VGA_G,
    output wire [7:0]  VGA_B,
    output wire        VGA_CLK,
    output wire        VGA_BLANK_N,
    output wire        VGA_SYNC_N,
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire        EEP_I2C_SCLK,
    inout  wire        EEP_I2C_SDAT
);
    wire cam_sioc, cam_xclk, cam_reset, cam_pwdn, cfg_done;
    assign GPIO[0] = cam_sioc;
    assign GPIO[1] = 1'bz;
    assign GPIO[2] = 1'bz;
    assign GPIO[3] = 1'bz;
    assign GPIO[4] = 1'bz;
    assign GPIO[5] = cam_xclk;
    assign GPIO[13:6] = 8'bz;
    assign GPIO[14] = cam_reset;
    assign GPIO[15] = cam_pwdn;
    assign GPIO[35:16] = 20'bz;

    wire cam_vsync = GPIO[2];
    wire cam_href  = GPIO[3];
    wire cam_pclk  = GPIO[4];
    wire [7:0] cam_d = GPIO[13:6];

    reg vga_clk_r = 1'b0;
    always @(posedge CLOCK_50) vga_clk_r <= ~vga_clk_r;
    wire vga_clk = vga_clk_r;

    reg [1:0] resend_sync = 2'b00;
    always @(posedge CLOCK_50) resend_sync <= {resend_sync[0], ~KEY[0]};
    ov7670_controller u_cam_ctrl (
        .clk(CLOCK_50), .resend(resend_sync[1]),
        .config_finished(cfg_done), .sioc(cam_sioc), .siod(GPIO[1]),
        .reset(cam_reset), .pwdn(cam_pwdn), .xclk(cam_xclk)
    );

    reg [1:0] freeze_sync = 2'b00;
    always @(posedge cam_pclk) freeze_sync <= {freeze_sync[0], SW[1]};
    wire capture_en = ~freeze_sync[1];
    wire [16:0] wr_addr;
    wire [11:0] wr_data;
    wire wr_en, cap_busy;
    ov7670_capture u_capture (
        .pclk(cam_pclk), .capture(capture_en), .vsync(cam_vsync),
        .href(cam_href), .d(cam_d), .addr(wr_addr), .dout(wr_data),
        .we(wr_en), .busy(cap_busy)
    );

    wire [16:0] rd_addr;
    wire [11:0] rd_data;
    wire vga_hs, vga_vs, vga_active;
    wire [11:0] test_pix;
    frame_buffer u_fb (
        .wclk(cam_pclk), .we(wr_en), .waddr(wr_addr), .wdata(wr_data),
        .rclk(vga_clk), .raddr(rd_addr), .rdata(rd_data)
    );
    vga_timing u_vga (
        .clk(vga_clk), .raddr(rd_addr), .hs(vga_hs), .vs(vga_vs),
        .active(vga_active), .test_pix(test_pix)
    );

    // Coordinates for the VGA stream, which displays each source pixel 2x2.
    reg [9:0] scan_x = 10'd0;
    reg [8:0] scan_y = 9'd0;
    reg active_prev = 1'b0;
    reg [1:0] detector_reset_sync = 2'b11;
    always @(posedge vga_clk)
        detector_reset_sync <= {detector_reset_sync[0], SW[3]};   // SW[3] up = reset attendance/tracker

    always @(posedge vga_clk) begin
        active_prev <= vga_active;
        if (!vga_active) scan_x <= 10'd0;
        else if (scan_x < 10'd639) scan_x <= scan_x + 1'b1;

        if (!vga_vs) scan_y <= 9'd0;
        else if (active_prev && !vga_active) begin
            if (scan_y < 9'd479) scan_y <= scan_y + 1'b1;
            else scan_y <= 9'd0;
        end
    end

    wire detector_frame_start = vga_active && !active_prev && (scan_y == 0);
    wire pixel_valid = vga_active && !detector_frame_start &&
                       !scan_x[0] && !scan_y[0];

    // Enrol keys: KEY[1] NAME1, KEY[2] NAME2, KEY[3] NAME3. They only act while
    // SW[17] (enrol enable) is up, so an accidental press cannot touch stored faces.
    reg [1:0] enrol0_sync = 2'b00, enrol1_sync = 2'b00, enrol2_sync = 2'b00, enable_sync = 2'b00;
    always @(posedge vga_clk) begin
        enrol0_sync <= {enrol0_sync[0], ~KEY[1]};
        enrol1_sync <= {enrol1_sync[0], ~KEY[2]};
        enrol2_sync <= {enrol2_sync[0], ~KEY[3]};
        enable_sync <= {enable_sync[0], SW[17]};
    end
    // Matching threshold from SW[15:12]: 0x1000 + 0x200 * value (all down = 0x1000).
    reg [3:0] thr_sync0 = 4'd0, thr_sync1 = 4'd0;
    always @(posedge vga_clk) begin
        thr_sync0 <= SW[15:12];
        thr_sync1 <= thr_sync0;
    end
    wire [15:0] match_threshold = 16'h1000 + {3'b000, thr_sync1, 9'b0};

    wire crop_template_valid, crop_template_bank;
    wire [7:0] crop_rd_addr, crop_rd_data;
    face_crop_16x16 #(.BOX_X(64), .BOX_Y(32), .CELL_W(12), .CELL_H(11)) u_face_crop (
        .clk(vga_clk), .reset(detector_reset_sync[1]),
        .frame_start(detector_frame_start), .pixel_valid(pixel_valid),
        .pixel_x(scan_x[9:1]), .pixel_y(scan_y[8:1]), .pixel_rgb444(rd_data),
        .template_valid(crop_template_valid), .template_bank(crop_template_bank),
        .sample_rd_addr(crop_rd_addr), .sample_rd_data(crop_rd_data)
    );

    wire result_valid, result_face, enrol_held, enrol_done;
    wire [1:0] result_id, enrol_sel, enrol_done_id;
    wire [15:0] score0, score1, score2, contrast;
    wire [3:0] count0, count1, count2;
    wire io_busy, io_we, io_mean_we, io_cnt_we;
    wire [13:0] io_raddr, io_waddr;
    wire [7:0] io_rdata, io_wdata, io_mean_val;
    wire [5:0] io_mean_slot;
    wire [1:0] io_cnt_id, busy_id;
    wire [3:0] io_cnt_val;
    wire [2:0] mem_status;
    live_face_matcher #(.CONTRAST_MIN(2560), .ENROL_STRIDE(10)) u_matcher (
        .clk(vga_clk), .reset(detector_reset_sync[1]),
        .template_valid(crop_template_valid),
        .sample_rd_addr(crop_rd_addr), .sample_rd_data(crop_rd_data),
        .enrol_en(enable_sync[1]),
        .enrol_key0(enrol0_sync[1]), .enrol_key1(enrol1_sync[1]), .enrol_key2(enrol2_sync[1]),
        .threshold(match_threshold),
        .io_busy(io_busy), .io_raddr(io_raddr), .io_rdata(io_rdata),
        .io_we(io_we), .io_waddr(io_waddr), .io_wdata(io_wdata),
        .io_mean_we(io_mean_we), .io_mean_slot(io_mean_slot), .io_mean_val(io_mean_val),
        .io_cnt_we(io_cnt_we), .io_cnt_id(io_cnt_id), .io_cnt_val(io_cnt_val),
        .enrol_done(enrol_done), .enrol_done_id(enrol_done_id),
        .result_valid(result_valid), .result_id(result_id), .result_face(result_face),
        .score0(score0), .score1(score1), .score2(score2), .contrast(contrast),
        .count0(count0), .count1(count1), .count2(count2),
        .enrol_held(enrol_held), .enrol_sel(enrol_sel)
    );

    // Permanent storage: the enrolled templates live in the on-board EEPROM and are
    // loaded automatically after every power-up / reprogramming.
    wire eep_sda_oe;
    assign EEP_I2C_SDAT = eep_sda_oe ? 1'b0 : 1'bz;
    eeprom_store #(.DIV(I2C_DIV), .BOOT_DELAY(BOOT_DELAY)) u_eeprom (
        .clk(vga_clk), .scl(EEP_I2C_SCLK), .sda_oe(eep_sda_oe), .sda_i(EEP_I2C_SDAT),
        .reload(1'b0),
        .io_busy(io_busy), .io_raddr(io_raddr), .io_rdata(io_rdata),
        .io_we(io_we), .io_waddr(io_waddr), .io_wdata(io_wdata),
        .io_mean_we(io_mean_we), .io_mean_slot(io_mean_slot), .io_mean_val(io_mean_val),
        .io_cnt_we(io_cnt_we), .io_cnt_id(io_cnt_id), .io_cnt_val(io_cnt_val),
        .save_req(enrol_done), .save_id(enrol_done_id),
        .cur_cnt0(count0), .cur_cnt1(count1), .cur_cnt2(count2),
        .status(mem_status), .busy_id(busy_id)
    );

    wire [1:0] mode, locked_id;
    wire unk_show, lock_pulse;
    wire [7:0] hold_left;
    presence_tracker #(.HOLD_FRAMES(90), .LOCK_ACC(12), .HIT_INC(2), .UNK_FRAMES(20)) u_tracker (
        .clk(vga_clk), .reset(detector_reset_sync[1]),
        .frame_start(detector_frame_start),
        .result_valid(result_valid), .result_id(result_id), .result_face(result_face),
        .enrol_held(enrol_held), .busy(io_busy),
        .mode(mode), .locked_id(locked_id), .unk_show(unk_show),
        .lock_pulse(lock_pulse), .hold_left(hold_left)
    );

    // Session attendance is marked once, when a person is LOCKED (not per frame).
    wire [2:0] attendance_flags;
    wire attendance_event, attendance_dup;
    wire [1:0] attendance_event_id;
    attendance_latch u_attendance (
        .clk(vga_clk), .reset(detector_reset_sync[1]),
        .recognition_valid(lock_pulse), .recognized_id(locked_id),
        .attendance_flags(attendance_flags), .event_pulse(attendance_event),
        .event_student_id(attendance_event_id), .dup_pulse(attendance_dup)
    );
    // Remember, for the current LOCK, whether this person had been marked before.
    reg already_marked = 1'b0;
    always @(posedge vga_clk) begin
        if (attendance_dup)        already_marked <= 1'b1;
        else if (attendance_event) already_marked <= 1'b0;
    end

    wire box_edge, label_panel, label_text, status_panel, status_text;
    wire [11:0] accent;
    box_label_overlay #(.BOX_X(64), .BOX_Y(32), .BOX_W(192), .BOX_H(176)) u_overlay (
        .pixel_x(scan_x), .pixel_y(scan_y), .active(vga_active),
        .mode(mode), .locked_id(locked_id), .unk_show(unk_show), .already(already_marked),
        .enrol_sel(enrol_sel), .count0(count0), .count1(count1), .count2(count2),
        .score0(score0), .score1(score1), .score2(score2),
        .threshold(match_threshold), .contrast(contrast),
        .mem_status(mem_status), .busy_id(busy_id),
        .box_edge(box_edge), .label_panel(label_panel), .label_text(label_text),
        .status_panel(status_panel), .status_text(status_text), .accent(accent)
    );

    // Attendance status panel (bottom left, below the box).
    wire attendance_panel, attendance_pixel;
    attendance_display #(.PANEL_X(10'd16), .PANEL_Y(9'd416)) u_attendance_display (
        .clk(vga_clk), .reset(detector_reset_sync[1]),
        .frame_start(detector_frame_start),
        .pixel_x(scan_x), .pixel_y(scan_y), .active(vga_active),
        .attendance_flags(attendance_flags),
        .panel_on(attendance_panel), .text_on(attendance_pixel)
    );

    reg [1:0] grey_sync = 2'b00;
    reg [1:0] test_sync = 2'b00;
    always @(posedge vga_clk) begin
        grey_sync <= {grey_sync[0], SW[0]};
        test_sync <= {test_sync[0], SW[2]};
    end
    wire [7:0] grey;
    RGB2GREY u_grey (.Din(rd_data), .Dout(grey));
    wire [11:0] cam_pix = grey_sync[1] ? {grey[7:4], grey[7:4], grey[7:4]} : rd_data;
    wire [11:0] base_pix = test_sync[1] ? test_pix : cam_pix;
    // Priority: attendance panel > status text > label text (state colour) > box outline > camera.
    wire [11:0] overlay_pix = attendance_panel ?
        (attendance_pixel ? 12'hFFF : 12'h000) :
        status_panel ? (status_text ? 12'hFFF : 12'h000) :
        label_panel ? (label_text ? accent : 12'h000) :
        box_edge ? accent : base_pix;
    wire [7:0] rgb_r, rgb_g, rgb_b;
    RGB u_rgb (
        .Din(overlay_pix), .Nblank(vga_active),
        .R(rgb_r), .G(rgb_g), .B(rgb_b)
    );
    // The overlay logic (text muxes + font ROM) is deeper than the old design,
    // so the whole VGA output bundle is registered once. Colour, blanking and
    // sync all move together by one 25 MHz clock, so their alignment is kept.
    reg [7:0] out_r = 8'd0, out_g = 8'd0, out_b = 8'd0;
    reg out_hs = 1'b1, out_vs = 1'b1, out_blank = 1'b0;
    always @(posedge vga_clk) begin
        out_r <= rgb_r; out_g <= rgb_g; out_b <= rgb_b;
        out_hs <= vga_hs; out_vs <= vga_vs; out_blank <= vga_active;
    end
    assign VGA_R = out_r;
    assign VGA_G = out_g;
    assign VGA_B = out_b;
    assign VGA_CLK = vga_clk;
    assign VGA_HS = out_hs;
    assign VGA_VS = out_vs;
    assign VGA_BLANK_N = out_blank;
    assign VGA_SYNC_N = 1'b0;
    // LEDG[2:0] attendance flags, [3] new attendance event, [4] matcher result,
    // [5] camera configured, [6] EEPROM busy (load/save), [7] LOCKED (PRESENT shown), [8] enrolling.
    assign LEDG = {enrol_held, mode == 2'd1, io_busy, cfg_done, result_valid,
                   attendance_event, attendance_flags};
endmodule

`timescale 1ns/1ps
// Behavioural model of a 24LC32-style I2C EEPROM (4096 bytes, 2-byte word address,
// 32-byte write pages, ack polling during the internal write cycle, sequential
// read with address auto-increment). Simulation only.
module eeprom_model #(
    parameter [6:0] DEV = 7'h50,
    parameter integer T_WC_NS = 200000,
    parameter integer PAGE = 32
) (
    inout  wire sda,
    input  wire scl
);
    reg [7:0] mem [0:4095];
    reg       drive_low = 1'b0;
    assign sda = drive_low ? 1'b0 : 1'bz;

    localparam [3:0] IDLE = 0, DEVA = 1, ACKD = 2, AH = 3, ACKH = 4, AL = 5, ACKL = 6,
                     WDATA = 7, ACKW = 8, RDATA = 9, MACK = 10, IGNORE = 11;
    reg [3:0]  st = IDLE;
    reg [3:0]  bc = 0;
    reg [7:0]  sh = 0;
    reg [11:0] ptr = 0;
    reg        rw = 0;
    reg        wrote = 0;
    reg [11:0] page_base = 0;
    realtime   busy_until = 0;
    integer    i;
    reg [7:0]  outb = 0;
    reg        master_acked = 0;
    integer    writes_total = 0;

    initial for (i = 0; i < 4096; i = i + 1) mem[i] = 8'hFF;


    // START: SDA falls while SCL high
    always @(negedge sda) if (scl === 1'b1) begin
        st <= DEVA; bc <= 0; sh <= 0; drive_low <= 1'b0;
    end
    // STOP: SDA rises while SCL high
    always @(posedge sda) if (scl === 1'b1) begin
        if (wrote) begin busy_until = $realtime + T_WC_NS; wrote <= 1'b0; end
        st <= IDLE; drive_low <= 1'b0;
    end

    always @(posedge scl) begin
        case (st)
        DEVA, AH, AL, WDATA: begin
            sh <= {sh[6:0], sda};
            bc <= bc + 1;
        end
        MACK: master_acked <= (sda === 1'b0);
        default: ;
        endcase
    end

    always @(negedge scl) begin
        case (st)
        DEVA: if (bc == 8) begin
            bc <= 0;
            if (sh[7:1] == DEV && !($realtime < busy_until)) begin
                rw <= sh[0]; drive_low <= 1'b1; st <= ACKD;
            end else st <= IGNORE;
        end
        ACKD: begin
            drive_low <= 1'b0;
            if (rw) begin outb <= mem[ptr]; st <= RDATA; bc <= 0; end
            else begin st <= AH; bc <= 0; end
            if (rw) begin drive_low <= ~mem[ptr][7]; bc <= 1; end
        end
        AH: if (bc == 8) begin ptr[11:8] <= sh[3:0]; bc <= 0; drive_low <= 1'b1; st <= ACKH; end
        ACKH: begin drive_low <= 1'b0; st <= AL; bc <= 0; end
        AL: if (bc == 8) begin ptr[7:0] <= sh; page_base <= {ptr[11:8] , 8'd0}; bc <= 0; drive_low <= 1'b1; st <= ACKL; end
        ACKL: begin drive_low <= 1'b0; st <= WDATA; bc <= 0; end
        WDATA: if (bc == 8) begin
            mem[ptr] <= sh; wrote <= 1'b1; writes_total <= writes_total + 1;
            // page wrap
            if ((ptr % PAGE) == PAGE - 1) ptr <= ptr - (PAGE - 1); else ptr <= ptr + 1;
            bc <= 0; drive_low <= 1'b1; st <= ACKW;
        end
        ACKW: begin drive_low <= 1'b0; st <= WDATA; bc <= 0; end
        RDATA: begin
            if (bc == 8) begin
                drive_low <= 1'b0; st <= MACK; bc <= 0;
            end else begin
                drive_low <= ~outb[7 - bc]; bc <= bc + 1;
            end
        end
        MACK: begin
            if (master_acked) begin
                ptr <= ptr + 1; outb <= mem[ptr + 1];
                drive_low <= ~mem[ptr + 1][7]; bc <= 1; st <= RDATA;
            end else begin drive_low <= 1'b0; st <= IGNORE; end
        end
        default: drive_low <= 1'b0;
        endcase
    end
endmodule

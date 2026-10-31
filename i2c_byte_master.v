// Minimal single-master I2C byte engine (no clock stretching).
// SCL is driven push-pull, SDA is open-drain: sda_oe = 1 pulls SDA low, 0 releases it.
// One bit takes 4 ticks; a tick is DIV clocks (DIV=62 at 25 MHz -> about 100 kHz).
//   cmd 1 START (also used as repeated START)   cmd 2 STOP
//   cmd 3 WRITE byte (ack = 1 when the slave pulled SDA low in the 9th bit)
//   cmd 4 READ byte, answer ACK   cmd 5 READ byte, answer NACK (last byte)
module i2c_byte_master #(
    parameter integer DIV = 62
) (
    input  wire       clk,
    input  wire       cmd_valid,
    input  wire [2:0] cmd,
    input  wire [7:0] wdata,
    output reg        busy,
    output reg  [7:0] rdata,
    output reg        ack,
    output reg        scl,
    output reg        sda_oe,
    input  wire       sda_i
);
    reg [15:0] div_cnt;
    reg [2:0]  c;
    reg [1:0]  ph;
    reg [3:0]  bitn;
    reg [7:0]  sh;
    wire tick = (div_cnt == DIV - 1);

    initial begin
        busy = 1'b0; rdata = 8'd0; ack = 1'b0; scl = 1'b1; sda_oe = 1'b0;
        div_cnt = 16'd0; c = 3'd0; ph = 2'd0; bitn = 4'd0; sh = 8'd0;
    end

    always @(posedge clk) begin
        div_cnt <= tick ? 16'd0 : div_cnt + 16'd1;
        if (!busy) begin
            if (cmd_valid) begin
                busy <= 1'b1; c <= cmd; sh <= wdata; ph <= 2'd0; bitn <= 4'd0;
                div_cnt <= 16'd0;
            end
        end else if (tick) begin
            ph <= ph + 2'd1;
            case (c)
            3'd1: case (ph)                                  // START
                2'd0: sda_oe <= 1'b0;
                2'd1: scl <= 1'b1;
                2'd2: sda_oe <= 1'b1;
                default: begin scl <= 1'b0; busy <= 1'b0; end
            endcase
            3'd2: case (ph)                                  // STOP
                2'd0: sda_oe <= 1'b1;
                2'd1: scl <= 1'b1;
                2'd2: sda_oe <= 1'b0;
                default: busy <= 1'b0;
            endcase
            3'd3: case (ph)                                  // WRITE (8 data bits + ack bit)
                2'd0: begin scl <= 1'b0; sda_oe <= (bitn < 4'd8) ? ~sh[7] : 1'b0; end
                2'd1: scl <= 1'b1;
                2'd2: if (bitn == 4'd8) ack <= ~sda_i;
                default: begin
                    scl <= 1'b0; sh <= {sh[6:0], 1'b0}; bitn <= bitn + 4'd1;
                    if (bitn == 4'd8) busy <= 1'b0;
                end
            endcase
            default: case (ph)                               // READ (8 data bits + our ack bit)
                2'd0: begin
                    scl <= 1'b0;
                    sda_oe <= (bitn == 4'd8) ? (c == 3'd4) : 1'b0;
                end
                2'd1: scl <= 1'b1;
                2'd2: if (bitn < 4'd8) sh <= {sh[6:0], sda_i};
                default: begin
                    scl <= 1'b0; bitn <= bitn + 4'd1;
                    if (bitn == 4'd7) rdata <= sh;
                    if (bitn == 4'd8) busy <= 1'b0;
                end
            endcase
            endcase
        end
    end
endmodule

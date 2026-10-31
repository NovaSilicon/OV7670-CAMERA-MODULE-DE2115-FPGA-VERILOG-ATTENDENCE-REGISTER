// Simple dual-port, dual-clock frame buffer: 320x240 pixels x 12 bits (RGB444).
// Write port: camera PCLK domain.  Read port: VGA clock domain (1 clock latency).
// Quartus infers this as M9K block RAM (~0.92 Mbit of the 3.9 Mbit on the EP4CE115).

module frame_buffer (
    input  wire        wclk,
    input  wire        we,
    input  wire [16:0] waddr,
    input  wire [11:0] wdata,

    input  wire        rclk,
    input  wire [16:0] raddr,
    output reg  [11:0] rdata
);

    (* ramstyle = "M9K, no_rw_check" *) reg [11:0] mem [0:76799];

    always @(posedge wclk) begin
        if (we) mem[waddr] <= wdata;
    end

    always @(posedge rclk) begin
        rdata <= mem[raddr];
    end

endmodule

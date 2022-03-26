module track_loader (
	input         clk,
	input         reset,
	input         active,
	output reg [31:0] lba_fdd,
	input  [5:0]  track,
	input         img_mounted,
	input  [63:0] img_size,
	output reg    cpu_wait_fdd,
	input         sd_ack,
	output reg    sd_rd,
	output reg    sd_wr,
	input  [8:0]  sd_buff_addr,
	input         sd_buff_wr,
	input  [7:0]  sd_buff_dout,
	output [7:0]  sd_buff_din,
	input  [13:0] fd_track_addr,
	input         fd_write_disk,
	input  [7:0]  fd_data_do,
	output [7:0]  fd_data_in

);


reg [3:0]  track_sec;

reg         fdd_mounted ;
reg  [63:0] disk_size;



// when we write to the disk, we need to mark it dirty
reg floppy_track_dirty;

always @(posedge clk) begin
        reg       wr_state;
        reg [5:0] cur_track;
        reg       old_ack ;
        reg [1:0] state;
		  

       if (img_mounted) begin
               //disk_mounted <= img_size != 0;
				disk_size <= img_size;
       end

        old_ack <= sd_ack;
        fdd_mounted <= fdd_mounted | img_mounted;

        if (fd_write_disk)
        begin
                floppy_track_dirty<=1;
                // reset timer
        end


        if(reset) begin
                state <= 0;
                cpu_wait_fdd <= 0;
                sd_rd <= 0;
                floppy_track_dirty<=0;
        end

        else case(state)

                2'b00:  // looking for a track change or a timeout

                if((cur_track != track) || (fdd_mounted && ~img_mounted)) begin
                        fdd_mounted <= 0;
                        if(disk_size>0) begin
                                if (floppy_track_dirty)
                                begin
                                        $display("THIS TRACK HAS CHANGES cur_track %x track %x",cur_track,track);
                                        track_sec <= 0;
                                        floppy_track_dirty<=0;
                                        lba_fdd <= 13 * cur_track;
                                        state <= 2'b01;
                                        sd_wr <= 1;
                                        cpu_wait_fdd <= 1;
                                end
                                else
                                        state<=2'b10;
                        end
                end

                2'b01:  // write data
                begin
                        if(~old_ack & sd_ack) begin
                                if(track_sec >= 12) sd_wr <= 0;
                                lba_fdd <= lba_fdd + 1'd1;
                        end else if(old_ack & ~sd_ack) begin
                                track_sec <= track_sec + 1'd1;
                                if(~sd_wr) state <= 2'b10;
                        end
                end

                2'b10:  // start read
                begin
                        cur_track <= track;
                        track_sec <= 0;
                        lba_fdd <= 13 * track;
                        state <= 2'b11;
                        sd_rd <= 1;
                        cpu_wait_fdd <= 1;
                end

                2'b11:  // read data
                begin
                        if(~old_ack & sd_ack) begin
                                if(track_sec >= 12) sd_rd <= 0;
                                lba_fdd <= lba_fdd + 1'd1;
                        end else if(old_ack & ~sd_ack) begin
                                track_sec <= track_sec + 1'd1;
                                if(~sd_rd) state <= 2'b0;
                                cpu_wait_fdd <= 0;
                        end
                end
        endcase
end

`ifdef VERILATOR
bram #(8,14) floppy_dpram_onetrack
(
        .clock_a(clk),
        .address_a({1'b0,track_sec, sd_buff_addr}),
        .wren_a(sd_buff_wr & sd_ack),
        .data_a(sd_buff_dout),
        .q_a(sd_buff_din),

        .clock_b(clk),
        .address_b(fd_track_addr),
        .wren_b(fd_write_disk), 
        .data_b(fd_data_do),
        .q_b(fd_data_in)
);

`else

dpram #(14,8) floppy_dpram
(
	.clock_a(clk),
	.address_a({1'b0,track_sec, sd_buff_addr}),
	.wren_a(sd_buff_wr & sd_ack),
	.data_a(sd_buff_dout),
	.q_a(sd_buff_din),

	.clock_b(clk),
	.address_b(fd_track_addr),
	.wren_b(fd_write_disk & active),
	.data_b(fd_data_do),
	.q_b(fd_data_in)

);
`endif


endmodule

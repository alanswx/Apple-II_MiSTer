//-----------------------------------------------------------------------------
//
// Disk II emulator
//
// This is read-only and only feeds "pre-nibblized" data to the processor
// It has a single-track buffer and only supports one drive (1).
//
// Stephen A. Edwards, sedwards@cs.columbia.edu
//
//-----------------------------------------------------------------------------
//
// Each track is represented as 0x1A00 bytes
// Each disk image consists of 35 * 0x1A00 bytes = 0x38A00 (227.5 K)
//
// X = $60 for slot 6
//
//  Off          On
// C080,X      C081,X		Phase 0  Head Stepper Motor Control
// C082,X      C083,X		Phase 1
// C084,X      C085,X		Phase 2
// C086,X      C087,X		Phase 3
// C088,X      C089,X           Motor On
// C08A,X      C08B,X           Select Drive 2 (select drive 1 when off)
// C08C,X      C08D,X           Q6  (Shift/load?)
// C08E,X      C08F,X           Q7  (Write request to drive)
//
//
// Q7 Q6
// 0  0  Read
// 0  1  Sense write protect
// 1  0  Write
// 1  1  Load Write Latch
//
// Reading a byte:
//        LDA $C08E,X  set read mode
// ...
// READ   LDA $C08C,X
//        BPL READ
//
// Sense write protect:
//   LDA $C08D,X
//   LDA $C08E,X
//   BMI PROTECTED
//
// Writing
//   STA $C08F,X   set write mode
//   ..
//   LDA DATA
//   STA $C08D,X   load byte to write
//   STA $C08C,X   write byte to disk
//
// Data bytes must be written in 32 cycle loops.
//
// There are 70 phases for the head stepper and and 35 tracks,
// i.e., two phase changes per track.
//
// The disk spins at 300 rpm; one new bit arrives every 4 us
// The processor's clock is 1 MHz = 1 us, so it takes 8 * 4 = 32 cycles
// for a new byte to arrive
//
// This corresponds to dividing the 2 MHz signal by 64 to get the byte clock
//
//-----------------------------------------------------------------------------

module disk_ii(
    CLK_14M,
    CLK_2M,
    PHASE_ZERO,
    IO_SELECT,
    DEVICE_SELECT,
    RESET,
    A,
    D_IN,
    D_OUT,
    TRACK1,
    TRACK2,
    track_addr,
    D1_ACTIVE,
    D2_ACTIVE,
    ram_write_addr,
    ram_di,
    ram_we,
    DISK_FD_WRITE_DISK,
    DISK_FD_READ_DISK,
    DISK_FD_TRACK_ADDR,
    DISK_FD_DATA_IN,
    DISK_FD_DATA_OUT
);
    input         CLK_14M;
    input         CLK_2M;
    input         PHASE_ZERO;
    input         IO_SELECT;		// e.g., C600 - C6FF ROM
    input         DEVICE_SELECT;		// e.g., C0E0 - C0EF I/O locations
    input         RESET;
    input [15:0]  A;
    input [7:0]   D_IN;		// From 6502
    output [7:0]  D_OUT;		// To 6502
    output [5:0]  TRACK1;		// Current track (0-34)
    output [5:0]  TRACK2;		// Current track (0-34)
    output [13:0] track_addr;
    output        D1_ACTIVE;		// Disk 1 motor on
    output        D2_ACTIVE;		// Disk 2 motor on
    input [12:0]  ram_write_addr;		// Address for track RAM
    input [7:0]   ram_di;		// Data to track RAM
    input         ram_we;		// RAM write enable
    
    output        DISK_FD_WRITE_DISK;
    output        DISK_FD_READ_DISK;
    output [13:0] DISK_FD_TRACK_ADDR;		// Address for track RAM
    input [7:0]   DISK_FD_DATA_IN;
    output [7:0]  DISK_FD_DATA_OUT;
    
    
    reg [3:0]     motor_phase1;
    reg [3:0]     motor_phase2;
    reg           drive_on;
    reg           drive2_select;
    reg           q6;
    reg           q7;
    reg           PHASE_ZERO_D;
    reg           CLK_2M_D;
    reg           write_disk_out;
    reg [13:0]    write_disk_addr;
    reg [7:0]     floppy_write_data_out;
    reg [7:0]     floppy_write_data;
    wire [7:0]    rom_dout;
    
    // Current phase of the head.  This is in half-steps to assign
    // a unique position to the case, say, when both phase 0 and phase 1 are
    // on simultaneously.  phase(7 downto 2) is the track number
    reg [7:0]     phase1;		// 0 - 139
    reg [7:0]     phase2;		// 0 - 139
    
    // Storage for one track worth of data in "nibblized" form
    // Double-ported RAM for holding a track
    wire [7:0]    track_memory[0:6655];
    wire [7:0]    ram_do;
    
    // Lower bit indicates whether disk data is "valid" or not
    // RAM address is track_byte_addr(14 downto 1)
    // This makes it look to the software like new data is constantly
    // being read into the shift register, which indicates the data is
    // not yet ready.
    reg [14:0]    track_byte_addr_1;
    reg [14:0]    track_byte_addr_2;
    wire [14:0]    track_byte_addr = D1_ACTIVE ? track_byte_addr_1 : track_byte_addr_2;
    wire          read_disk;		// When C08C accessed
    wire          write_disk;
    reg           select_d;
    
    function integer NEXT_PHASE;
        input [3:0]   motor_phase;
        input [7:0]   phase;
        integer       phase_change;
        integer       new_phase;
        reg [3:0]     rel_phase;
    begin
        phase_change = 0;
        new_phase = phase;
        rel_phase = motor_phase;
        case (phase[2:1])
            2'b00 :
                rel_phase = {rel_phase[1:0], rel_phase[3:2]};
            2'b01 :
                rel_phase = {rel_phase[2:0], rel_phase[3]};
            2'b10 :
                ;
            2'b11 :
                rel_phase = {rel_phase[0], rel_phase[3:1]};
            default :
                ;
        endcase
        
        if (phase[0] == 1'b1)		// Phase is odd
            case (rel_phase)
                4'b0000 :
                    phase_change = 0;
                4'b0001 :
                    phase_change = -3;
                4'b0010 :
                    phase_change = -1;
                4'b0011 :
                    phase_change = -2;
                4'b0100 :
                    phase_change = 1;
                4'b0101 :
                    phase_change = -1;
                4'b0110 :
                    phase_change = 0;
                4'b0111 :
                    phase_change = -1;
                4'b1000 :
                    phase_change = 3;
                4'b1001 :
                    phase_change = 0;
                4'b1010 :
                    phase_change = 1;
                4'b1011 :
                    phase_change = -3;
                4'b1111 :
                    phase_change = 0;
                default :
                    ;
            endcase
        else
            // Phase is even
            case (rel_phase)
                4'b0000 :
                    phase_change = 0;
                4'b0001 :
                    phase_change = -2;
                4'b0010 :
                    phase_change = 0;
                4'b0011 :
                    phase_change = -1;
                4'b0100 :
                    phase_change = 2;
                4'b0101 :
                    phase_change = 0;
                4'b0110 :
                    phase_change = 1;
                4'b0111 :
                    phase_change = 0;
                4'b1000 :
                    phase_change = 0;
                4'b1001 :
                    phase_change = 1;
                4'b1010 :
                    phase_change = 2;
                4'b1011 :
                    phase_change = -2;
                4'b1111 :
                    phase_change = 0;
                default :
                    ;
            endcase
        
        if (new_phase + phase_change <= 0)
            new_phase = 0;
        else if (new_phase + phase_change > 139)
            new_phase = 139;
        else
            new_phase = new_phase + phase_change;
        NEXT_PHASE = new_phase;
    end
    endfunction
    
    
    always @(posedge CLK_14M)
    begin: interpret_io
        
        begin
            if (RESET == 1'b1)
            begin
                motor_phase1 <= 4'b0;
                motor_phase2 <= 4'b0;
                drive_on <= 1'b0;
                drive2_select <= 1'b0;
                q6 <= 1'b0;
                q7 <= 1'b0;
                floppy_write_data <= 8'b00000000;
            end
            else
            begin
                select_d <= DEVICE_SELECT;
                if (DEVICE_SELECT == 1'b1)
                begin
                    if (A[3] == 1'b0)		// C080 - C087
                    begin
                        if (drive2_select == 1'b0)
                            motor_phase1[A[2:1]] <= A[0];
                        else
                            motor_phase2[A[2:1]] <= A[0];
                    end
                    else
                        case (A[2:1])
                            2'b00 :		// C088 - C089
                                drive_on <= A[0];
                            2'b01 :		// C08A - C08B
                                drive2_select <= A[0];
                            2'b10 :		// C08C - C08D
                                begin
                                    q6 <= A[0];
                                    if (A[0] == 1'b1 & select_d == 1'b0)
                                        floppy_write_data <= D_IN;
                                end
                            2'b11 :		// C08E - C08F
                                q7 <= A[0];
                            default :
                                ;
                        endcase
                end
            end
        end
    end
    
    //assign D1_ACTIVE = drive_on & (~drive2_select);
    //assign D2_ACTIVE = drive_on & drive2_select;
    assign D1_ACTIVE = (~drive2_select);
    assign D2_ACTIVE =  drive2_select;
    
    // There are two cases:
    //
    //  Current phase is odd (between two poles)
    //        |
    //        V
    // -3-2-1 0 1 2 3 
    //  X   X   X   X
    //  0   1   2   3
    //
    //
    //  Current phase is even (under a pole)
    //          |
    //          V
    // -4-3-2-1 0 1 2 3 4
    //  X   X   X   X   X
    //  0   1   2   3   0
    //
    
    always @(posedge CLK_14M)
    begin
	    //if (read_disk) $display("drive_on %x drive_2_select %x D1_ACTIVE %x TRACK1 %x D2_ACTIVE %x TRACK2 %x",drive_on,drive2_select,D1_ACTIVE,TRACK1,D2_ACTIVE,TRACK2);
    end
    
    always @(posedge CLK_14M)
    begin: update_phase
        begin
            if (RESET == 1'b1)
            begin
                phase1 <= 70;		// Deliberately odd to test reset
                phase2 <= 70;		// Deliberately odd to test reset
            end
            else
            begin
                phase1 <= (NEXT_PHASE(motor_phase1, phase1));
                phase2 <= (NEXT_PHASE(motor_phase2, phase2));
            end
        end
    end
    
    assign TRACK1 = phase1[7:2];
    assign TRACK2 = phase2[7:2];
    
    // Dual-ported RAM holding the contents of the track
    //track_storage : process (CLK_14M)
    //begin
    //  if rising_edge(CLK_14M) then
    //    if ram_we = '1' then
    //      track_memory(to_integer(ram_write_addr)) <= ram_di;
    //    end if;
    //    ram_do <= track_memory(to_integer(track_byte_addr(14 downto 1)));
    //  end if;
    //end process;
    
    
    always @(negedge PHASE_ZERO)
    begin: write_logic
        
        begin
            write_disk_out <= 1'b0;
            if (write_disk == 1'b1)
            begin
                floppy_write_data_out <= floppy_write_data;
                write_disk_out <= 1'b1;
                write_disk_addr <= track_byte_addr[14:1];
		$display("%x TRACK (%x) WRITE track addr %x data %x",D2_ACTIVE,D1_ACTIVE?TRACK1:TRACK2,track_byte_addr[14:1],floppy_write_data);
            end
	    else if (read_disk == 1'b1)
	    begin
		$display("%x TRACK (%x) READ track addr %x data %x",D2_ACTIVE,D1_ACTIVE?TRACK1:TRACK2,track_byte_addr[14:1],DISK_FD_DATA_IN);
	    end
        end
    end
    
    // Go to the next byte when the disk is accessed or if the counter times out
    
    always @(posedge CLK_14M or posedge RESET)
    begin: read_head
        reg [5:0]     byte_delay_1;		// Accounts for disk spin rate
        reg [5:0]     byte_delay_2;		// Accounts for disk spin rate
        if (RESET == 1'b1)
        begin
            track_byte_addr_1 <= 15'b0;
            track_byte_addr_2 <= 15'b0;
            byte_delay_1 <= 6'b0;
            byte_delay_2 <= 6'b0;
        end
        else 
        begin
	       CLK_2M_D <= CLK_2M;
      	if (CLK_2M == 1'b1 & CLK_2M_D == 1'b0)
	begin
		if (D1_ACTIVE)
        		byte_delay_1 <= byte_delay_1 - 1'b1;
		else
        		byte_delay_2 <= byte_delay_2 - 1'b1;
	end

            PHASE_ZERO_D <= PHASE_ZERO;
            if (PHASE_ZERO == 1'b1 & PHASE_ZERO_D == 1'b0)
            begin
		if (D1_ACTIVE) 
		begin
                	if (((read_disk == 1'b1 | write_disk == 1'b1) & PHASE_ZERO == 1'b1) | byte_delay_1 == 0)
                //if (((read_disk == 1'b1 | write_disk == 1'b1) & PHASE_ZERO == 1'b1) )
                	begin
                    		byte_delay_1 <= 6'b0;
                    		if (track_byte_addr_1 == 16'h33FE)
                        		track_byte_addr_1 <= 15'b0;
                    		else
                        		track_byte_addr_1 <= track_byte_addr_1 + 2;
		    	end
		end
		else begin
                	if (((read_disk == 1'b1 | write_disk == 1'b1) & PHASE_ZERO == 1'b1) | byte_delay_2 == 0)
                	begin
                    		byte_delay_2 <= 6'b0;
                    		if (track_byte_addr_2 == 16'h33FE)
                        		track_byte_addr_2 <= 15'b0;
                    		else
                        		track_byte_addr_2 <= track_byte_addr_2 + 2;
		    	end
		end
            end
        end
    end
    
    assign DISK_FD_WRITE_DISK = write_disk_out;
    assign DISK_FD_READ_DISK = read_disk;
    assign DISK_FD_TRACK_ADDR = (write_disk_out == 1'b1) ? write_disk_addr : 
                                track_byte_addr[14:1];
    assign ram_do = DISK_FD_DATA_IN;
    assign DISK_FD_DATA_OUT = floppy_write_data_out;
    
    
   rom #(8,8,"rtl/roms/diskii.hex") diskrom (
           .clock(CLK_14M),
           .ce(1'b1),
           .a(A[7:0]),
           .data_out(rom_dout)
   );
 
    assign read_disk = (DEVICE_SELECT == 1'b1 & A[3:0] == 4'hC & q7 == 1'b0) ? 1'b1 : 		// C08C
                       1'b0;
    assign write_disk = (DEVICE_SELECT == 1'b1 & A[3:0] == 4'hC & q7 == 1'b1) ? 1'b1 : 		// C08C
                        1'b0;
    
    assign D_OUT = (IO_SELECT == 1'b1) ? rom_dout : 
                   (read_disk == 1'b1 & track_byte_addr[0] == 1'b0) ? ram_do : 
                   (write_disk == 1'b1 & track_byte_addr[0] == 1'b0) ? floppy_write_data : 
                   8'b0;
    
    assign track_addr = track_byte_addr[14:1];
    
endmodule

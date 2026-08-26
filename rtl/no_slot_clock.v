//
// No-Slot Clock (DS1216E) for the MiSTer Apple II core
//
// Copyright (c) 2026 Alan Steremberg
//
// Derived from the no-slot clock in Henri Asseily's Appletini One
// (hdl/apple/no_slot_clock.sv), used with the author's permission.
// The bus-facing protocol, the $Cn00 slot-ROM snoop and the choice to gate the
// $C800 window on slot ownership all come from that implementation; the BCD
// timekeeping here is carried over from this core's previous clock_card.v.
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// The DS1216E was a socket that sat underneath an existing ROM. It watches
// accesses to that ROM and stays completely invisible until it sees a 64-bit
// unlock pattern, so it costs no slot and no address space. Every stock
// driver works with it: NS.CLOCK.SYSTEM, the ProDOS 8 NSC driver, AppleWorks,
// Total Replay's clock detection.
//
// Protocol, as seen from the Apple bus. Only address lines matter - the data
// bus is not used to send a bit to the clock:
//
//   A2 = 0  input  cycle: A0 supplies one bit, LSB first
//   A2 = 1  read   cycle: the clock drives one bit on D0, LSB first
//   A2 = 1  write  cycle: aborts and re-arms the pattern matcher
//
// Sixty-four consecutive input bits matching 0x5CA33AC55CA33AC5 unlock the
// clock. The next 64 cycles then either read the time out or write a new time
// in. Any mismatched bit re-arms the matcher, so ordinary ROM reads - which
// walk addresses in no particular pattern - never accidentally unlock it.
//
// Register order, LSB first, matching the DS1216E:
//
//   [ 7: 0] hundredths of a second
//   [15: 8] seconds
//   [23:16] minutes
//   [31:24] hours          (24-hour mode; bit 7 clear)
//   [39:32] day of week    1-7
//   [47:40] date           1-31
//   [55:48] month          1-12
//   [63:56] year           00-99
//
// All fields are BCD.
//
// The MiSTer HPS supplies the wall clock on RTC[64:0] and toggles RTC[64]
// when it changes. Between those updates this module runs its own counter so
// the time actually advances, the same way rtl/clock_card.v does.
//
// This replaces clock_card.v, which was a bespoke ProDOS clock needing its
// own slot and its own ROM.
//

module no_slot_clock #(
	// clk frequency, used to derive the 100 Hz tick
	parameter CLK_FREQ = 14318181
) (
	input             clk,
	input             reset,

	// Feature enable. When low the clock is inert and never drives the bus.
	input             enable,

	// High when this cycle is touching the ROM the clock hides under.
	// Computed by the caller so the hiding place can be chosen freely.
	input             cs,

	input      [15:0] addr,
	input             rw,        // 1 = read, 0 = write

	// One pulse per Apple bus cycle (a PHASE_ZERO rising edge). The whole
	// protocol advances on this; see the note on data_en below.
	input             cycle_en,

	// MiSTer HPS wall clock, BCD. Bit 64 toggles on every update.
	input      [64:0] RTC,

	// Drive the data bus this cycle. This is a *level*, held for the whole bus
	// cycle, because PD in apple2_top.vhd is a combinational mux and the CPU
	// does not latch it until a clock after PHI0 falls (apple2.vhd:502). A
	// one-clk pulse at cycle_en would be long gone by then.
	output            data_en,
	output reg  [7:0] data_out
);

localparam [63:0] ACCESS_PATTERN = 64'h5CA3_3AC5_5CA3_3AC5;

localparam [1:0] ST_IDLE     = 2'd0;  // mismatched; wait for a re-arm
localparam [1:0] ST_MATCH    = 2'd1;  // comparing against the unlock pattern
localparam [1:0] ST_TRANSFER = 2'd2;  // unlocked; 64 bits in or out

// ---------------------------------------------------------------------------
// Timekeeping
// ---------------------------------------------------------------------------

reg [63:0] time_bcd;
reg        rtc_flag;

// 100 Hz, to drive the hundredths register the DS1216E exposes.
localparam [31:0] TICK_MAX32 = (CLK_FREQ / 100) - 1;
localparam [23:0] TICK_MAX   = TICK_MAX32[23:0];
reg  [23:0] tick_count;
wire        tick = (tick_count == TICK_MAX);

// BCD increment of one packed byte.
function [7:0] bcd_inc;
	input [7:0] v;
	begin
		bcd_inc = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0}
		                           : {v[7:4], v[3:0] + 4'd1};
	end
endfunction

wire [7:0] hsec  = time_bcd[7:0];
wire [7:0] sec   = time_bcd[15:8];
wire [7:0] min   = time_bcd[23:16];
wire [7:0] hour  = time_bcd[31:24];
wire [7:0] wday  = time_bcd[39:32];
wire [7:0] date  = time_bcd[47:40];
wire [7:0] month = time_bcd[55:48];
wire [7:0] year  = time_bcd[63:56];

// Roll-over points. The date always rolls at 31 rather than tracking month
// length - the HPS refreshes the whole time regularly, so a wrong date can
// only persist until the next update, and getting it exactly right here would
// cost a month-length table for no practical gain.
wire hsec_carry  = (hsec  == 8'h99);
wire sec_carry   = (sec   == 8'h59);
wire min_carry   = (min   == 8'h59);
wire hour_carry  = (hour  == 8'h23);
wire date_carry  = (date  == 8'h31);
wire month_carry = (month == 8'h12);
wire wday_carry  = (wday  == 8'h07);

// Written back by the Apple. Exposed so a caller can push it to the HPS;
// unconnected is fine, in which case the write just updates the local clock.
reg [63:0] write_time_bcd;
reg        write_time_strobe;

// ---------------------------------------------------------------------------
// Access decode
// ---------------------------------------------------------------------------

// The CPU core holds its address bus during internal cycles - R65Cx2.vhd's
// calcAddr ends with `when others => null` (:1494), so myAddr keeps its value
// on any cycle that does not compute a new address. One logical CPU access
// therefore leaves cs asserted across several consecutive cycle_en pulses.
// Counting each as a protocol event shifts the same bit repeatedly and the
// unlock can never align, so take one event per contiguous run of cs.
reg  cs_prev;
wire cs_edge = cs && !cs_prev;

wire rom_cycle    = enable && cs_edge && cycle_en;
wire output_read  = rom_cycle &&  addr[2] &&  rw;   // clock drives a bit
wire input_cycle  = rom_cycle && !addr[2];          // A0 supplies a bit
wire reset_cycle  = rom_cycle &&  addr[2] && !rw;   // re-arm

reg [1:0]  state;
reg [5:0]  bit_count;
reg [63:0] pattern;
reg [63:0] shift;        // time being shifted out
reg [63:0] write_shift;  // time being shifted in

// Only ever drives D0; the other seven bits read back as zero, as on the part.
//
// drive_bit is decided at cycle_en, from the state *before* that cycle's shift,
// and then held for the rest of the bus cycle. Deciding it combinationally from
// `state` instead would drop the 64th bit, because the state machine has already
// returned to ST_MATCH by the time the CPU latches it.
reg drive_bit;
assign data_en = enable && drive_bit;

always @(posedge clk) begin
	if (reset) begin
		state             <= ST_MATCH;
		bit_count         <= 6'd0;
		pattern           <= ACCESS_PATTERN;
		shift             <= 64'd0;
		write_shift       <= 64'd0;
		write_time_bcd    <= 64'd0;
		write_time_strobe <= 1'b0;
		data_out          <= 8'h00;
		drive_bit         <= 1'b0;
		cs_prev           <= 1'b0;
		tick_count        <= 24'd0;
		rtc_flag          <= 1'b0;
		time_bcd          <= 64'd0;
	end else begin
		write_time_strobe <= 1'b0;

		// One decision per CPU access: made on the cs edge, then held for as long
		// as the CPU keeps the address on the bus, so the byte is still being
		// driven when the CPU latches it.
		if (cycle_en) begin
			cs_prev <= cs;
			if (cs_edge) begin
				drive_bit <= enable && addr[2] && rw && (state == ST_TRANSFER);
				if (enable && addr[2] && rw && (state == ST_TRANSFER))
					data_out <= {7'h00, shift[0]};
			end else if (!cs) begin
				drive_bit <= 1'b0;
			end
		end

		// --- wall clock ---------------------------------------------------
		rtc_flag <= RTC[64];
		if (rtc_flag != RTC[64]) begin
			// HPS pushed a new time. RTC is
			// {wday[55:48], year[47:40], month[39:32], date[31:24],
			//  hour[23:16], min[15:8], sec[7:0]}, all BCD.
			time_bcd   <= {RTC[47:40],   // year
			               RTC[39:32],   // month
			               RTC[31:24],   // date
			               RTC[55:48],   // day of week
			               RTC[23:16],   // hours
			               RTC[15:8],    // minutes
			               RTC[7:0],     // seconds
			               8'h00};       // hundredths
			tick_count <= 24'd0;
		end else begin
			tick_count <= tick ? 24'd0 : tick_count + 24'd1;
			if (tick) begin
				time_bcd[7:0] <= hsec_carry ? 8'h00 : bcd_inc(hsec);
				if (hsec_carry) begin
					time_bcd[15:8] <= sec_carry ? 8'h00 : bcd_inc(sec);
					if (sec_carry) begin
						time_bcd[23:16] <= min_carry ? 8'h00 : bcd_inc(min);
						if (min_carry) begin
							time_bcd[31:24] <= hour_carry ? 8'h00 : bcd_inc(hour);
							if (hour_carry) begin
								time_bcd[39:32] <= wday_carry ? 8'h01 : bcd_inc(wday);
								time_bcd[47:40] <= date_carry ? 8'h01 : bcd_inc(date);
								if (date_carry) begin
									time_bcd[55:48] <= month_carry ? 8'h01 : bcd_inc(month);
									if (month_carry)
										time_bcd[63:56] <= (year == 8'h99) ? 8'h00 : bcd_inc(year);
								end
							end
						end
					end
				end
			end
		end

		// --- protocol -----------------------------------------------------
		if (!enable) begin
			drive_bit   <= 1'b0;
			state       <= ST_MATCH;
			bit_count   <= 6'd0;
			pattern     <= ACCESS_PATTERN;
			shift       <= 64'd0;
			write_shift <= 64'd0;
		end else if (output_read) begin
			if (state == ST_TRANSFER) begin
				shift <= {1'b0, shift[63:1]};
				if (bit_count == 6'd63) begin
					state       <= ST_MATCH;
					bit_count   <= 6'd0;
					pattern     <= ACCESS_PATTERN;
					write_shift <= 64'd0;
				end else begin
					bit_count <= bit_count + 6'd1;
				end
			end else begin
				// A read with A2 high outside a transfer just re-arms.
				state       <= ST_MATCH;
				bit_count   <= 6'd0;
				pattern     <= ACCESS_PATTERN;
				write_shift <= 64'd0;
			end
		end else if (input_cycle) begin
			if (state == ST_MATCH) begin
				if (addr[0] == pattern[0]) begin
					if (bit_count == 6'd63) begin
						// Unlocked. Snapshot the time so it cannot change
						// underneath a transfer that takes 64 bus cycles.
						state       <= ST_TRANSFER;
						bit_count   <= 6'd0;
						pattern     <= ACCESS_PATTERN;
						shift       <= time_bcd;
						write_shift <= 64'd0;
					end else begin
						bit_count <= bit_count + 6'd1;
						pattern   <= {1'b0, pattern[63:1]};
					end
				end else begin
					// Wrong bit: go quiet until something re-arms us.
					state       <= ST_IDLE;
					bit_count   <= 6'd0;
					pattern     <= ACCESS_PATTERN;
					write_shift <= 64'd0;
				end
			end else if (state == ST_TRANSFER) begin
				if (bit_count == 6'd63) begin
					write_time_bcd    <= {addr[0], write_shift[62:0]};
					write_time_strobe <= 1'b1;
					time_bcd          <= {addr[0], write_shift[62:0]};
					state             <= ST_MATCH;
					bit_count         <= 6'd0;
					pattern           <= ACCESS_PATTERN;
					write_shift       <= 64'd0;
				end else begin
					write_shift[bit_count] <= addr[0];
					bit_count <= bit_count + 6'd1;
				end
			end
		end else if (reset_cycle) begin
			state       <= ST_MATCH;
			bit_count   <= 6'd0;
			pattern     <= ACCESS_PATTERN;
			write_shift <= 64'd0;
		end
	end
end

endmodule

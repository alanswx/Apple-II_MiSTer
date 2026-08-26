`timescale 1ns / 1ps
//
// Unit test for no_slot_clock.v
//
// Copyright (c) 2026 Alan Steremberg
// Licensed under the GNU General Public License v3 or later.
//
//   iverilog -g2005 -o /tmp/tb_nsc rtl/tb_no_slot_clock.v rtl/no_slot_clock.v
//   /tmp/tb_nsc
//
// Covers: the unlock pattern, reading the time back, writing a new time,
// rejection of a wrong pattern, that ordinary ROM reads never unlock it,
// and that the clock keeps time on its own between HPS updates.
//

module tb_no_slot_clock;

	localparam integer CLK_FREQ = 1000000;   // 1 MHz keeps the 100 Hz tick cheap
	localparam [63:0] PATTERN = 64'h5CA3_3AC5_5CA3_3AC5;

	reg         clk = 0;
	reg         reset = 1;
	reg         enable = 1;
	reg         cs = 0;
	reg  [15:0] addr = 16'hC300;
	reg         rw = 1;
	reg         cycle_en = 0;
	reg  [64:0] RTC = 65'd0;
	wire        data_en;
	wire [7:0]  data_out;

	// clk_sys ticks in one Apple bus cycle. The real core gives 14 for a normal
	// cycle (16 for the one stretched cycle per line); the exact number does not
	// matter here, only that it is longer than the cycle_en pulse.
	localparam integer CYCLE_CLKS = 14;

	// Bus cycles the CPU keeps one address asserted. R65Cx2.vhd's calcAddr has
	// `when others => null`, so the address bus holds during internal cycles;
	// measured at 5 on hardware for Applesoft's LDA (zp),Y. The clock must
	// still register exactly one protocol event per access.
	localparam integer HOLD = 5;

	integer errors = 0;
	reg        last_data_en;
	reg  [7:0] last_data_out;

	no_slot_clock #(.CLK_FREQ(CLK_FREQ)) dut (
		.clk(clk), .reset(reset), .enable(enable), .cs(cs),
		.addr(addr), .rw(rw), .cycle_en(cycle_en), .RTC(RTC),
		.data_en(data_en), .data_out(data_out)
	);

	always #5 clk = ~clk;   // 100 MHz sim clock; timing is driven by cycle_en

	// One Apple bus cycle, modelled the way the core actually drives it: the
	// address and chip select are held for the whole cycle, cycle_en is a single
	// clk pulse at the *start* (PHASE_ZERO_R), and the CPU does not latch the
	// data bus until a clock after PHI0 falls (apple2.vhd:502) - near the end.
	//
	// Sampling late is the point. A data_en that is only valid during the
	// cycle_en pulse looks fine to a one-clock testbench and returns nothing at
	// all on hardware.
	// One clk_sys-length bus cycle with whatever cs/addr the caller set.
	task raw_cycle(input [15:0] a, input r, input sel, input sample);
		integer k;
	begin
		@(negedge clk);
		addr = a; rw = r; cs = sel; cycle_en = 1;
		@(negedge clk);
		cycle_en = 0;
		for (k = 0; k < CYCLE_CLKS - 3; k = k + 1) @(negedge clk);
		if (sample) begin
			// CPU latch point.
			last_data_en  = data_en;
			last_data_out = data_out;
		end
		@(negedge clk);
	end
	endtask

	task bus_cycle(input [15:0] a, input r);
		integer k;
	begin
		// The access itself, then the held-address tail.
		raw_cycle(a, r, 1'b1, 1'b1);
		for (k = 0; k < HOLD - 1; k = k + 1) raw_cycle(a, r, 1'b1, 1'b0);
		cs = 0;

		// One idle bus cycle with cs low. On hardware the next instruction's
		// opcode fetch always separates two peripheral accesses, and the clock
		// counts one protocol event per contiguous run of cs - so cs must be
		// seen low at a cycle_en for the next access to register as new.
		@(negedge clk); addr = 16'h0300; cycle_en = 1;
		@(negedge clk); cycle_en = 0;
		for (k = 0; k < CYCLE_CLKS - 3; k = k + 1) @(negedge clk);
	end
	endtask

	// Present one pattern/data bit: A2 low, bit on A0.
	task send_bit(input b);
		bus_cycle({12'hC30, 1'b0, 2'b00, b}, 1'b1);
	endtask

	// Clock a bit out: A2 high, read. Value appears on D0.
	task read_bit(output b);
	begin
		bus_cycle(16'hC304, 1'b1);
		b = last_data_out[0];
	end
	endtask

	task unlock;
		integer i;
	begin
		for (i = 0; i < 64; i = i + 1) send_bit(PATTERN[i]);
	end
	endtask

	task read_time(output [63:0] t);
		integer i;
		reg b;
	begin
		for (i = 0; i < 64; i = i + 1) begin
			read_bit(b);
			t[i] = b;
			if (!last_data_en) begin
				$display("  FAIL: data_en low on transfer read bit %0d", i);
				errors = errors + 1;
			end
		end
	end
	endtask

	task write_time(input [63:0] t);
		integer i;
	begin
		for (i = 0; i < 64; i = i + 1) send_bit(t[i]);
	end
	endtask

	// The hundredths field advances on its own while a test runs, so compare
	// every field above it rather than demanding an exact 64-bit match.
	localparam [63:0] NO_HSEC = 64'hFFFF_FFFF_FFFF_FF00;

	task check64(input [127:0] name, input [63:0] got, input [63:0] want);
	begin
		if (got !== want) begin
			$display("  FAIL: %0s got %016h want %016h", name, got, want);
			errors = errors + 1;
		end else begin
			$display("  ok:   %0s = %016h", name, got);
		end
	end
	endtask

	reg [63:0] t;
	reg [63:0] expect_time;
	reg        b;
	integer    i;

	initial begin
		repeat (4) @(negedge clk);
		reset = 0;
		repeat (4) @(negedge clk);

		// RTC: 2026-08-24 (Monday), 21:47:33
		// layout {wday[55:48], year[47:40], month[39:32], date[31:24],
		//         hour[23:16], min[15:8], sec[7:0]}
		RTC = {1'b0, 8'h00, 8'h01, 8'h26, 8'h08, 8'h24, 8'h21, 8'h47, 8'h33};
		@(negedge clk); RTC[64] = 1'b1;   // toggle = new time
		repeat (4) @(negedge clk);

		// DS1216E order: {year, month, date, wday, hour, min, sec, hsec}
		expect_time = {8'h26, 8'h08, 8'h24, 8'h01, 8'h21, 8'h47, 8'h33, 8'h00};

		$display("1. unlock then read the time back");
		unlock;
		read_time(t);
		check64("time", t & NO_HSEC, expect_time & NO_HSEC);

		$display("2. a wrong pattern must not unlock");
		for (i = 0; i < 63; i = i + 1) send_bit(PATTERN[i]);
		send_bit(~PATTERN[63]);
		read_bit(b);
		if (last_data_en) begin
			$display("  FAIL: clock drove the bus after a bad pattern");
			errors = errors + 1;
		end else $display("  ok:   stayed silent");

		$display("3. ordinary ROM reads must not unlock it");
		// Walk a stretch of ROM the way real code fetching bytes would.
		for (i = 0; i < 300; i = i + 1)
			bus_cycle(16'hC300 + i[15:0], 1'b1);
		read_bit(b);
		if (last_data_en) begin
			$display("  FAIL: clock unlocked from plain ROM reads");
			errors = errors + 1;
		end else $display("  ok:   stayed silent");

		$display("4. unlock still works afterwards");
		unlock;
		read_time(t);
		check64("time", t & NO_HSEC, expect_time & NO_HSEC);

		$display("5. write a new time, then read it back");
		unlock;
		write_time({8'h99, 8'h12, 8'h31, 8'h07, 8'h23, 8'h59, 8'h58, 8'h00});
		unlock;
		read_time(t);
		check64("written", t & NO_HSEC,
		        {8'h99, 8'h12, 8'h31, 8'h07, 8'h23, 8'h59, 8'h58, 8'h00} & NO_HSEC);

		$display("6. the clock keeps time on its own");
		// 100 Hz tick at CLK_FREQ -> one second is CLK_FREQ clocks.
		repeat (CLK_FREQ + 1000) @(posedge clk);
		unlock;
		read_time(t);
		// 23:59:58 + ~1s -> 23:59:59, seconds field is bits [15:8]
		if (t[15:8] !== 8'h59) begin
			$display("  FAIL: seconds %02h, expected 59 after one second", t[15:8]);
			errors = errors + 1;
		end else $display("  ok:   advanced to %02h:%02h:%02h",
		                  t[31:24], t[23:16], t[15:8]);

		$display("7. disabled clock never drives the bus");
		enable = 0;
		unlock;
		read_bit(b);
		if (last_data_en) begin
			$display("  FAIL: drove the bus while disabled");
			errors = errors + 1;
		end else $display("  ok:   silent while disabled");
		enable = 1;

		$display("");
		if (errors == 0) $display("PASS - all no_slot_clock checks ok");
		else             $display("FAIL - %0d error(s)", errors);
		$finish;
	end

	initial begin
		#50_000_000;
		$display("FAIL - timeout");
		$finish;
	end

endmodule

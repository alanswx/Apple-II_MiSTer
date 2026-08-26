`timescale 1ns / 1ps
//
// Unit test for speaker_filter.v
//
// Copyright (c) 2026 Alan Steremberg
// Licensed under the GNU General Public License v3 or later.
//
//   iverilog -g2005 -o /tmp/tb_spk rtl/tb_speaker_filter.v rtl/speaker_filter.v
//   /tmp/tb_spk
//
// Covers DC gain at both rails, the running sum's invariant, and the reason the
// filter exists: what a 48 kHz sampler sees when the speaker is driven fast.
//

module tb_speaker_filter;

	localparam integer TAPS      = 256;
	localparam integer CLK_HZ    = 14318181;   // clk_sys
	localparam integer SAMPLE_HZ = 48000;
	localparam integer SPC       = CLK_HZ / SAMPLE_HZ;   // 298 clks per sample

	reg        clk = 0, reset = 1, speaker = 0;
	wire [7:0] level;
	integer    errors = 0;

	speaker_filter #(.TAPS(TAPS)) dut (
		.clk(clk), .reset(reset), .speaker(speaker), .level(level)
	);

	always #5 clk = ~clk;

	task settle(input integer n);
		integer k;
	begin
		for (k = 0; k < n; k = k + 1) @(negedge clk);
	end
	endtask

	task expect_level(input [127:0] name, input integer got, input integer want,
	                  input integer tol);
	begin
		if (got < want - tol || got > want + tol) begin
			$display("  FAIL: %0s = %0d, expected %0d +/- %0d", name, got, want, tol);
			errors = errors + 1;
		end else begin
			$display("  ok:   %0s = %0d (expected %0d +/- %0d)", name, got, want, tol);
		end
	end
	endtask

	// The running sum must always equal the population count of the window.
	// If that invariant ever breaks the filter has over- or underflowed.
	integer i, ones;
	always @(posedge clk) if (!reset) begin
		ones = 0;
		for (i = 0; i < TAPS; i = i + 1) ones = ones + dut.sr[i];
		if (dut.acc !== ones[8:0]) begin
			$display("  FAIL: acc=%0d but window holds %0d ones", dut.acc, ones);
			errors = errors + 1;
		end
	end

	// Drive the speaker as a square wave of the given half-period (in clks) for
	// `clks` cycles, sampling `level` every SPC clocks the way the framework's
	// 48 kHz resampler would, and reporting the min/max spread of those samples.
	integer smin, smax, ssum, scount, half_ctr, lv;
	task drive_square(input integer half, input integer clks);
		integer k;
	begin
		smin = 999; smax = 0; ssum = 0; scount = 0; half_ctr = 0;
		for (k = 0; k < clks; k = k + 1) begin
			@(negedge clk);
			half_ctr = half_ctr + 1;
			if (half_ctr >= half) begin half_ctr = 0; speaker = ~speaker; end
			if (k % SPC == 0 && k > TAPS) begin
				lv = level;                       // integer, so the compares are signed
				if (lv < smin) smin = lv;
				if (lv > smax) smax = lv;
				ssum = ssum + lv; scount = scount + 1;
			end
		end
	end
	endtask

	// Same drive, but sampling the RAW speaker bit - i.e. what the core did
	// before this filter existed.
	integer rmin, rmax, rv;
	task drive_square_raw(input integer half, input integer clks);
		integer k;
	begin
		rmin = 999; rmax = 0; half_ctr = 0; speaker = 0;
		for (k = 0; k < clks; k = k + 1) begin
			@(negedge clk);
			half_ctr = half_ctr + 1;
			if (half_ctr >= half) begin half_ctr = 0; speaker = ~speaker; end
			if (k % SPC == 0 && k > TAPS) begin
				rv = speaker ? 128 : 0;
				if (rv < rmin) rmin = rv;
				if (rv > rmax) rmax = rv;
			end
		end
	end
	endtask

	initial begin
		settle(4); reset = 0; settle(4);

		$display("1. DC low");
		speaker = 0; settle(TAPS + 8);
		expect_level("level", level, 0, 0);

		$display("2. DC high must reach the old peak amplitude of 128");
		speaker = 1; settle(TAPS + 8);
		expect_level("level", level, 128, 0);

		$display("3. back to DC low");
		speaker = 0; settle(TAPS + 8);
		expect_level("level", level, 0, 0);

		// One clk per half period is the fastest possible edge rate. Point
		// sampling would return 0 or 128 depending on phase; the average is 64.
		$display("4. toggling every clock averages to mid-scale");
		drive_square(1, TAPS * 8);
		expect_level("mean", ssum / scount, 64, 1);

		// ~1 MHz: a CPU banging $C030 every couple of cycles. This is the case
		// that used to alias.
		$display("5. ~1 MHz square wave (half period 7 clks)");
		drive_square(7, SPC * 40);
		$display("      filtered samples span %0d..%0d, mean %0d",
		         smin, smax, ssum / scount);
		expect_level("mean", ssum / scount, 64, 4);
		if (smax - smin > 24) begin
			$display("  FAIL: filtered output still swings %0d - not band-limited",
			         smax - smin);
			errors = errors + 1;
		end else begin
			$display("  ok:   filtered swing is only %0d", smax - smin);
		end

		// The same waveform, point-sampled the way the core used to do it.
		drive_square_raw(7, SPC * 40);
		$display("      unfiltered point samples span %0d..%0d", rmin, rmax);
		if (rmax - rmin < 100) begin
			$display("  FAIL: expected the unfiltered path to alias badly");
			errors = errors + 1;
		end else begin
			$display("  ok:   unfiltered swing is %0d, which is the aliasing",
			         rmax - rmin);
		end

		$display("6. 25%% duty cycle tracks amplitude, not just frequency");
		speaker = 0; settle(TAPS + 8);
		begin : duty25
			integer k;
			for (k = 0; k < TAPS * 6; k = k + 1) begin
				@(negedge clk);
				speaker = ((k % 8) < 2);   // 2 of every 8 clks high
			end
		end
		expect_level("level", level, 32, 2);

		$display("");
		if (errors == 0) $display("PASS - all speaker_filter checks ok");
		else             $display("FAIL - %0d error(s)", errors);
		$finish;
	end

	initial begin
		#20_000_000;
		$display("FAIL - timeout");
		$finish;
	end
endmodule

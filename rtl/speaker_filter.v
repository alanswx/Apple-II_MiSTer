//
// Speaker anti-alias filter for the MiSTer Apple II core
//
// Copyright (c) 2026 Alan Steremberg
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
// $C030 toggles a flip-flop (apple2.vhd:321-328). That one bit used to go
// straight into audio(7) and get point-sampled at 48 kHz downstream, so a
// speaker driven anywhere near the CPU's 1 MHz ceiling aliased freely into the
// audible band - the grit on Electric Duet, four-voice music and digitised
// speech. Which alias you got depended on the sampling phase, not on the
// waveform.
//
// The fix is the one AppleWin uses: don't sample the level, average it. A
// boxcar over one output-sample period turns the speaker's local duty cycle
// into an amplitude, which is what the ear actually hears from a 1-bit driver.
//
// 256 taps at 14.318181 MHz is a 17.9 us window - just under the 20.8 us of a
// 48 kHz sample - putting the first null at 55.9 kHz. 256 is chosen over an
// exact 298 because the output scaling then costs a shift instead of a
// multiplier, and the filter shape barely moves.
//
// Measured on hardware over HDMI capture, driving the speaker with an 11-cycle
// toggle loop (a 46.4 kHz square wave, which aliases to 48000-46386 = 1614 Hz):
//
//   1614 Hz alias   -14.2 dB
//   1 kHz control    -0.0 dB
//
// So the artefact drops by more than a factor of five while ordinary in-band
// audio is untouched - at 1 kHz this filter is 0.003 dB down.
//
// -14 dB is close to the ceiling for a single boxcar and lengthening it will
// not help: a rectangular window's first sidelobe is -13 dB however many taps
// it has, and 46 kHz lands in the sidelobes. Cascading two boxcars (a
// triangular window) would roughly double the rejection in dB, at the cost of a
// second delay line that is 9 bits wide rather than 1 - likely an M10K, and
// block RAM is the binding resource here at 72%. Not worth it for now.
//
// Cost is a 256-bit shift register and a 9-bit running sum: one add and one
// subtract per clock, no multiplier and no memory block.
//

module speaker_filter #(
	// Window length in clk cycles. Must stay a power of two: the output scaling
	// below is a shift, and ACC_W/the widths depend on it.
	parameter TAPS = 256
) (
	input            clk,
	input            reset,

	// Raw speaker flip-flop level.
	input            speaker,

	// Box-averaged level, 0..128, matching the amplitude the unfiltered
	// audio(7) used to contribute so the mix balance is unchanged.
	output     [7:0] level
);

localparam ACC_W = $clog2(TAPS) + 1;   // 0..TAPS inclusive

reg [TAPS-1:0]  sr;
reg [ACC_W-1:0] acc;

// acc is by construction the number of ones in sr, so it can never exceed TAPS
// and can never underflow: the subtracted bit is only set when acc >= 1.
always @(posedge clk) begin
	if (reset) begin
		sr  <= {TAPS{1'b0}};
		acc <= {ACC_W{1'b0}};
	end else begin
		sr  <= {sr[TAPS-2:0], speaker};
		acc <= acc + {{(ACC_W-1){1'b0}}, speaker}
		           - {{(ACC_W-1){1'b0}}, sr[TAPS-1]};
	end
end

// acc spans 0..256; halving gives 0..128, the old peak amplitude exactly.
assign level = acc[ACC_W-1:1];

endmodule

# TODO

Work plan for the MiSTer Apple //e core, and the parts of it that land in sibling
repositories (`Apple-IIgs_MiSTer`, `Main_MiSTer`).

Most items come from a survey of Henri Asseily's [Appletini
One](https://github.com/hasseily/appletini-one) (a Zynq-7020 //e card) against
this core and the IIgs core, August 2026. Where an item says "port", the source
file is named so the comparison can be re-checked.

**Licensing:** Appletini's repo root is GPL-3, but its `README.md` says "No
repository-wide license is granted by this README" and most RTL files have no
header. **The author has since given permission to use the code** (2026-08-26),
so items below that port from Appletini are cleared. Attribute in the file
header, as `rtl/no_slot_clock.v` does. `via6522.v` (Skibo) and `YM2149.sv` are
separately BSD and were always safe.

---

## Phase 0 — quick wins

### 1. No-Slot Clock, replacing the current clock card
**Status:** done in the working tree, **not yet tested on hardware**

`rtl/no_slot_clock.v`, a DS1216E: the 64-bit `5CA33AC55CA33AC5` unlock pattern, A2
selects read/write, A0 shifts, 64 reads return the time LSB-first, all BCD.

It hides under every slot's ROM page and the `$C800` window rather than claiming
addresses, so it needs **no slot** and works with the stock NSC drivers
(NS.CLOCK.SYSTEM, the ProDOS 8 driver, AppleWorks, Total Replay's clock check).

- Fed from the HPS `RTC` input, with the BCD ticker lifted from the old
  `clock_card.v` so time advances between HPS updates.
- `NSC_CS` in `apple2_top.vhd` is the snoop; `PHASE_ZERO_R` is the cycle enable.
- OSD bit `o1` under Hardware turns it off.
- `rtl/clock_card.v`, `rtl/roms/clock.a65` and `rtl/roms/clock.hex` deleted; slot 1
  is now empty. `README.md` and `CLAUDE.md` slot tables updated.
- `rtl/tb_no_slot_clock.v` covers unlock, read-back, write, wrong pattern, ordinary
  ROM reads, the free-running ticker, and the disable. Passes under iverilog.

**Verified on hardware** (MiSTer, 2026-08-26). Reads the correct date and time,
zero drift measured over 332 s, and the unmodified third-party `NSC` driver from
Asimov's `NoSlotClock.dsk` displays a live ticking clock.

Two bugs only hardware testing found, both now covered by the testbench:

1. `data_en` was a one-clock pulse at `PHASE_ZERO_R`; `PD` is a combinational mux
   and the CPU does not latch until a clock after PHI0 falls, so reads returned
   the floating bus. It must be a level held for the whole access.
2. `NSC_CS` snooped raw `IO_STROBE`, i.e. all of `$C800-$CFFF`, which picked up a
   constant stream of firmware reads at `$CFA0`/`$CFA1`. Every one shifted a bit
   and derailed the matcher. Now slot ROM pages only.

   *(A `cs_edge` qualifier was added at the same time, believing the CPU held its
   address for ~5 cycles per access. That was wrong — see the corrected note in
   CLAUDE.md. `R65Cx2.vhd` only holds for RMW, `cyclePreWrite` and implied
   `cycle2`. The window narrowing was the fix that mattered; `cs_edge` is
   defensive.)*

Also: the `$C800` window is no longer snooped. Raw `IO_STROBE` picked up a constant
stream of firmware reads at `$CFA0`/`$CFA1` that derailed the matcher. Appletini
gates that window on the owning slot; we have no equivalent, so slot ROM pages only.

**Known limitation.** Drivers that hardcode `$C300` (the `NSC` binary above uses
`WRTNSC EQU $C300` / `READNSC EQU $C304`) need `POKE 49163,0` (SETSLOTC3ROM) first,
because `C3ROM` resets to 0 and `$C3xx` then goes to the //e's internal 80-column
ROM, where `IO_SELECT(3)` never asserts. A real DS1216E sits physically under the
ROM socket and snoops the address lines whoever responds. Emulating that faithfully
means giving `CLOCK_OE` priority over `rom_out` in `apple2.vhd`'s `D_IN` mux -
a change to the core data path, deliberately not made.

### 2. Replace the 6522 VIA
**Status:** done in the working tree, **not yet tested on hardware**

`rtl/mockingboard/via6522.v` is Skibo's BSD-3 core via Appletini, with
`tb_via6522_timing.sv` alongside it — the MB-Audit-derived checks (T6522_F IFR
boundary, T6522_15 T1 flag-clear) pass under iverilog. The old
`rtl/mockingboard/via6522.vhd` and its "do not use without written permission"
notice are gone.

Wiring notes, since the interface is not a drop-in:

- `slow_clock` = `PHASE_ZERO_R` (early in the Apple cycle), `strobe` =
  `sel and PHASE_ZERO_F` (late). The VIA depends on that ordering to hand a read
  the counter value from before this cycle's decrement — T6522_3. The old VHDL
  VIA did its register access on `PHASE_ZERO_R`, so **every Mockingboard register
  access is re-timed by half an Apple cycle**. That is the main risk here.
- `strobe` is deliberately *not* edge-qualified, matching the old
  `wen/ren and falling`. RMW instructions legitimately drive the same address for
  read/modify/write and the VIA should see all of those cycles.
- New `I_POWER_RESET` port on MOCKINGBOARD, fed from `power_on_reset` in
  `apple2_top.vhd`, so the T1/T2 latches survive an Apple RESET.
- `ifr_set_ext` / `ifr_clr_ext` tied off (no speech chips),
  `timer_read_extra_clock` = 0.

Fit: 19,266 ALMs (46%, +284), RAM blocks unchanged at 399, setup slack 0.420 ns.

**Verified on hardware** (2026-08-26) by driving the AY directly through the VIA
from BASIC — DDRA/DDRB, latch-address, write-data, mixer, amplitude, tone period
— to a fixed 996.6 Hz, and capturing over HDMI. Pre-swap and post-swap cores:

| | pre-swap VIA | Skibo VIA |
|---|---|---|
| fundamental | 996.5 Hz | 996.5 Hz |
| rms | 1017 | 1013 |
| harmonics 3rd-15th | -9.4 -14.3 -16.6 -19.2 -20.7 -22.3 -24.1 | -9.4 -14.3 -16.6 -19.1 -20.7 -22.3 -24.1 |

Every harmonic within 0.1 dB. The timer rate needs no measurement: the old VIA
decremented on `falling`, which *is* `PHASE_ZERO_R`, the same signal now feeding
`slow_clock`.

mb-audit would still be the better validator and remains blocked by item 4.

Original notes follow.

**Effort:** ~1 day

Swap `rtl/mockingboard/via6522.vhd` for `appletini-one/hdl/apple/via6522.v`
(Thomas Skibo, **BSD-3**) plus its testbench `tb_via6522_timing.sv`. Each fix is
tagged with the mb-audit test it satisfies:

- Timer snapshot at the slow clock so a late read returns the pre-decrement
  value — **T6522_3/4** (`:270-284`)
- IFR read does not expose timer underflow early — **T6522_F/10/11** (`:565-571`)
- T1 flag-clear semantics — **T6522_15** (`tb_via6522_timing.sv:221-259`)
- `power_reset` vs `reset` split so T1/T2 latches survive an Apple RESET (`:296-308`)

Ours resets latches to `X"5550"` and has none of this. Bonus: the current file
carries Gideon Zweijtzer's "do not use without written permission" notice
(`via6522.vhd:11-14`), so this is also a licensing cleanup.

Wiring: `slow_clock` = 1 MHz tick, `strobe` = PHASE_ZERO edge, `ifr_*_ext` tied
off, `timer_read_extra_clock` = 0.

**Settled (2026-08-26): route both VIAs to IRQ.**

First, the note this replaced was wrong about what we do. We route VIA1 (left,
`$Cn00`) to **IRQ** already — the same as Appletini. The actual difference is
VIA2 (right, `$Cn80`), which we send to **NMI** (`mockingboard.vhd:102-103`,
`lirq`->`O_IRQ_L`, `rirq`->`O_NMI_L`).

Every reference implementation routes both VIAs to IRQ and never asserts NMI:

- **AppleWin** — "NB. Mockingboard generates IRQ on both 6522s", and NMI appears
  in that file only to say the speech IRQs "must generate a 6502 IRQ (not NMI)".
- **Appletini** — `assert_irq <= via0_irq | via1_irq | ssi0_direct_irq |
  ssi1_direct_irq`, with `assert_nmi <= 1'b0` (`mockingboard.sv:1067-1070`).
- **Clemens** — `mockingboard.c:881` returns `CLEM_CARD_IRQ` if either VIA is
  active.

Real boards *could* be jumpered with one VIA on NMI — mb-audit probes for exactly
that. But it treats it as a degraded configuration: "Don't use 6522 if it's
connected to NMI (as nested IRQ then NMI aren't supported by my ISR)", and skips
**T6522_E, T6522_F and T6522_17** when it sees an NMI. So our current wiring
actively costs us coverage on the very test suite item 2 is meant to satisfy.

Apple's own tech note settles the hardware question: NMI is not recommended for
peripheral cards, because "the data and programs on the disk may be destroyed if
an NMI occurs while the Apple is writing data to the disk." DOS masks IRQ around
disk I/O; nothing can mask NMI.

So: `O_NMI_L` should be tied inactive and `rirq` OR'd into `O_IRQ_L`. This is a
small change and independent of the VIA swap itself — worth doing either way.

### 3. Audio: fix the mixer, then band-limit the speaker
**Status:** ready · **Effort:** 1–2 days

Do **not** port Appletini's `onee_speaker_audio.sv` — the framework already
DC-blocks at ~15 Hz (`sys/audio_out.sv:224-243`, `sys/iir_filter.v:189-213`), so
that module is redundant. The real problems are different:

1. ~~**Mixer overflow (bug).**~~ **Done.** `apple2_top.vhd` now sums in 12 bits
   and saturates at 1023 instead of wrapping 1658 to 634. Clamping was chosen over
   rescaling so the gain - and so the loudness of the common one-board case, 893 -
   is unchanged; only the rare both-boards-flat-out peak clips. Not yet listened to
   on hardware.
2. ~~**The speaker is not band-limited.**~~ **Done.** `rtl/speaker_filter.v`
   box-averages the `$C030` flip-flop over 256 `clk_sys` cycles before it reaches
   `audio`, the way AppleWin does. 256 rather than 298 so the output scaling is a
   shift, not a multiplier.

   Confirmed by measurement, not assumption. Over HDMI capture an 11-cycle toggle
   loop (46.4 kHz square wave) produced a **1614 Hz** tone — exactly
   `48000-46386`, a frequency present nowhere in the source. After the filter:

   | | before | after |
   |---|---|---|
   | 1614 Hz alias | 138.0 | 26.9 (**−14.2 dB**) |
   | 1 kHz control | 1643.8 | 1640.6 (−0.0 dB) |

   The framework's own IIR (`sys/sys_top.v:339-347`) does sit before the 48 kHz
   decimation, but is far too gentle to prevent this — worth knowing before
   assuming `sys/` handles band-limiting for you.

   **If more rejection is wanted:** lengthening the boxcar will not give it. A
   rectangular window's first sidelobe is −13 dB at any length, and 46 kHz lands in
   the sidelobes. Cascading two boxcars (a triangular window) roughly doubles the
   rejection in dB; the cost is a second delay line 9 bits wide instead of 1, which
   likely means an M10K, and blocks are the binding resource at 72%.
3. **Bipolar mapping.** Map the speaker to ±A instead of 0/+A so it is centered at
   the source and uses sane headroom. **Deliberately not done**, and arguably no
   longer worth doing: the whole mix is unsigned (`AUDIO_S = 0`), so making just
   the speaker bipolar means reworking the Mockingboard paths and the new clamp to
   signed arithmetic. The two stated benefits are already covered — the framework
   DC-blocks at ~15 Hz, and the headroom question was settled by the saturating
   mix in item 1.

### 4. ProDOS 2.4.x does not boot — blocks mb-audit
**Status:** newly found, not diagnosed · **Effort:** unknown

ProDOS 8 **2.4.1 and 2.4.3** both print their banner and then BRK into the
monitor (`P=32`, B set, `X=$C3`). Reproduced on `ALECLOCK.dsk` and on
`mb-audit-v1.60`, and **on the pre-existing `Apple-II_20260603.rbf` as well**, so
it is not caused by any of the recent work. DOS 3.3 and ProDOS-based games boot
fine, so it is specific to 2.4.x.

`X=$C3` at the BRK hints at slot-3 scanning — 2.4.x probes hardware far more
aggressively than 1.1.1 or 2.0.3.

This matters beyond the disks above: **mb-audit ships as a ProDOS 2.4.x disk**,
so until this is fixed the Mockingboard test suite cannot run on this core, and
item 2's per-test claims (T6522_3/4, F/10/11, 15) cannot be verified on hardware.

Note mb-audit is distributed as `.po`, which this core serves raw. Convert to DOS
order first — the DOS/ProDOS interleave is self-inverse:
`[0,14,13,12,11,10,9,8,7,6,5,4,3,2,1,15]`, applied per 16-sector track. A correct
conversion puts the ProDOS volume directory at offset `0x0B00`.

---

## Phase 1 — WOZ

### 4. Fix the IIgs WOZ engine, then port it here
**Status:** ready · **Effort:** 3–5 weeks · **Lands in:** `Apple-IIgs_MiSTer`, then here, plus `Main_MiSTer`

The IIgs core already does bit-level and flux-level WOZ, and native `.woz` files
are passed through verbatim (`Main_MiSTer/support/a2/iigs_disk.cpp:215`) with the
FPGA parsing INFO/TMAP/TRKS/FLUX off SD blocks. The DSK→WOZ converter produces
byte-aligned nibbles and cannot represent protection — that path is only a bridge
for unprotected formats. **The passthrough is what makes this worth porting.**

**Do this first:** `Apple-IIgs_MiSTer/vsim/disks_525/` holds ~2,860 5.25" WOZ
images (2,587 v2 · 266 v1 · 7 v3 · 145 with `WRIT` · 6 with `FLUX`) and
`vsim/test_woz_batch.sh` is a parallel, resumable batch harness with an HTML
report — **and it has never been run** (`vsim/woztest/` and `vsim/woz_report/`
do not exist; `regression.sh:175-185` tests exactly one 3.5" image). Get a
baseline before writing any code.

Six defects, ordered by how many titles they affect:

| Pri | Defect | Reach |
|-----|--------|-------|
| P1 | **TMAP alias forces a full reload on every quarter-track nudge.** `Apple-IIgs.sv:936-938` compares the raw quarter-track index rather than the TMAP-resolved TRK, so a wobble resolving to the same TRK still re-reads 13 identical blocks after a 3.5 ms settle (`woz_floppy_controller.sv:297,784,879`). The stale-data gate is disabled (`iwm_woz.v:762`), so the drive streams mixed old/new BRAM during the reload. *Fix: cache the TMAP value, skip the reload when unchanged; reset settle on TRK change, not half-track.* | 822 half-track + 106 quarter-track disks |
| P2 | **Weak bits wrong in three ways.** Threshold is 7 zeros (`flux_drive.v:1684`) vs the reference model's 4. `head_window` is written (`:1667`) but **never read anywhere**, so there is no MC3470 one-cell delay and fake bits land at the *end* of a zero run instead of the middle. The LFSR free-runs every 14 MHz clock (`:1188`), so noise does not repeat per revolution. Reference: `../clemens_iigs/clem_drive.c:337-368`. | 2,673 disks on the path; 165 mis-read (Maniac Mansion, Ultima V, Wizardry V, Alcazar, Copy II Plus) |
| P0 | **Bit cell is 3.911 µs, not 4.0.** `flux_drive.v:136` uses 56 clocks with a comment claiming "4µs @14M", but clk_sys is 14.318181 MHz — a **2.27% systematic error on every disk**. Correct value is 57.27. And `optimal_bit_timing` (INFO byte 39) is parsed at `woz_floppy_controller.sv:1409` and used **only in a `$display`**; the fractional accumulator that would fix it is gated `IS_35_INCH` (`:325-327`). | 22 disks fail outright (all late-Infocom side B at timing 28, all Newsroom revisions at 34); all 2,860 skewed |
| P0 | **No data separator.** The 5.25" read path (`iwm_flux.v:259-270, 837-907`) is a free-running mod-56 counter that never re-phases on a flux edge — the code documents a resulting hardware wedge at `:849-851`. Real hardware restarts its window on every transition. **This caps everything else**: honouring bit timing fixes uniform-rate disks, but within-track variation still needs a resyncing window. Blocks E7/Sierra bitstream and bit-slip families. | structural |
| P3 | **Write-back can corrupt the image.** `trk_start_block`/`trk_block_count` are set only on a successful load (`:1206-1207`), but the empty-TMAP path (`:960-1007`) leaves them pointing at the *previous* track while `bit_we` sets dirty unconditionally (`:619-623`) — writing an unmapped track overwrites the last-loaded track's blocks. Also never updates TRK bit-count, TMAP, or header CRC32, so saved images fail validation in Applesauce/CiderPress2/MAME. `WRIT` chunks are never parsed. | 145 WRIT disks + live corruption |
| P4 | **Angular position not scaled across tracks.** Position is kept as a raw bit index, so when adjacent tracks differ in bit count the same index is a different angle. `head_window`/`zero_run_count` also reset at wrap, truncating weak regions that straddle the loop. INFO byte 3 (`synchronized`, set on 2,842 images) is never read. Breaks SpiraDisc and RapidLok track-arc timing. | 209 disks with >1000-bit spread |

**Then port here.** Start from the fixed `woz_floppy_controller.sv` + `flux_drive.v`
— same `sd_lba/sd_rd/sd_buff_*` interface as our `rtl/floppy_track.sv`, already
parameterized `IS_35_INCH=0`, Quartus-proven. `iwm_flux.v:260-270, 833-907` holds a
Disk-II-equivalent 5.25" shifter that extracts (~80 lines) without the IWM; Q6/Q7
map directly. Instantiate two drives (SD slots 0 and 2), mux by `drive2_select`
(`disk_ii.vhd:71-73`). This replaces `rtl/drive_ii.vhd`'s fixed 32 µs byte cadence
and `X"19FF"` wrap.

**Main_MiSTer side:** extend the core-name gate. The IIgs uses `iigs_is_core()`
(`support/a2/iigs_disk.cpp:40-44`); the 8-bit core uses an inline full-compare at
`user_io.cpp:2132`, so they never collide today. Doing this also fixes `.po`/`.do`
(see Bugs below).

**Regression gauntlet to add:** Gumball (65 quarter-track entries + cross-track
sync — the best single stress case), Lode Runner (half-track, already special-cased
at `Apple-IIgs.sv:931-935`), Choplifter, Cyclotron (known-fail), Beyond Zork side B
(timing 28), The Newsroom (timing 34), Carmen Sandiego side B (fuzzy bits), Essex
side 1 (write-back).

---

## Phase 2 — memory and DMA

### 5. RamWorks
**Status:** ready · **Effort:** 1–2 weeks

**8 MB is not reachable in block RAM.** Measured fit: 399/553 M10K used, ~154 free,
and one 64K bank costs 64. 8 MB = 128 banks = 8,192 blocks against 553 on the whole
device (~692 KB total). BRAM tops out around 128–192K of aux.

**Use the SDRAM module**, with the IIgs core as the template:

- Copy `../Apple-IIgs_MiSTer/rtl/sdram.sv` — its toggle req/ack handshake was
  written specifically for a CLK_14M-domain requester (`:5-11`).
- Its SDRAM clock is 114.545 MHz = **exactly 8× clk_sys**, so the crossing is
  PLL-related and trivial. Regenerate `rtl/pll.v` with the extra outputs (3/6 PLLs
  used today).
- Budget: ~489 ns per CPU access vs 78.6 ns for a random SDRAM access — **~6×
  margin, no cache or burst logic needed**. Appletini reaches the same conclusion:
  its `psram_simple.sv:1-38` states outright it has "no cache, tags, speculative
  requests" and serves RamWorks byte-by-byte.

**The rule that keeps 80-col/DHGR working:** aux **bank 0 stays in block RAM**,
because `apple2.vhd:200-213` latches main+aux in the same cycle for the video
scanner. Banks 1–127 are CPU-only in SDRAM. One line expresses it, and it matches
real hardware — RamWorks video always scans bank 0:

```vhdl
ram_bank <= aux_bank when PHASE_ZERO = '1' else "0000000";
```

Other changes:
- Bank register at `$C071`/`$C073`, data bit 7 = 0 selects bank 0–127, bank 0 on
  Ctrl-Reset (Appletini `soft_switch_manager.sv:159-165`).
- `apple2.vhd:265` currently swallows all of `$C070-$C07F` into `PDL_STROBE` —
  needs a write-qualified decode that preserves paddle-strobe reads.
- Thread `ram_bank` through `apple2_top.vhd`; OR a wait into the existing
  `CPU_WAIT` if desired.
- **Gate on `sdram_sz`** (`sys/hps_io.sv:161,525`) and fall back to 64K aux when no
  SDRAM board is fitted. The IIgs hard-requires SDRAM; this core has a large
  installed base without the add-on, so graceful fallback matters more here.
- New OSD options must use status bit `o1` and up — `O0`–`OV` and `o0` are taken.

Ceiling with SDRAM: 8 MB uses a quarter of a 32 MB board; 16 MB (RamWorks IV) also
fits.

### 6. Port the IIgs HDD DMA engine
**Status:** ready · **Effort:** ~1 week

The IIgs hard drive is a genuine cycle-stealing bus master: engine at
`Apple-IIgs_MiSTer/rtl/hdd.v:128-227`, arbitration is just
`RDY_IN(~hdd_dma & ~mem_stall)` on the 65816 (`iigs.sv:2053`) plus three bus
muxes — address (`:458`), write-enable (`:425`), data (`:421-423`). 512 bus cycles
per block.

Today our `rtl/hdd_rom.vhd` firmware copies 512 bytes one at a time through
`$C0F8` (`LDA $C0F8 / STA ($44),Y / INY / BNE`) — roughly **3,000 CPU cycles per
block** on top of the SD wait. DMA replaces that with 512 bus cycles and deletes
the port. `CPU_WAIT` is already wired.

Two caveats:
- Our DMA must drive main/aux select alongside the address; the IIgs gets that free
  from its MMU.
- **There is no arbiter** — `hdd_dma` is hardcoded in six places in `iigs.sv`.
  Adding a Z80 as a second master means writing one. If the Z80 (item 9) is
  coming, design the arbiter here rather than bolting it on later.

---

## Phase 3 — CPU and acceleration

### 7. W65C02 core + TransWarp-style turbo
**Status:** ready · **Effort:** 2–3 weeks

**Keep non-enhanced //e compatibility.** Make the CPU a three-way choice: 6502
(T65, NMOS — for II+/unenhanced //e), 65C02 (current `rtl/R65Cx2.vhd`), and the new
W65C02. The menu already has `P1O5,CPU,65C02,6502`; widen it. The NMOS path is
untouched, so nothing regresses.

**The core:** `appletini-one/hdl/apple/w65c02_core.sv` (1592 lines) is cycle-exact
with dummy cycles modelled, full Rockwell bit ops (BBR/BBS/RMB/SMB), WAI/STP, and
W65C02S invalid-BCD/V-flag behaviour. Verified against 2.54 M SingleStepTests
vectors, Klaus functional + 65C02 extended + decimal + interrupt suites, and 266
directed pin checks. Ours NOPs the Rockwell ops (`R65Cx2.vhd:314,322`) and WAI/STP
(`:517,533`). Same enable-per-cycle contract → near drop-in; ~1010 LUTs; no vendor
primitives (only `DONT_TOUCH`/`KEEP` attributes, harmless in Quartus). Async reset
at `:1075` — fine on Cyclone V, just wrap the polarity.

**The turbo is a ~100-line policy**, not the whole Virtual TransWarp. Skip the bus
shadowing, DMA and posted-write queue — we own RAM. Take from
`vtw_core_top.sv:959-1031, 1403-1446`:

- Three speed modes: full, divided (26/13/7/3.6/2.6 MHz), and cycle-locked 1 MHz so
  cycle-counting detectors see a stock machine.
- `$C074` register: 0 = fast, 1 = 1 MHz, 3 = off until reset.
- Per-region one-shot slowdowns, retriggered per access: speaker/video
  `$C030-$C05F`, paddles, per-slot I/O and slot ROM.
- Always slow for `$C0E0-$C0EF` and the whole Q7 write window; Mockingboard slot
  always slow because 6522 timer detection counts cycles.

**The real work is ours:** `apple2.vhd:179-209` time-multiplexes one RAM port
between CPU and video. Turbo needs a CPU access slot every 14 MHz clock with video
interleaved, or a second port. Preserve the rule that any `$C000-$CFFF` access
completes on a real PHI0 boundary.

---

## Phase 4 — cards

### 8. Phasor / Echo+ Mockingboard modes
**Status:** ready · **Effort:** 2–3 days · **Do after item 2**

Self-contained in `appletini-one/hdl/apple/mockingboard.sv`: 3-bit mode register
(`:31-33`) switched by the Phasor `$C0nX` soft-switch (`:534-545`), 4× YM2149
(`:706-784`), AppleWin chip-select latch state machine (`:557-592`), doubled PSG
clock in Phasor native (`:547-555`). Skip the 5-band tone shaping and per-channel
pan — menu bloat.

Also take the a2fpga `YM2149.sv` fork: `address_latched` guard, separate noise reset
on register 6, register 7 not forced on reset.

Mind the mixer overflow from item 3 — adding two more PSGs makes it worse.

### 9. Z80 CP/M card (SoftCard)
**Status:** **blocked on licensing** · **Effort:** days once cleared

A complete working implementation is already on this machine:
`../apple2cpm/apple2efpga`, commit **`d75cb8b` "Use T80 module (SoftCard)"** —
VHDL, MiST-targeted, using the same T80 v351 at `../T80`. It has the full `z80_ham`
address-mangling table, the `zsel` toggle on `$C4xx` writes, `CPU_FREEZE` for the
6502, a Language Card proxy (`mist/apple2e_mist.vhd:616-631`), and bootable CP/M
disks (`softw/cpm/`). Provenance: Jesús Arias' `a2e128/src/system.v`.

**SoftCard, not Appli-Card** — deliberately unlike Appletini. Appletini chose
Appli-Card because it runs its Z80 as an ARM *interpreter*, where a shared-bus
design cannot be timed. We have a real T80 in fabric on the same memory, so that
reason vanishes. SoftCard is the compatibility baseline nearly all Apple II CP/M
software targets, and the Applied Engineering Z-80 Plus is a clone, so it comes
free. In FPGA it is *simpler* than the hardware: the real card used Z80 RFSH to
keep the 6502's registers from decaying, irrelevant with flops.

**Blocker:** both `apple2efpga` and `a2e128` are **unlicensed** — no LICENSE file,
nothing declared on GitHub. Needs an explicit grant from Maverick-Shark before it
can land in a MiSTer-devel repo.

Someone else is already working on Z80 support for this core — hand them that
commit plus this warning.

### 10. SSI-263 / SC-01A speech
**Status:** ready · **Effort:** 1–2 weeks

Pure RTL, no ARM involvement: `ssi263_bus_wrapper.sv` (AppleWin-faithful
register/D7/IRQ/mode-switch semantics) → `ssi263_formant_backend.sv` →
`sc01a_digital_core.sv` (derived from Galibert's MAME/vsim SC-01A die simulation).
One shared 24×16 MAC, ~150 clocks per 48 kHz sample — comfortable at 28 MHz.

Set expectations honestly: it is an SC-01A formant synth with an SSI-263 phoneme map
layered on (`ssi263_formant_pkg.sv:9-91`), tuned by ear. It talks; it is not
bit-accurate SSI-263.

Convert the 4119-line coefficient package (F2 table ≈ 3,585 signed-16 entries) to a
`.mif` ROM rather than letting Quartus infer it as logic — and re-check the fit,
since block RAM is the binding constraint.

---

## Sibling-repo items

### 11. IIgs hard drive → real SmartPort, 8 units
**Status:** blocked on a slot ceiling · **Effort:** 1–2 weeks · **Lands in:** `Apple-IIgs_MiSTer`

`rtl/smartport_dev.v` is *not* the hard drive — it is an IWM SmartPort protocol
engine instantiated with **every block-I/O port stubbed off** (`iwm_woz.v:1120-1127`).
It cannot read or write an image, decodes only `$41`/`$42`/`$43`, has no GETDIB, and
`cmd_unit` is captured but never used. There is also a dead `sp_hdd` reference at
`iigs.sv:2469-2491` that would not compile.

The real drives are `rtl/hdd.v`: **2 units** (`hdd_unit = reg_unit[7]`, one bit,
`:122`), **16-bit block = 32 MB max** (`:118`). There *is* genuine slot firmware with
a SmartPort entry at `$Cn0D` (`hdd.a65:100`), but it is a shim funnelling into ProDOS
registers — `$Cn07` is `$3C` (deliberate, so it autoboots on a ][+) and `$CsFE`
declares 2 volumes.

Getting to 8 units is mechanical: widen unit decode to `[2:0]` and mount arrays to
`[8]`; add a third block register at the dead `$C0F8` port for 24-bit/8 GB; fan
`sd_rd`/`sd_wr`/`img_mounted` out to 8; flip `$Cn07` to `$00` and add a real GETDIB
path. The shared 512-byte sector buffer is fine — only one transfer is ever in flight.

**Blocker: `VDNUM`.** `sys/hps_io.sv:27` caps it at **10**; the core uses 5 today.
8 HDD + 2 WOZ floppies + 1 NVRAM = **11**. Decide before starting: move NVRAM off a
virtual-disk slot, or ship 7 units.

### 12. Ethernet for the IIgs
**Status:** research done, not started · **Effort:** 3–4 weeks

The Macintosh LC core has **no ethernet** to reuse — its own `HARDWARE.md:66` says
"Correctly absent. LC has no built-in ethernet." SONIC was a card, not on-board.

The template is the **Amiga A2065** (AMD Am7990 LANCE) in upstream Minimig +
Main_MiSTer: FPGA implements only autoconfig, a 32 KB board-RAM window and the CSR
register file; the HPS owns the state machine and descriptor rings; transport is a
**DDR3 shared-memory mailbox** (doorbell ring, FPGA never blocks); packets reach
Linux via raw socket, dedicated NIC, macvlan or tap, OSD-selectable. Our local
`Main_MiSTer` checkout predates it.

**Emulate Uthernet I (CS8900A), not Uthernet II.** The W5100 is a hardware TCP/IP
offload engine (4 sockets, TCP state machines, 8 KB buffers); reimplementing it in
software is a large project with no MiSTer precedent. Appletini sidesteps it by
soldering the real chip on, which we cannot. The CS8900A is a plain MAC, and
Marinetti and Contiki both support it. LANceGS uses the same chip.

We already have the emulation: `../ai/*/software_emulators/gsplus/src/rawnet/cs8900.c`
(1675 lines, from VICE, **GPL-2**) plus `rawnetarch_tap.c`, the Linux tap backend the
HPS would use. Preserve attribution.

DDRAM is completely free in the IIgs core (`Apple-IIgs.sv:51`), so the mailbox drops
in with no contention. Slot hooks exist: `iigs.sv:319` hard-wires `slot_dout = 8'hFF`,
with `slot_ce`/`slot_internalrom_ce` decode already at `:1708`/`:1711`.

### 13. Printer emulation on the Linux side
**Status:** idea · **Effort:** its own project · **Lands in:** `Main_MiSTer`

Appletini proves the concept: its SSC is TX-only into a 2 KB FIFO, drained by the ARM
into an ImageWriter II PNG renderer (`ps_sources/frontend/imagewriter.c`,
`README_PRINTER.md`). None of that belongs in RTL.

The right shape is a Main_MiSTer-side printer daemon on the second serial port, shared
across all cores, with a family of emulations (Epson FX/ESC-P, ImageWriter, maybe HP
PCL) rendering to PNG/PDF in a spool directory. Worth writing up separately and
proposing upstream — every core with a serial port benefits.

---

## Explicitly not doing

| Item | Why |
|------|-----|
| NTSC/colour changes | `fb734d4` already moved this forward. The AppleWin 12-bit LUT stays on the shelf. |
| Disk mechanical sounds | The framework already provides drive sounds; Appletini's needs a 415 KB DDR sample blob for no gain. |
| Appletini video pipeline | Cycle-capture → DDR → ARM renderer is Zynq-specific. Its "PAL Accurate" mode is a software simulation of logic we already have in `timing_generator.vhd`. |
| Appletini clocking | Its 133 MHz fabric *oversamples* a real bus; our timing generator is already cycle-exact and the PLL ratio is exact. Nothing to gain. |
| Appletini mouse | Ours runs the real 6805 firmware + real card ROM and is more authentic. Use theirs only as a reference for status/IRQ ordering (`mouse_card.sv:216-227, 395-414`). |
| Appletini SSC | TX-only, status stuck at `$10`, no RX/IRQ — a strict subset of ours. |
| Uthernet II on this core | Bridges a physical W5100S chip; nothing to emulate. See item 12. |
| SuperSprite | Its RTL is only a register front end; tiles render on the ARM at ~20 Hz. Use a real TMS9918/F18A core if wanted. The register map at `supersprite_card.sv:407-421` is a usable spec. |
| Boot menu card, linear text overlay, ONE//e | Physical-card concerns; MiSTer already has an OSD and already is the machine. |

---

## Bugs found, not yet fixed

- **`.po` and `.do` images are served raw.** `Main_MiSTer/user_io.cpp:2155` routes
  only `.dsk` to `SD_TYPE_A2` nibblization (`.do` only for Oric), though `CONF_STR`
  advertises `"S0,NIBDSKDO PO ;"`. `.nib` works only because raw passthrough happens
  to be the right layout. *Fixed for free by item 4.*
- **Mockingboard mixer overflow** — `apple2_top.vhd:607-608`. See item 3.
- **`floppy_track.sv` does not clamp the track number** — `track` is 6 bits from
  `drive_ii.vhd:124` with no limit of 34, so tracks ≥35 read past the image.
- **`iigs_unmount` is never called on eject** — `Main_MiSTer/user_io.cpp:2198-2202`
  does `FileClose` + `c64_closeGCR` but not `iigs_unmount`, leaking up to 2 MB of
  `g_woz[index]` per eject.
- **IIgs WOZ write can corrupt the image** — unmapped-track writes overwrite the
  last-loaded track's blocks. Item 4, P3.
- `iigs_read`/`iigs_write` index `g_mode[disk]`/`g_woz[disk]` unbounded
  (`iigs_disk.cpp:271,294`); safe only because the dispatcher constrains `disk` to 0–3.
- `a2_writeNib2Dsk`'s `bytes_accumulated` (`dsk2nib_lib.cpp:418`) sums copied lengths
  instead of tracking a high-water mark, so out-of-order block arrival truncates the
  scan window.

## Housekeeping

- **`README.md` is out of date.** It predates the configurable slot 4/5 options and
  the mouse card, and its slot table lists the Mockingboard and Saturn at fixed slots.
- **This core has no simulation harness.** The IIgs core's `vsim/` (Verilator) is
  where timing-sensitive work should be prototyped. Standing goal: build an
  equivalent here.
- **`Apple-IIgs_MiSTer` is not published on GitHub** and the local `Main_MiSTer`
  checkout points at upstream with the `support/a2/` tree committed locally and no
  fork remote, though `alanswx/Main_MiSTer` exists. Sort both out before the WOZ
  work, since it lands in both.
- **Upstreamable now:** the `LED_USER` polarity fix (`c65cfe0`) is a one-line bug fix
  against MiSTer-devel.

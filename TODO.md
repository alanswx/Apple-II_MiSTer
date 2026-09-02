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

**Confirmed by mb-audit v1.60**, which does *not* need item 4 fixed — its `.po`
is already a raw ProDOS block image, so `cp mb-audit.po mb-audit.hdv` and boot it
from slot 7, a path that works.

| | pre-swap | Skibo VIA |
|---|---|---|
| slot 4 `$00`/`$80` | `?` `?` | `C0` `C0` |
| 6522-A | FAIL 50:06:00 exp `E0` act `60` | **passes** |
| 6522-B | FAIL 60:02:00 exp `E0` act `60` | **passes** |
| reaches | stops at the 6522 | AY891x test 21:13:00 |

The old VIA returned `'0' & irq_mask` for an IER read — bit 7 hardcoded low, where
a real 6522 always returns it set. Verified directly from BASIC at `$C40E`:

| | old VIA | Skibo VIA | correct |
|---|---|---|---|
| initial | 0 | 128 | 128 |
| after `$C0` | 64 | 192 | 192 |
| after `$40` | 0 | 128 | 128 |
| after `$E0` | 96 | 224 | 224 |

**New, separate finding:** mb-audit now fails in the AY-3-8913 at test 21:13:00,
`Expected:00 Actual:42`, with AY register 0 reading `$42`. That is `YM2149.sv`,
not the VIA — pre-existing, and only visible now that the 6522 no longer blocks
the run. Worth its own item.

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

### 4. ProDOS does not boot from floppy (any version)
**Status:** localised, root cause not proven · **Effort:** unknown

Not a ProDOS 2.4 bug, and not a ProDOS bug. **ProDOS cannot boot from the Disk II
floppy path on this core**, and never could — it reproduces on the pre-existing
`Apple-II_20260603.rbf`.

Symptom is always the same: the ProDOS banner prints, then the CPU BRKs into the
monitor at a low address with zero page all `00` — PC has run away into cleared
memory. `X=$C3 Y=$FA` recurs across images.

What the bisect established:

| test | result |
|---|---|
| ProDOS 2.4.1 (`ALECLOCK.dsk`), 2.4.3 (`mb-audit`) floppy | crash |
| **ProDOS 1.0.1** (`ProDos Users Disk`) floppy | **crash — so not 2.4-specific** |
| **ProDOS 1.1.1 from HDD** (`PRODOS_111_1.HDV`, `PR#7`) | **boots fully to the USER'S DISK menu** |
| **ProDOS 2.4 as raw `.nib`** (`prodostest1.nib`) | **crash — so not the HPS nibblizer** |
| DOS 3.3 floppy | boots fine |

So: ProDOS itself is fine, the HDD block path is fine, `dsk2nib_lib.cpp` is fine,
and the 65C02 is fine (the full opcode table was audited — every 65C02 opcode is
implemented; `$9E STZ abs,X` is present at `R65Cx2.vhd:470`, merely mislabelled
`9C` in its comment). The fault is in the core's Disk II read path.

It also fails *late*: the ProDOS kernel is many successful sectors' worth of
reading, and the banner proves it ran. The monitor's address pointer sat at
`$2C00` — the region a `.SYSTEM` file loads into before ProDOS jumps to it — so
the likely story is that the `.SYSTEM` load is corrupt and the jump lands in
cleared memory.

**Unproven hypothesis worth checking first.** Nothing stalls floppy *reads* while
the track buffer refills:

- `Apple-II.sv:287` — `.CPU_WAIT(cpu_wait_hdd /*| cpu_wait_fdd*/)`. The floppy
  wait is commented out and `cpu_wait_fdd` does not exist. The HDD path *does*
  stall the CPU, which is consistent with the HDD path working.
- `TRACK1_RAM_BUSY` is plumbed all the way to `drive_ii.vhd`, but it is used only
  at `:163` — `TRACK_WE <= not TRACK_BUSY` — which gates **writes**. A read during
  a refill is served from a buffer that is being overwritten.

Why DOS 3.3 would survive that and ProDOS not is the part still to explain; both
retry on a bad checksum, so this may not be the whole story. Also unexplained:
ProDOS reports MACHID `$B2` — Apple //e, 80-column present, but **64K rather than
128K**, so aux-memory detection is not being satisfied either.

Fixing this unblocks mb-audit, which ships as a ProDOS disk and is the proper
validator for item 2. **Note:** the Phase 1 WOZ port replaces this whole read
path (`drive_ii.vhd` + `floppy_track.sv`) and brings the IIgs engine's
ready/stall gating with it, so decide whether to fix this here or let the port
close it.

---

## Phase 1 — WOZ

### 4. Port the IIgs WOZ engine here
**Status:** IIgs side done, port not started · **Effort:** 2–3 weeks · **Lands in:** here, plus `Main_MiSTer`

The IIgs engine was fixed first, on `Apple-IIgs_MiSTer` branch `woz-fixes`
(pushed to `alanswx`, 2026-09-02). Read `vsim/HANDOFF_woz.md` there before
touching anything; `vsim/WOZ_FINDINGS.md` has the evidence behind every claim.
This section replaces the earlier six-defect plan, which turned out to be mostly
wrong.

**Where the IIgs engine stands.** Applesauce WOZ Test Images: 24 of 26 boot
(the two left, Hard Hat Mack and Stargate, fail on GSSquared's IIgs profiles
too). 202-disk corpus: clean against the previous head, +9. Three independent
references now agree on the 5.25" read semantics: AppleWin, GSSquared /
OpenEmulator, and Appletini's `disk2_card.sv` (AppleWin's model in HDL, on a
real //e bus).

**What was actually wrong, in the order it mattered:**

| Fix | What it was |
|-----|-------------|
| Sequencer semantics (`iwm_flux.v`, `sr525` path) | The data register was cleared when the CPU read it. Real hardware holds a completed byte until the next read pulse arrives, then restarts one cell later with that pulse as the leading 1; trailing zero bits extend the hold. Every "data separator" and "cell alignment" theory was this. Fixed First Math, DOS 3.2, ProDOS User's Disk, Border Zone A/B, all nine Newsroom revisions, and Halley Project. |
| Q6H re-framing (`$C08D`) | Was absent entirely; now loads the register with the write-protect sense and discards pulses while Q6 is high. Commando, Wings of Fury. |
| SmartPort mode bits gating 5.25" flux | IIgs-only. |
| `optimal_bit_timing` honoured | INFO byte 39 drives the bit cell; standard disks unchanged. |
| Weak-bit LFSR advances per fake bit; write-back guard for unmapped tracks | Both real; both small. |
| 1 MHz persists through the IWM motor-off holdover (`clock_divider.v`) | **IIgs-only.** A //e is always 1 MHz. Does not port. |

**The old six-defect table, corrected.** P0 "bit cell is 3.911 µs": a 56-clock
cell at 14.318 MHz is calibrated against the rotation constant, and 57.27
regressed 35 of 202 disks; keep 56. P0 "no data separator": two variants were
built and neither fixed anything; the fault was the sequencer. P1 "TMAP alias
forces a reload": does not reproduce (1 duplicate load in 66). P3 write-back:
the guard shipped; TRK bit-count / TMAP / CRC32 update and `WRIT` parsing are
still open. P2 weak bits: the LFSR fix shipped; the threshold change regressed
12 of 15 and the reference read-head model broke DOS 3.3 in the IIgs core —
**retry both only against Appletini's implementation** (`disk2_card.sv`
`woz_read_mode` branch: 4-bit head window with one-cell-delayed output, and a
30 % random 1 when the window is all zero, per the WOZ spec). Appletini's
author has given permission. P4 angular scaling across tracks: still open, no
evidence either way.

**Scope decisions for the //e port:**

- **Disk II controller only.** Every //e title expects the 16-sector P5A boot
  ROM and the P6 sequencer in slot 6; the DuoDisk uses the same card. No IWM.
- **5.25" only.** A //e has no 3.5" path without a Liron/SmartPort card; 800K
  `.po` images already work as a slot 7 block device. Flux-level 3.5" stays a
  IIgs feature.
- Two drives (SD slots 0 and 2), muxed by `drive2_select` (`disk_ii.vhd:71-73`).
- Writes carried over from the IIgs engine (dirty-track flush).
- Nothing from the speed holdover.

**What to move.** `woz_floppy_controller.sv` + `flux_drive.v` (same
`sd_lba/sd_rd/sd_buff_*` interface as `rtl/floppy_track.sv`, `IS_35_INCH=0`,
Quartus-proven), plus the `sr525` sequencer from `iwm_flux.v` (~100 lines:
QA hold / arm / restart, READLOAD on Q6H) driven straight from the Disk II
soft switches. This replaces `rtl/drive_ii.vhd`'s fixed 32 µs byte cadence
and `X"19FF"` wrap, and therefore also replaces the read path implicated in
Phase 0 item 4 (ProDOS floppy crash) — carry the IIgs engine's `DISK_READY`
gating so a read during a track refill stalls instead of serving a buffer
being overwritten.

**Order of work:**

1. `Main_MiSTer`: pass `.woz` through for this core. Today only `iigs_is_core()`
   (`support/a2/iigs_disk.cpp:40`) gets the passthrough; the 8-bit core's
   inline compare at `user_io.cpp:2132` nibblizes everything. Same change fixes
   raw `.po`/`.do` (Bugs below).
2. Extract the engine into a module with no IWM dependencies; simulate it in
   the **IIgs Verilator harness** (`../Apple-IIgs_MiSTer/vsim/`), which is the
   only simulator either core has. Gate: WOZ Test Images stay at 24/26.
3. Instantiate here in place of `drive_ii.vhd`/`floppy_track.sv`; Quartus fit
   (two track buffers ≈ 13 M10K; core is at 72 %).
4. Hardware gauntlet, in this order: DOS 3.3 System Master, ProDOS 2.4.3
   (closes Phase 0 item 4), First Math Adventures (latch lifespan), Wings of
   Fury (Q6H re-framing), Gumball (65 quarter-track entries + cross-track
   sync), Lode Runner (half-track), Frogger (**must boot on a //e**; it does not
   on a IIgs because the IIgs ROM's boot loop is 50 cycles between the track
   compare and the next poll), Beyond Zork side B (timing 28), The Newsroom
   (timing 34), Carmen Sandiego side B (fuzzy bits), Essex side 1 (write-back).

**Reference emulator.** GSSquared (`/home/alans/mister/gssquared-bench`,
branch `bench`) with `-p 3` — the enhanced //e with a 65C02, i.e. this core.
Not `-p 2` (6502) and not the IIgs profiles. It clocks the floppy off the CPU,
so it is blind to CPU-speed bugs; on a //e that does not matter.

**Corpus.** `Apple-IIgs_MiSTer/vsim/test_woz_batch.sh` over `verify_p0.txt`
(202 disks) at **2500 frames** — 1200 is too short for slow loaders. The
frozen reference from the finished IIgs work is `vsim/woz_ref/` there
(rebuilt 2026-09-02 at 2500 frames; the 2026-08-28 one is kept as
`woz_ref_20260828/`).

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

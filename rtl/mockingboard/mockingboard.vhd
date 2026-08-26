--
-- Mockingboard clone for the Apple II
-- Model A: two AY-3-8913 chips for six audio channels
--
-- Top file by W. Soltys <wsoltys@gmail.com>
-- 
-- loosely based on:
-- http://www.downloads.reactivemicro.com/Public/Apple%20II%20Items/Hardware/Mockingboard_v1/Mockingboard-v1a-Docs.pdf
-- http://www.applelogic.org/CarteBlancheIIProj6.html
--

library ieee ;
  use ieee.std_logic_1164.all ;
--  use ieee.std_logic_unsigned.all;
  use ieee.numeric_std.all;
  
  
entity MOCKINGBOARD is
  port (
    CLK_14M           : in std_logic;
    PHASE_ZERO        : in std_logic;
    PHASE_ZERO_R      : in std_logic;
    PHASE_ZERO_F      : in std_logic;
    I_ADDR            : in std_logic_vector(7 downto 0);
    I_DATA            : in std_logic_vector(7 downto 0);
    O_DATA            : out std_logic_vector(7 downto 0);
    
    OE                : out std_logic;

    I_RW_L            : in std_logic;
    O_IRQ_L           : out std_logic;
    O_NMI_L           : out std_logic;
    I_IOSEL_L         : in std_logic;
    I_RESET_L         : in std_logic;
    -- Power-on reset, distinct from the Apple RESET line above. The 6522's
    -- timer latches survive RESET but not power-on, which is what T1/T2 latch
    -- persistence across an Apple RESET depends on.
    I_POWER_RESET     : in std_logic;
    I_ENA_H           : in std_logic;     
    
    O_AUDIO_L         : out std_logic_vector(9 downto 0);
    O_AUDIO_R         : out std_logic_vector(9 downto 0)
    );
 end;
 
 
 architecture RTL of MOCKINGBOARD is
 
  signal o_pb_l           : std_logic_vector(7 downto 0);
  signal o_pb_r           : std_logic_vector(7 downto 0);
  
  signal i_psg_r          : std_logic_vector(7 downto 0);
  signal o_psg_r          : std_logic_vector(7 downto 0);
  signal i_psg_l          : std_logic_vector(7 downto 0);
  signal o_psg_l          : std_logic_vector(7 downto 0);

  signal o_psg_al         : std_logic_vector(7 downto 0);
  signal o_psg_bl         : std_logic_vector(7 downto 0);
  signal o_psg_cl         : std_logic_vector(7 downto 0);
  signal o_psg_ol         : std_logic_vector(9 downto 0);
  
  signal o_psg_ar         : std_logic_vector(7 downto 0);
  signal o_psg_br         : std_logic_vector(7 downto 0);
  signal o_psg_cr         : std_logic_vector(7 downto 0);
  signal o_psg_or         : std_logic_vector(9 downto 0);
  
  signal o_data_l          : std_logic_vector(7 downto 0);
  signal o_data_r          : std_logic_vector(7 downto 0);
  
  signal lirq             : std_logic;
  signal rirq             : std_logic;
  
  signal PSG_EN   : std_logic;
  signal via_sel_l, via_sel_r : std_logic;

  -- Thomas Skibo's 6522 (BSD-3), by way of Appletini One. Replaces the previous
  -- via6522.vhd, which carried a "do not use without written permission" notice
  -- and lacked the timer bus-value snapshot, the IFR underflow boundary and the
  -- reset/power_reset split that MB-Audit's 6522 tests check for.
  component via6522 is
    port (
      data_out               : out std_logic_vector(7 downto 0);
      data_in                : in  std_logic_vector(7 downto 0);
      addr                   : in  std_logic_vector(3 downto 0);
      strobe                 : in  std_logic;
      we                     : in  std_logic;

      irq                    : out std_logic;
      ifr_set_ext            : in  std_logic_vector(6 downto 0);
      ifr_clr_ext            : in  std_logic_vector(6 downto 0);

      porta_out              : out std_logic_vector(7 downto 0);
      porta_in               : in  std_logic_vector(7 downto 0);
      portb_out              : out std_logic_vector(7 downto 0);
      portb_in               : in  std_logic_vector(7 downto 0);
      portb_bus              : out std_logic_vector(7 downto 0);
      pcr_out                : out std_logic_vector(7 downto 0);
      ddrb_out               : out std_logic_vector(7 downto 0);

      ca1_in                 : in  std_logic;
      ca2_out                : out std_logic;
      ca2_in                 : in  std_logic;
      cb1_out                : out std_logic;
      cb1_in                 : in  std_logic;
      cb2_out                : out std_logic;
      cb2_in                 : in  std_logic;

      slow_clock             : in  std_logic;
      timer_read_extra_clock : in  std_logic;

      clk                    : in  std_logic;
      reset                  : in  std_logic;
      power_reset            : in  std_logic
      );
  end component;

  component YM2149
  port (
    CLK         : in  std_logic;
    CE          : in  std_logic;
    RESET       : in  std_logic;
    BDIR        : in  std_logic; -- Bus Direction (0 - read , 1 - write)
    BC          : in  std_logic; -- Bus control
    DI          : in  std_logic_vector(7 downto 0);
    DO          : out std_logic_vector(7 downto 0);
    CHANNEL_A   : out std_logic_vector(7 downto 0);
    CHANNEL_B   : out std_logic_vector(7 downto 0);
    CHANNEL_C   : out std_logic_vector(7 downto 0);

    SEL         : in  std_logic;
    MODE        : in  std_logic;

    ACTIVE      : out std_logic_vector(5 downto 0);

    IOA_in      : in  std_logic_vector(7 downto 0);
    IOA_out     : out std_logic_vector(7 downto 0);

    IOB_in      : in  std_logic_vector(7 downto 0);
    IOB_out     : out std_logic_vector(7 downto 0)
    );
  end component;

begin
  OE <= not I_IOSEL_L;

  O_DATA <= o_data_l when I_ADDR(7) = '0' else o_data_r;
  -- Both 6522s drive IRQ; NMI is never asserted.
  --
  -- Real boards could be jumpered with the second VIA on NMI, but nothing should
  -- take that option. Apple's own interrupt tech note warns that "the data and
  -- programs on the disk may be destroyed if an NMI occurs while the Apple is
  -- writing data to the disk" - DOS masks IRQ around disk I/O, and nothing can
  -- mask NMI. mb-audit agrees in practice: it installs an NMI handler purely to
  -- detect a VIA wired that way ("Don't use 6522 if it's connected to NMI") and
  -- skips T6522_E, T6522_F and T6522_17 when it sees one.
  --
  -- AppleWin ("Mockingboard generates IRQ on both 6522s"), Appletini
  -- (assert_nmi tied 0) and Clemens all route both VIAs to IRQ.
  O_IRQ_L <= not (lirq or rirq) or not I_ENA_H;
  O_NMI_L <= '1';

  PSG_EN <= PHASE_ZERO_F;

  -- Which VIA a cycle is addressing. A7 picks left ($Cn00) or right ($Cn80).
  via_sel_l <= (not I_IOSEL_L) and I_ENA_H and (not I_ADDR(7));
  via_sel_r <= (not I_IOSEL_L) and I_ENA_H and I_ADDR(7);

  -- slow_clock is the timer tick and must land EARLY in the Apple cycle;
  -- strobe serves the register access and must land LATE. The VIA relies on
  -- that ordering to hand a read the counter value from before this cycle's
  -- decrement, which is what MB-Audit T6522_3 checks. PHASE_ZERO_R is the last
  -- clock before PHI0 rises and PHASE_ZERO_F the last clock while it is high,
  -- so they give exactly that early/late pair.


-- Left Channel Combo
  m6522_left : component via6522
    port map (
      clk                    => CLK_14M,
      reset                  => not I_RESET_L,
      power_reset            => I_POWER_RESET,

      addr                   => I_ADDR(3 downto 0),
      data_in                => I_DATA,
      data_out               => o_data_l,
      we                     => not I_RW_L,
      strobe                 => via_sel_l and PHASE_ZERO_F,

      slow_clock             => PHASE_ZERO_R,
      timer_read_extra_clock => '0',

      irq                    => lirq,
      ifr_set_ext            => (others => '0'),
      ifr_clr_ext            => (others => '0'),

      porta_out              => i_psg_l,
      porta_in               => o_psg_l,
      portb_out              => o_pb_l,
      portb_in               => (others => '1'),
      portb_bus              => open,
      pcr_out                => open,
      ddrb_out               => open,

      ca1_in                 => '1',
      ca2_out                => open,
      ca2_in                 => '1',
      cb1_out                => open,
      cb1_in                 => '1',
      cb2_out                => open,
      cb2_in                 => '1'
      );

  psg_left: YM2149
  port map (
    CLK         => CLK_14M,
    CE          => PSG_EN and I_ENA_H,
    RESET       => not o_pb_l(2),
    BDIR        => o_pb_l(1),
    BC          => o_pb_l(0),
    DI          => i_psg_l,
    DO          => o_psg_l,
    CHANNEL_A   => o_psg_al,
    CHANNEL_B   => o_psg_bl,
    CHANNEL_C   => o_psg_cl,

    SEL         => '0',
    MODE        => '0',

    ACTIVE      => open,

    IOA_in      => (others => '0'),
    IOA_out     => open,

    IOB_in      => (others => '0'),
    IOB_out     => open
    );

  O_AUDIO_L <= std_logic_vector(unsigned("00" & o_psg_al) + unsigned("00" & o_psg_bl) + unsigned("00" & o_psg_cl));

-- Right Channel Combo
  m6522_right : component via6522
    port map (
      clk                    => CLK_14M,
      reset                  => not I_RESET_L,
      power_reset            => I_POWER_RESET,

      addr                   => I_ADDR(3 downto 0),
      data_in                => I_DATA,
      data_out               => o_data_r,
      we                     => not I_RW_L,
      strobe                 => via_sel_r and PHASE_ZERO_F,

      slow_clock             => PHASE_ZERO_R,
      timer_read_extra_clock => '0',

      irq                    => rirq,
      ifr_set_ext            => (others => '0'),
      ifr_clr_ext            => (others => '0'),

      porta_out              => i_psg_r,
      porta_in               => o_psg_r,
      portb_out              => o_pb_r,
      portb_in               => (others => '1'),
      portb_bus              => open,
      pcr_out                => open,
      ddrb_out               => open,

      ca1_in                 => '1',
      ca2_out                => open,
      ca2_in                 => '1',
      cb1_out                => open,
      cb1_in                 => '1',
      cb2_out                => open,
      cb2_in                 => '1'
      );

  psg_right: YM2149
  port map (
    CLK         => CLK_14M,
    CE          => PSG_EN and I_ENA_H,
    RESET       => not o_pb_r(2),
    BDIR        => o_pb_r(1),
    BC          => o_pb_r(0),
    DI          => i_psg_r,
    DO          => o_psg_r,
    CHANNEL_A   => o_psg_ar,
    CHANNEL_B   => o_psg_br,
    CHANNEL_C   => o_psg_cr,

    SEL         => '0',
    MODE        => '0',

    ACTIVE      => open,

    IOA_in      => (others => '0'),
    IOA_out     => open,

    IOB_in      => (others => '0'),
    IOB_out     => open
    );

  O_AUDIO_R <= std_logic_vector(unsigned("00" & o_psg_ar) + unsigned("00" & o_psg_br) + unsigned("00" & o_psg_cr));


end architecture RTL;
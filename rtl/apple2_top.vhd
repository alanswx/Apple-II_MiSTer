--
-- Apple II+ toplevel abstract
--
-- Copyright (c) 2014 W. Soltys <wsoltys@gmail.com>
--
-- This source file is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This source file is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity apple2_top is
port (
	CLK_14M        : in std_logic;
	CLK_50M        : in std_logic;


	reset_cold     : in std_logic;
	reset_warm     : in std_logic;
	soft_reset     : buffer std_logic;
	cpu_type       : in std_logic;
	CPU_WAIT       : in std_logic;

	-- main RAM
	ram_we         : out std_logic;
	ram_di         : out std_logic_vector(7 downto 0);
	ram_do         : in  std_logic_vector(15 downto 0);
	ram_addr       : out std_logic_vector(17 downto 0);
	ram_aux        : out std_logic;

	-- load replacement rom files	
	ioctl_addr    : in  std_logic_vector(24 downto 0);
	ioctl_data    : in  std_logic_vector(7 downto 0);
	ioctl_index   : in  std_logic_vector(7 downto 0);
	ioctl_download: in  std_logic;
	ioctl_wr      : in  std_logic;
	ioctl_wait	  : out std_logic;

	-- video output
	hsync          : out std_logic;
	vsync          : out std_logic;
	hblank         : out std_logic;
	vblank         : out std_logic;
	r              : out std_logic_vector(7 downto 0);
	g              : out std_logic_vector(7 downto 0);
	b              : out std_logic_vector(7 downto 0);
	SCREEN_MODE    : in  std_logic_vector(1 downto 0); -- 00: Color, 01: B&W, 10:Green, 11: Amber
	TEXT_COLOR     : in  std_logic; -- 1 = color processing for
	                                -- text lines in mixed modes
	
	video_switch   : out std_logic;
	palette_switch : out std_logic;
	COLOR_PALETTE  :  in std_logic_vector(1 downto 0); -- 00: Original (//e NTSC), 01: //gs, 02: AppleWin, 03: //c PAL
	GRAY_SEAM_FIX  : in std_logic;
	NTSC_VERTICAL_COMB : in std_logic;
	
    PALMODE        : in  std_logic := '0';       -- PAL/NTSC selection
    ROMSWITCH      : in std_logic;

	PS2_Key        : in  std_logic_vector(10 downto 0);
	joy            : in  std_logic_vector(5 downto 0);
	joy_an         : in  std_logic_vector(15 downto 0);

	
	-- Disk II (WOZ engine, rtl/disk_ii_woz.sv): SD block interface per drive
	FD_RESET        : in  std_logic;                     -- cold/OSD reset for the drives
	FD_SD_LBA0      : out std_logic_vector(31 downto 0);
	FD_SD_RD0       : out std_logic;
	FD_SD_WR0       : out std_logic;
	FD_SD_ACK0      : in  std_logic;
	FD_SD_BUFF_DIN0 : out std_logic_vector(7 downto 0);
	FD_SD_LBA1      : out std_logic_vector(31 downto 0);
	FD_SD_RD1       : out std_logic;
	FD_SD_WR1       : out std_logic;
	FD_SD_ACK1      : in  std_logic;
	FD_SD_BUFF_DIN1 : out std_logic_vector(7 downto 0);
	FD_SD_BUFF_ADDR : in  std_logic_vector(8 downto 0);
	FD_SD_BUFF_DOUT : in  std_logic_vector(7 downto 0);
	FD_SD_BUFF_WR   : in  std_logic;
	FD_IMG_MOUNTED0 : in  std_logic;
	FD_IMG_MOUNTED1 : in  std_logic;
	FD_IMG_READONLY : in  std_logic;
	FD_IMG_SIZE     : in  std_logic_vector(63 downto 0);

	D1_ACTIVE      : buffer std_logic;             -- Disk 1 motor on
	D2_ACTIVE      : buffer std_logic;             -- Disk 2 motor on
	
	D1_WP          : in std_logic;
	D2_WP          : in std_logic;

	DISK_ACT       : out std_logic;

	-- HDD control
	HDD_SECTOR     : out unsigned(15 downto 0);
	HDD_READ       : out std_logic;
	HDD_WRITE      : out std_logic;
	HDD_MOUNTED    : in  std_logic;
	HDD_PROTECT    : in  std_logic;
	HDD_RAM_ADDR   : in  unsigned(8 downto 0);
	HDD_RAM_DI     : in  unsigned(7 downto 0);
	HDD_RAM_DO     : out unsigned(7 downto 0);
	HDD_RAM_WE     : in  std_logic;

	AUDIO_L        : out std_logic_vector(9 downto 0);
	AUDIO_R        : out std_logic_vector(9 downto 0);
	TAPE_IN        : in  std_logic;

	UART_TXD       :out  std_logic;
	UART_RXD       :in  std_logic;
	UART_RTS       :out  std_logic;
	UART_CTS       :in  std_logic;
	UART_DTR       :out  std_logic;
	UART_DSR       :in  std_logic;
	RTC            :in  std_logic_vector(64 downto 0);
	NSC_ENABLE     :in  std_logic;
	
	
	mouse_strobe : in std_logic;
	mouse_x      : in signed(8 downto 0);
	mouse_y      : in signed(8 downto 0);
	mouse_button  : in std_logic;
	
	
	mouse_4_inslot  : in std_logic;
	mouse_5_inslot  : in std_logic;
	-- mocking board
	mb_4_inslot     : in std_logic;
	mb_5_inslot     : in std_logic;
	saturn_5_inslot : in std_logic	
);
end apple2_top;

architecture arch of apple2_top is
  component disk_ii_woz is
    port (
      CLK_14M       : in  std_logic;
      RESET         : in  std_logic;
      DD_RESET      : in  std_logic;
      PHASE_ZERO    : in  std_logic;
      IO_SELECT     : in  std_logic;
      DEVICE_SELECT : in  std_logic;
      WE            : in  std_logic;
      A             : in  std_logic_vector(15 downto 0);
      D_IN          : in  std_logic_vector(7 downto 0);
      D_OUT         : out std_logic_vector(7 downto 0);
      D1_ACTIVE     : out std_logic;
      D2_ACTIVE     : out std_logic;
      D1_WP         : in  std_logic;
      D2_WP         : in  std_logic;
      SD_LBA0       : out std_logic_vector(31 downto 0);
      SD_RD0        : out std_logic;
      SD_WR0        : out std_logic;
      SD_ACK0       : in  std_logic;
      SD_BUFF_DIN0  : out std_logic_vector(7 downto 0);
      SD_LBA1       : out std_logic_vector(31 downto 0);
      SD_RD1        : out std_logic;
      SD_WR1        : out std_logic;
      SD_ACK1       : in  std_logic;
      SD_BUFF_DIN1  : out std_logic_vector(7 downto 0);
      SD_BUFF_ADDR  : in  std_logic_vector(8 downto 0);
      SD_BUFF_DOUT  : in  std_logic_vector(7 downto 0);
      SD_BUFF_WR    : in  std_logic;
      IMG_MOUNTED0  : in  std_logic;
      IMG_MOUNTED1  : in  std_logic;
      IMG_READONLY  : in  std_logic;
      IMG_SIZE      : in  std_logic_vector(63 downto 0)
    );
  end component;

  component superserial is
    port (
	CLK_14M  	: in std_logic;
	CLK_2M  	: in std_logic;
	CLK_50M		: in std_logic;
	PH_2    	: in std_logic;
	IO_SELECT_N	: in std_logic;
	DEVICE_SELECT_N : in std_logic;
	IO_STROBE_N  	: in std_logic;
	ADDRESS     	: std_logic_vector(15 downto 0);
	RW_N        	: in std_logic;
	RESET      	: in std_logic;
	DATA_IN    	: in std_logic_vector(7 downto 0);
	DATA_OUT   	: out std_logic_vector(7 downto 0);
	ROM_EN 		: out std_logic;
	UART_CTS 	: in std_logic;
	UART_RTS 	: out std_logic;
	UART_RXD 	: in std_logic;
	UART_TXD 	: out std_logic;
	UART_DTR 	: out std_logic;
	UART_DSR 	: in std_logic;
	IRQ_N 		: out std_logic);


  end component;
  
  component speaker_filter is
    generic (
        TAPS            : integer := 256);
    port (
        clk             : in std_logic;
        reset           : in std_logic;
        speaker         : in std_logic;
        level           : out std_logic_vector(7 downto 0));
  end component;

  component no_slot_clock is
    generic (
        CLK_FREQ        : integer := 14318181);
    port (
        clk             : in std_logic;
        reset           : in std_logic;
        enable          : in std_logic;
        cs              : in std_logic;
        addr            : in std_logic_vector(15 downto 0);
        rw              : in std_logic;
        cycle_en        : in std_logic;
        RTC             : in std_logic_vector(64 downto 0);
        data_en         : out std_logic;
        data_out        : out std_logic_vector(7 downto 0));
  end component;


  signal CLK_2M, CLK_2M_D, PHASE_ZERO, PHASE_ZERO_R, PHASE_ZERO_F : std_logic;
  signal IO_SELECT, DEVICE_SELECT : std_logic_vector(7 downto 0);
  signal IO_STROBE : std_logic;

  signal ADDR : unsigned(15 downto 0);
  signal D, PD: unsigned(7 downto 0);
  signal DISK_DO, HDD_DO : unsigned(7 downto 0);
  signal disk_do_slv : std_logic_vector(7 downto 0);
  signal PSG_4_DO, PSG_5_DO : unsigned(7 downto 0);
  signal cpu_we : std_logic;
  signal psg_4_irq_n, psg_4_nmi_n , psg_4_oe: std_logic;
  signal psg_5_irq_n, psg_5_nmi_n , psg_5_oe: std_logic;
  signal ssc_irq_n: std_logic;

  signal SSC_ROM_EN : std_logic;
  signal SSC_DO     : unsigned(7 downto 0);

  signal CLOCK_DO   : unsigned(7 downto 0);
  signal CLOCK_OE   : std_logic;
  signal NSC_CS     : std_logic;

  signal MOUSE_4_DO:  unsigned(7 downto 0);
  signal MOUSE_4_OE: std_logic;
  signal mouse_4_irq_n: std_logic;
  signal MOUSE_5_DO:  unsigned(7 downto 0);
  signal MOUSE_5_OE: std_logic;
  signal mouse_5_irq_n: std_logic;
  
  signal we_ram : std_logic;
  signal VIDEO, HBL, VBL : std_logic;
  signal COLOR_LINE : std_logic;
  signal COLOR_LINE_CONTROL : std_logic;
  signal TEXT_MODE : std_logic;
  signal GAMEPORT : std_logic_vector(7 downto 0);

  signal K : unsigned(7 downto 0);
  signal read_key : std_logic;
  signal akd : std_logic;

  signal flash_clk : unsigned(22 downto 0) := (others => '0');
  signal power_on_reset : std_logic := '1';
  signal reset : std_logic;


  signal a_ram: unsigned(17 downto 0);
  
  signal psg_4_audio_l : unsigned(9 downto 0);
  signal psg_4_audio_r : unsigned(9 downto 0);

  signal psg_5_audio_l : unsigned(9 downto 0);
  signal psg_5_audio_r : unsigned(9 downto 0);

  
  signal audio       : unsigned(9 downto 0);
  signal speaker_raw : std_logic;
  signal spk_level   : std_logic_vector(7 downto 0);
  signal audio_sum_l : unsigned(11 downto 0);
  signal audio_sum_r : unsigned(11 downto 0);

  signal joyx       : std_logic;
  signal joyy       : std_logic;
  signal pdl_strobe : std_logic;
  signal open_apple : std_logic;
  signal closed_apple : std_logic;
begin


  -- In the Apple ][, this was a 555 timer
  power_on : process(CLK_14M)
  begin
    if rising_edge(CLK_14M) then
      reset <= reset_warm or power_on_reset;

      if reset_cold = '1' or soft_reset ='1'then
        power_on_reset <= '1';
        flash_clk <= (others=>'0');
      else
		  if flash_clk(22) = '1' then
          power_on_reset <= '0';
			end if;
			 
        flash_clk <= flash_clk + 1;
      end if;
    end if;
  end process;		
  
  
  -- Paddle buttons
  -- GAMEPORT input bits:
  --  7    6    5    4    3   2   1    0
  -- pdl3 pdl2 pdl1 pdlCLOCK_OE0 pb3 pb2 pb1 casette
  GAMEPORT <=  "00" & joyy & joyx & "0" & (joy(5) or closed_apple)& (joy(4) or open_apple) & TAPE_IN;

  process(CLK_14M, pdl_strobe)
    variable cx, cy : integer range -100 to 5800 := 0;
  begin
    if rising_edge(CLK_14M) then
     CLK_2M_D <= CLK_2M;
     if CLK_2M_D = '0' and CLK_2M = '1' then
      if cx > 0 then
        cx := cx -1;
        joyx <= '1';
      else
        joyx <= '0';
      end if;
      if cy > 0 then
        cy := cy -1;
        joyy <= '1';
      else
        joyy <= '0';
      end if;
      if pdl_strobe = '1' then
        cx := 2800+(22*to_integer(signed(joy_an(15 downto 8))));
        cy := 2800+(22*to_integer(signed(joy_an(7 downto 0)))); -- max 5650
        if cx < 0 then
          cx := 0;
        elsif cx >= 5590 then
          cx := 5650;
        end if;
        if cy < 0 then
          cy := 0;
        elsif cy >= 5590 then
          cy := 5650;
        end if;
      end if;
     end if;
    end if;
  end process;

  COLOR_LINE_CONTROL <= (COLOR_LINE or (TEXT_COLOR and not TEXT_MODE)) and not (SCREEN_MODE(1) or SCREEN_MODE(0));  -- Color or B&W mode

  -- Simulate power up on cold reset to go to the disk boot routine
  ram_we   <= we_ram when reset_cold = '0' else '1';
  ram_addr <= std_logic_vector(a_ram) when reset_cold = '0' else std_logic_vector(to_unsigned(1012,ram_addr'length)); -- $3F4
  ram_di   <= std_logic_vector(D) when reset_cold = '0' else "00000000";

  PD <= PSG_4_DO when psg_4_oe = '1'  else
        PSG_5_DO when psg_5_oe = '1'  else
        MOUSE_4_DO when MOUSE_4_OE = '1' else
        MOUSE_5_DO when MOUSE_5_OE = '1' else
        CLOCK_DO when CLOCK_OE = '1' else
        HDD_DO when IO_SELECT(7) = '1' or DEVICE_SELECT(7) = '1' else
        SSC_DO when IO_SELECT(2) = '1' or DEVICE_SELECT(2) = '1' or SSC_ROM_EN ='1' else 
        DISK_DO;

  core : entity work.apple2 port map (
    CLK_14M        => CLK_14M,
    CLK_2M         => CLK_2M,
    CPU_WAIT       => CPU_WAIT,
    PHASE_ZERO     => PHASE_ZERO,
    PHASE_ZERO_R   => PHASE_ZERO_R,
    PHASE_ZERO_F   => PHASE_ZERO_F,
    FLASH_CLK      => flash_clk(22),
    reset          => reset,
    cpu            => cpu_type,
    ADDR           => ADDR,
    ram_addr       => a_ram,
    D              => D,
    ram_do         => unsigned(ram_do),
    aux            => ram_aux,
    PD             => PD,
    CPU_WE         => cpu_we,
    IRQ_N          => psg_4_irq_n and psg_5_irq_n and ssc_irq_n and mouse_4_irq_n and mouse_5_irq_n,
    NMI_N          => psg_4_nmi_n and psg_5_nmi_n,
    ram_we         => we_ram,
    VIDEO          => VIDEO,
    PALMODE        => PALMODE,
    ROMSWITCH      => ROMSWITCH,
    COLOR_LINE     => COLOR_LINE,
    TEXT_MODE      => TEXT_MODE,
    HBL            => HBL,
    VBL            => VBL,
    K              => K,
    read_key       => read_key,
    AKD            => akd,
    AN             => open,
    GAMEPORT       => GAMEPORT,
    PDL_strobe     => pdl_strobe,
    IO_SELECT      => IO_SELECT,
    DEVICE_SELECT  => DEVICE_SELECT,
    IO_STROBE      => IO_STROBE,

    ioctl_addr     => ioctl_addr,
    ioctl_data     => ioctl_data,
    ioctl_index    => ioctl_index,
    ioctl_download => ioctl_download,
    ioctl_wr       => ioctl_wr,
	 
    saturn_5_inslot=> saturn_5_inslot,
	 
    speaker        => speaker_raw
    );

  tv : entity work.vga_controller port map (
    CLK_14M    => CLK_14M,
    VIDEO      => VIDEO,
    COLOR_LINE => COLOR_LINE_CONTROL,
    SCREEN_MODE => SCREEN_MODE,
    COLOR_PALETTE => COLOR_PALETTE,
    GRAY_SEAM_FIX => GRAY_SEAM_FIX,
    NTSC_VERTICAL_COMB => NTSC_VERTICAL_COMB,
    HBL        => HBL,
    VBL        => VBL,
    VGA_HS     => hsync,
    VGA_VS     => vsync,
    VGA_HBL    => hblank,
    VGA_VBL    => vblank,
    std_logic_vector(VGA_R) => r,
    std_logic_vector(VGA_G) => g,
    std_logic_vector(VGA_B) => b,
    -- for custom palette loader
    ioctl_addr     => ioctl_addr,
    ioctl_data     => ioctl_data,
    ioctl_wr       => ioctl_wr,
	 ioctl_index    => ioctl_index,
	 ioctl_download => ioctl_download,
	 ioctl_wait => ioctl_wait
    );

  keyboard : entity work.keyboard port map (
    PS2_Key  => PS2_Key,
    CLK_14M  => CLK_14M,
	 reset    => reset_cold, -- use reset_cold, not reset so we keep the
	                         -- keyboard state machine running for key up 
									 -- events during / after reset
    reads    => read_key,
    K        => K,
    akd      => akd,
    open_apple => open_apple,
    closed_apple => closed_apple,
    soft_reset => soft_reset,
    video_toggle => video_switch,
	palette_toggle => palette_switch
    );

	 
  DISK_ACT <= D1_ACTIVE or D2_ACTIVE;

  disk_do_u : disk_ii_woz port map (
    CLK_14M        => CLK_14M,
    RESET          => reset,
    DD_RESET       => FD_RESET,
    PHASE_ZERO     => PHASE_ZERO,
    IO_SELECT      => IO_SELECT(6),
    DEVICE_SELECT  => DEVICE_SELECT(6),
    WE             => cpu_we,
    A              => std_logic_vector(ADDR),
    D_IN           => std_logic_vector(D),
    D_OUT          => disk_do_slv,
    D1_ACTIVE      => D1_ACTIVE,
    D2_ACTIVE      => D2_ACTIVE,
    D1_WP          => D1_WP,
    D2_WP          => D2_WP,
    SD_LBA0        => FD_SD_LBA0,
    SD_RD0         => FD_SD_RD0,
    SD_WR0         => FD_SD_WR0,
    SD_ACK0        => FD_SD_ACK0,
    SD_BUFF_DIN0   => FD_SD_BUFF_DIN0,
    SD_LBA1        => FD_SD_LBA1,
    SD_RD1         => FD_SD_RD1,
    SD_WR1         => FD_SD_WR1,
    SD_ACK1        => FD_SD_ACK1,
    SD_BUFF_DIN1   => FD_SD_BUFF_DIN1,
    SD_BUFF_ADDR   => FD_SD_BUFF_ADDR,
    SD_BUFF_DOUT   => FD_SD_BUFF_DOUT,
    SD_BUFF_WR     => FD_SD_BUFF_WR,
    IMG_MOUNTED0   => FD_IMG_MOUNTED0,
    IMG_MOUNTED1   => FD_IMG_MOUNTED1,
    IMG_READONLY   => FD_IMG_READONLY,
    IMG_SIZE       => FD_IMG_SIZE
    );
  DISK_DO <= unsigned(disk_do_slv);
	 
  hdd : entity work.hdd port map (
    CLK_14M        => CLK_14M,
    IO_SELECT      => IO_SELECT(7),
    DEVICE_SELECT  => DEVICE_SELECT(7),
    RESET          => reset,
    A              => ADDR,
    RD             => not cpu_we,
    D_IN           => D,
    D_OUT          => HDD_DO,
    sector         => HDD_SECTOR,
    hdd_read       => HDD_READ,
    hdd_write      => HDD_WRITE,
    hdd_mounted    => HDD_MOUNTED,
    hdd_protect    => HDD_PROTECT,
    ram_addr       => HDD_RAM_ADDR,
    ram_di         => HDD_RAM_DI,
    ram_do         => HDD_RAM_DO,
    ram_we         => HDD_RAM_WE
    );

  mb_4 : work.mockingboard
    port map (
      CLK_14M    => CLK_14M,
      PHASE_ZERO => PHASE_ZERO,
      PHASE_ZERO_R => PHASE_ZERO_R,
      PHASE_ZERO_F => PHASE_ZERO_F,
      I_RESET_L => not reset,
      I_POWER_RESET => power_on_reset,
      I_ENA_H   => mb_4_inslot,

      I_ADDR    => std_logic_vector(ADDR)(7 downto 0),
      I_DATA    => std_logic_vector(D),
      unsigned(O_DATA) => PSG_4_DO,
      I_RW_L    => not cpu_we,
      I_IOSEL_L => not IO_SELECT(4) or NOT mb_4_inslot,
		OE        => psg_4_oe,
		
      O_IRQ_L   => psg_4_irq_n,
      O_NMI_L   => psg_4_nmi_n,
      unsigned(O_AUDIO_L) => psg_4_audio_l,
      unsigned(O_AUDIO_R) => psg_4_audio_r
      );
  mb_5 : work.mockingboard
    port map (
      CLK_14M    => CLK_14M,
      PHASE_ZERO => PHASE_ZERO,
      PHASE_ZERO_R => PHASE_ZERO_R,
      PHASE_ZERO_F => PHASE_ZERO_F,
      I_RESET_L => not reset,
      I_POWER_RESET => power_on_reset,
      I_ENA_H   => mb_5_inslot,

      I_ADDR    => std_logic_vector(ADDR)(7 downto 0),
      I_DATA    => std_logic_vector(D),
      unsigned(O_DATA) => PSG_5_DO,
      I_RW_L    => not cpu_we,
      I_IOSEL_L => not IO_SELECT(5) or NOT mb_5_inslot,
		OE        => psg_5_oe,
		
      O_IRQ_L   => psg_5_irq_n,
      O_NMI_L   => psg_5_nmi_n,
      unsigned(O_AUDIO_L) => psg_5_audio_l,
      unsigned(O_AUDIO_R) => psg_5_audio_r
      );

   ssc : component superserial
     port map (
	CLK_50M 	=> CLK_50M,
	CLK_14M     	=> CLK_14M,
	CLK_2M      	=> CLK_2M,
	PH_2        	=> PHASE_ZERO,
	IO_SELECT_N 	=> not IO_SELECT(2),
	DEVICE_SELECT_N => not DEVICE_SELECT(2),
	IO_STROBE_N  	=> NOT IO_STROBE,
	ADDRESS     	=> std_logic_vector(ADDR),
	RW_N        	=> not cpu_we,
	RESET       	=> reset,
	DATA_IN     	=> std_logic_vector(D),
	unsigned(DATA_OUT) => SSC_DO,
	ROM_EN 		=> SSC_ROM_EN,
	UART_CTS 	=> UART_CTS,
	UART_RTS 	=> UART_RTS,
	UART_RXD 	=> UART_RXD,
	UART_TXD 	=> UART_TXD,
	UART_DTR 	=> UART_DTR,
	UART_DSR 	=> UART_DSR,
	IRQ_N 		=> ssc_irq_n
	);

	


 mouse_4 : entity work.applemouse 
 port map (
    CLK_14M        => CLK_14M,
    CLK_2M         => CLK_2M,
    PHASE_ZERO     => PHASE_ZERO,
    IO_SELECT      => IO_SELECT(4) and mouse_4_inslot,
    IO_STROBE      => IO_STROBE,
    DEVICE_SELECT  => DEVICE_SELECT(4) and mouse_4_inslot,
    RESET          => reset,
    A              => ADDR,
    RNW            => not cpu_we,
    D_IN           => D,
    D_OUT          => MOUSE_4_DO,
    OE             => MOUSE_4_OE,
    IRQ_N          => MOUSE_4_IRQ_N,

    STROBE         => mouse_strobe,
    X              => mouse_x,
    Y              => mouse_y,
    BUTTON         => mouse_button
  );
 mouse_5 : entity work.applemouse 
 port map (
    CLK_14M        => CLK_14M,
    CLK_2M         => CLK_2M,
    PHASE_ZERO     => PHASE_ZERO,
    IO_SELECT      => IO_SELECT(5) and mouse_5_inslot,
    IO_STROBE      => IO_STROBE,
    DEVICE_SELECT  => DEVICE_SELECT(5) and mouse_5_inslot,
    RESET          => reset,
    A              => ADDR,
    RNW            => not cpu_we,
    D_IN           => D,
    D_OUT          => MOUSE_5_DO,
    OE             => MOUSE_5_OE,
    IRQ_N          => MOUSE_5_IRQ_N,

    STROBE         => mouse_strobe,
    X              => mouse_x,
    Y              => mouse_y,
    BUTTON         => mouse_button
  );
	
	
  -- No-Slot Clock (DS1216E).
  --
  -- It hides underneath peripheral ROM space and stays invisible until it
  -- sees its 64-bit unlock pattern, so it occupies no slot. Watching every
  -- slot ROM page plus the $C800 window gives the stock drivers the best
  -- chance of finding it wherever they probe.
  --
  -- The $C800 window is deliberately NOT snooped. Appletini's no_slot_clock.sv
  -- only watches it when it belongs to a slot the clock is configured for
  -- (its c8_select/slot_mask test); we have no equivalent here, and raw
  -- IO_STROBE covers all of $C800-$CFFF. Measured on hardware, that picks up a
  -- constant stream of firmware reads at $CFA0/$CFA1, every one of which shifts
  -- a bit and derails the unlock. Slot ROM pages alone are clean.
  NSC_CS <= IO_SELECT(1) or IO_SELECT(2) or IO_SELECT(3) or IO_SELECT(4) or
            IO_SELECT(5) or IO_SELECT(6) or IO_SELECT(7);

  clock : component no_slot_clock
  generic map (
    CLK_FREQ        => 14318181)
  port map (
    clk             => CLK_14M,
    reset           => reset,
    enable          => NSC_ENABLE,
    cs              => NSC_CS,
    addr            => std_logic_vector(ADDR),
    rw              => not cpu_we,
    cycle_en        => PHASE_ZERO_R,
    RTC             => RTC,
    data_en         => CLOCK_OE,
    unsigned(data_out) => CLOCK_DO
  );



  -- Band-limit the speaker before it reaches the 48 kHz sampler.
  --
  -- The raw $C030 flip-flop used to go straight into audio(7). Measured on
  -- hardware over HDMI capture: an 11-cycle toggle loop produces a 46.4 kHz
  -- square wave, and what came out was a 1614 Hz tone - exactly 48000-46386,
  -- a frequency present nowhere in the source. The framework's default IIR
  -- runs before the 48 kHz decimation but is far too gentle to stop it.
  spk : component speaker_filter
  generic map (
    TAPS    => 256)
  port map (
    clk     => CLK_14M,
    reset   => reset,
    speaker => speaker_raw,
    level   => spk_level);

  audio <= resize(unsigned(spk_level), 10);
  -- Sum in 12 bits, then clamp instead of letting it wrap.
  --
  -- Each Mockingboard peaks at 765 - three 8-bit PSG channels summed in
  -- mockingboard.vhd:171 - and the speaker adds 128, so two boards plus the
  -- speaker reach 1658. That does not fit in 10 bits, and the old unclamped
  -- 10-bit add wrapped it to 634: a full-scale discontinuity on exactly the
  -- loudest passages, which is far worse than clipping.
  --
  -- Clamping rather than rescaling is deliberate. The common case - one
  -- Mockingboard plus the speaker, 893 - already fits, so the gain and the
  -- perceived loudness are unchanged; only the rare both-boards-flat-out peak
  -- is affected, and there it clips cleanly.
  audio_sum_l <= resize(psg_4_audio_l, 12) + resize(psg_5_audio_l, 12) + resize(audio, 12);
  audio_sum_r <= resize(psg_4_audio_r, 12) + resize(psg_5_audio_r, 12) + resize(audio, 12);

  AUDIO_R <= std_logic_vector(audio_sum_r(9 downto 0)) when audio_sum_r < 1024
             else (others => '1');
  AUDIO_L <= std_logic_vector(audio_sum_l(9 downto 0)) when audio_sum_l < 1024
             else (others => '1');

end arch;

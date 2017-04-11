--------------------------------------------------------------------------------
--| @file cpu.vhd
--| @brief This contains the CPU/main memory instances
--|
--| @author     Richard James Howe.
--| @copyright  Copyright 2013 Richard James Howe.
--| @license    MIT
--| @email      howe.r.j.89@gmail.com
--------------------------------------------------------------------------------

library ieee,work;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util.n_bits;

entity cpu is
	generic(number_of_interrupts: positive := 8);
	port(
		-- synthesis translate_off
		debug_pc:         out std_logic_vector(12 downto 0);
		debug_insn:       out std_logic_vector(15 downto 0);
		debug_dwe:    out std_logic := '0';
		debug_din:    out std_logic_vector(15 downto 0);
		debug_dout:   out std_logic_vector(15 downto 0);
		debug_daddr:  out std_logic_vector(12 downto 0);
		-- synthesis translate_on

		clk:        in   std_logic;
		rst:        in   std_logic;

		-- CPU External interface, I/O
		cpu_wait:   in   std_logic; -- Halts the CPU
		cpu_wr:     out  std_logic; -- I/O Write enable
		cpu_re:     out  std_logic; -- hardware *READS* can have side effects
		cpu_din:    in   std_logic_vector(15 downto 0);
		cpu_dout:   out  std_logic_vector(15 downto 0):= (others => 'X');
		cpu_daddr:  out  std_logic_vector(15 downto 0):= (others => 'X');
		-- Interrupts
		cpu_irq:    in   std_logic;
		cpu_irc:    in   std_logic_vector(number_of_interrupts - 1 downto 0));
end;

architecture behav of cpu is
	constant interrupt_address_length: natural  := n_bits(number_of_interrupts);
	constant addr_length:              positive := 13;
	constant data_length:              positive := 16;
	constant file_name:                string   := "h2.hex";
	constant file_type:                string   := "hex";

	signal pc:    std_logic_vector(addr_length - 1 downto 0):= (others => '0'); -- Program counter
	signal insn:  std_logic_vector(data_length - 1 downto 0):= (others => '0'); -- Instruction issued by program counter
	signal dwe:   std_logic := '0'; -- Write enable
	signal dre:   std_logic := '0'; -- Read enable
	signal din:   std_logic_vector(data_length - 1 downto 0):= (others => '0');
	signal dout:  std_logic_vector(data_length - 1 downto 0):= (others => '0');
	signal daddr: std_logic_vector(addr_length - 1 downto 0):= (others => '0');

	signal h2_irq:       std_logic := '0';
	signal h2_irq_addr:  std_logic_vector(interrupt_address_length - 1 downto 0) := (others=>'0');
begin
	-- synthesis translate_off
	debug_pc          <= pc;
	debug_insn        <= insn;
	debug_dwe     <= dwe;
	debug_din     <= din;
	debug_dout    <= dout;
	debug_daddr   <= daddr;
	-- synthesis translate_on

	irqh_0: entity work.irqh
	generic map(number_of_interrupts => number_of_interrupts)
	port map(
		clk    => clk,
		rst    => rst,

		irq_i  => cpu_irq,
		irc_i  => cpu_irc,

		irq_o  => h2_irq,
		addr_o => h2_irq_addr);

	h2_0: entity work.h2 -- The actual CPU instance (H2)
	generic map(interrupt_address_length => interrupt_address_length)
	port map(
		clk       =>    clk,
		rst       =>    rst,

		-- External interface with the 'outside world'
		cpu_wait  =>  cpu_wait,
		io_wr     =>  cpu_wr,
		io_re     =>  cpu_re,
		io_din    =>  cpu_din,
		io_dout   =>  cpu_dout,
		io_daddr  =>  cpu_daddr,

		irq       =>  h2_irq,
		irq_addr  =>  h2_irq_addr,

		-- Instruction and instruction address to CPU
		pco       =>    pc,
		insn      =>    insn,
		-- Fetch/Store
		dwe       =>    dwe,
		dre       =>    dre,
		din       =>    din,
		dout      =>    dout,
		daddr     =>    daddr);
		
	mem_h2_0: entity work.memory
	generic map(
		addr_length   => addr_length,
		data_length   => data_length,
		file_name     => file_name,
		file_type     => file_type)
	port map(
		-- Port A, Read only, CPU instruction/address
		a_clk   =>    clk,
		a_dwe   =>    '0',
		a_dre   =>    '1',
		a_addr  =>    pc,
		a_din   =>    (others => '0'),
		a_dout  =>    insn,
		-- Port B, Read/Write controlled by CPU instructions
		b_clk   =>    clk,
		b_dwe   =>    dwe,
		b_dre   =>    dre,
		b_addr  =>    daddr,
		b_din   =>    dout,
		b_dout  =>    din);

end architecture;

-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2023 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Ondřej Hruboš <xhrubo01 AT stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
	port (
		CLK        : in std_logic;                      -- hodinovy signal
		RESET      : in std_logic;                      -- asynchronni reset procesoru
		EN         : in std_logic;                      -- povoleni cinnosti procesoru

		-- synchronni pamet RAM
		DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
		DATA_WDATA : out std_logic_vector(7 downto 0);  -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
		DATA_RDATA : in std_logic_vector(7 downto 0);   -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
		DATA_RDWR  : out std_logic;                     -- cteni (0) / zapis (1)
		DATA_EN    : out std_logic;                     -- povoleni cinnosti

		-- vstupni port
		IN_DATA    : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
		IN_VLD     : in std_logic;                      -- data platna
		IN_REQ     : out std_logic;                     -- pozadavek na vstup data

		-- vystupni port
		OUT_DATA   : out std_logic_vector(7 downto 0);  -- zapisovana data
		OUT_BUSY   : in std_logic;                      -- LCD je zaneprazdnen (1), nelze zapisovat
		OUT_WE     : out std_logic;                     -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

		-- stavove signaly
		READY      : out std_logic;                     -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
		DONE       : out std_logic                      -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
	);
end cpu;

-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is
	-- -----------
	-- FSM States
	-- -----------
	type fsm_state is(
	state_init, state_decode_init, state_fetch_init,                        -- stavy pro nastavení pointeru na data
	state_begin, state_fetch, state_decode, state_end,                      -- stavy pro řízení programu
	state_print_prepare, state_print, state_load_prepare, state_load,       -- stavy pro výpis a zápis do paměti
	state_ptr_inc, state_ptr_dec,                                           -- stavy pro pohyb pointeru
	state_val_inc, state_val_inc_write, state_val_dec, state_val_dec_write, -- stavy pro přičtení a odečtení hodnoty v paměti
	state_while_start, state_while_start_compare, state_while_jmp_end,      -- stavy pro začátek cyklu
	state_while_end, state_while_end_compare, state_while_jmp_start,        -- stavy pro konec cyklu
	state_while_break, state_while_break_jmp_end                            -- stavy pro přerušení cyklu
	);

	-- --------
	-- SIGNALS
	-- --------

	-- current and next state signals
	signal state               : fsm_state;
	signal state_next          : fsm_state;

	-- program_counter signals
	signal program_counter     : std_logic_vector(12 downto 0);
	signal program_counter_inc : std_logic;
	signal program_counter_dec : std_logic;

	-- pointer signals
	signal pointer             : std_logic_vector(12 downto 0);
	signal pointer_inc         : std_logic;
	signal pointer_dec         : std_logic;

	-- mux signals
	signal mux1_select         : std_logic;
	signal mux2_select         : std_logic_vector(1 downto 0);
begin
	-- pri tvorbe kodu reflektujte rady ze cviceni INP, zejmena mejte na pameti, ze 
	--   - nelze z vice procesu ovladat stejny signal,
	--   - je vhodne mit jeden proces pro popis jedne hardwarove komponenty, protoze pak
	--      - u synchronnich komponent obsahuje sensitivity list pouze CLK a RESET a 
	--      - u kombinacnich komponent obsahuje sensitivity list vsechny ctene signaly. 

	-- ----------------
	-- PROGRAM COUNTER
	-- ----------------
	program_counter_register : process (program_counter_inc, program_counter_dec, CLK, RESET)
	begin
		if (RESET = '1') then
			program_counter <= "0000000000000";
		elsif (CLK'event) and (CLK = '1') then
			if (program_counter_inc = '1') then
				program_counter <= program_counter + 1;
			elsif (program_counter_dec = '1') then
				program_counter <= program_counter - 1;
			end if;
		end if;
	end process;

	-- --------
	-- POINTER
	-- --------
	pointer_register : process (pointer_inc, pointer_dec, CLK, RESET)
	begin
		if (RESET = '1') then
			pointer <= "0000000000000";
		elsif (CLK'event) and (CLK = '1') then
			if (pointer_inc = '1') then
				pointer <= pointer + 1;
			elsif (pointer_dec = '1') then
				pointer <= pointer - 1;
			end if;
		end if;
	end process;

	-- ------
	-- MUX 1
	-- ------
	mux1 : process (pointer, program_counter, mux1_select)
	begin
		case mux1_select is
			when '0'    => DATA_ADDR <= pointer;
			when '1'    => DATA_ADDR <= program_counter;
			when others => null;
		end case;
	end process;

	-- ------
	-- MUX 2
	-- ------
	mux2 : process (IN_DATA, DATA_RDATA, mux2_select)
	begin
		case mux2_select is
			when "00"   => DATA_WDATA <= IN_DATA;
			when "01"   => DATA_WDATA <= DATA_RDATA - 1;
			when "10"   => DATA_WDATA <= DATA_RDATA + 1;
			when others => null;
		end case;
	end process;

	-- ---------------
	-- STATE REGISTER
	-- ---------------
	state_register : process (EN, CLK, RESET)
	begin
		if (RESET = '1') then
			state <= state_init;
		elsif ((CLK'event) and (CLK = '1')) and (EN = '1') then
			state <= state_next;
		end if;
	end process;

	-- ----
	-- FSM
	-- ----
	fsm_logic : process (state, DATA_RDATA, OUT_BUSY, IN_VLD, EN)
	begin
		pointer_inc         <= '0';
		pointer_dec         <= '0';
		program_counter_inc <= '0';
		program_counter_dec <= '0';
		mux1_select         <= '0';
		mux2_select         <= "00";
		DATA_RDWR           <= '0';
		DATA_EN             <= '0';
		IN_REQ              <= '0';
		OUT_DATA            <= "00000000";
		OUT_WE              <= '0';

		case state is

				-- -------------
				-- NALEZENÍ DAT
				-- -------------
			when state_init =>
				READY <= '0';
				DONE  <= '0';
				if (EN = '1') then
					state_next <= state_fetch_init;
				else
					state_next <= state_init;
				end if;
			when state_decode_init =>
				case DATA_RDATA is
					when X"40" =>
						state_next <= state_begin;
					when others =>
						state_next <= state_fetch_init;
				end case;
			when state_fetch_init =>
				pointer_inc <= '1';
				DATA_EN     <= '1';
				DATA_RDWR   <= '0'; -- čtení
				mux1_select <= '0'; -- DATA_ADDR = pointer
				state_next  <= state_decode_init;

				-- ----------------
				-- ŘÍZENÍ PROGRAMU
				-- ----------------
			when state_begin => -- begin program
				READY      <= '1';
				state_next <= state_fetch;
			when state_fetch =>
				mux1_select <= '1'; -- DATA_ADDR = program counter
				DATA_EN     <= '1';
				DATA_RDWR   <= '0'; -- čtení
				state_next  <= state_decode;
			when state_decode =>
				case DATA_RDATA is
					when X"3E" => -- inkrementace hodnoty ukazatele
						state_next          <= state_ptr_inc;
						program_counter_inc <= '1';
					when X"3C" => -- dekrementace hodnoty ukazatele
						state_next          <= state_ptr_dec;
						program_counter_inc <= '1';
					when X"2B" => -- inkrementace hodnoty na ukazateli
						state_next          <= state_val_inc;
						program_counter_inc <= '1';
					when X"2D" => -- dekrementace hodnoty na ukazateli
						state_next          <= state_val_dec;
						program_counter_inc <= '1';
					when X"5B" => -- porovnej buňku na ukazateli, pokud je nulová skoč na konec cyklu, jinak pokračuj dalším znakem
						state_next          <= state_while_start;
					when X"5D" => -- porovnej buňku na ukazateli, pokud je nenulová skoč na začátek cyklu, jinak pokračuj dalším znakem
						state_next <= state_while_end;
					when X"7E" => -- ukončí while (ekvivalence break)
						state_next          <= state_while_break;
						program_counter_inc <= '1';
					when X"2E" => -- vytiskni hodnotu na ukazateli
						state_next          <= state_print_prepare;
						program_counter_inc <= '1';
					when X"2C" => -- načti hodnotu a ulož ji do aktuální buňky
						state_next          <= state_load_prepare;
						program_counter_inc <= '1';
					when X"40" => -- oodělovač kódu (@) - způsobí zastavení vykonávání programu (ekvivalence return)
						state_next          <= state_end;
						program_counter_inc <= '1';
					when others => -- přeskočení komentárů
						state_next          <= state_fetch;
						program_counter_inc <= '1';
				end case;
			when state_end =>
				DONE <= '1';

				-- -------------
				-- PRINT & LOAD
				-- -------------
			when state_print_prepare =>
				-- přečtení z paměti
				mux1_select <= '0'; -- pointer
				DATA_EN     <= '1';
				DATA_RDWR   <= '0'; -- čtení
				state_next  <= state_print;
			when state_print =>
				-- vypsání na OUT_DATA
				if (OUT_BUSY = '1') then
					state_next <= state_print;
				else
					OUT_WE     <= '1'; -- povolení výstupu
					OUT_DATA   <= DATA_RDATA;
					state_next <= state_fetch;
				end if;
			when state_load_prepare =>
				IN_REQ <= '1';
				if (IN_VLD = '1') then
					state_next <= state_load;
				else
					state_next <= state_load_prepare;
				end if;
			when state_load =>
				mux1_select <= '0';  -- pointer
				mux2_select <= "00"; -- nastavím WDATA na IN_DATA
				DATA_EN     <= '1';
				DATA_RDWR   <= '1'; -- zápis
				state_next  <= state_fetch;

				-- -------------------
				-- POSOUVÁNÍ POINTERU
				-- -------------------
			when state_ptr_inc =>
				pointer_inc <= '1';
				state_next  <= state_fetch;
			when state_ptr_dec =>
				pointer_dec <= '1';
				state_next  <= state_fetch;

				-- ---------------------
				-- ZMĚNA HODNOTY PAMĚTI
				-- ---------------------
			when state_val_inc =>
				-- čtení z paměti (příprava k přičtení 1)
				mux1_select <= '0'; -- pointer
				DATA_EN     <= '1';
				DATA_RDWR   <= '0'; -- čtení
				state_next  <= state_val_inc_write;
			when state_val_inc_write =>
				-- přičtení 1 (pomocí mux1) a zápis do paměti
				mux1_select <= '0';
				mux2_select <= "10"; -- inc RDATA
				DATA_EN     <= '1';
				DATA_RDWR   <= '1'; -- zápis
				state_next  <= state_fetch;
			when state_val_dec =>
				-- čtení z paměti (příprava k odečtení 1)
				mux1_select <= '0'; -- pointer
				DATA_EN     <= '1';
				DATA_RDWR   <= '0'; -- čtení
				state_next  <= state_val_dec_write;
			when state_val_dec_write =>
				-- odečtení 1 (pomocí mux2) a zápis do paměti
				mux1_select <= '0'; -- paměť
				mux2_select <= "01"; -- dec RDATA
				DATA_EN     <= '1';
				DATA_RDWR   <= '1'; -- zápis
				state_next  <= state_fetch;

				-- -------------
				-- CYKLUS WHILE
				-- -------------
			when state_while_start =>
				program_counter_inc <= '1';
				mux1_select         <= '0'; -- pointer
				DATA_EN             <= '1';
				DATA_RDWR           <= '0'; -- čtení
				state_next          <= state_while_start_compare;
			when state_while_start_compare =>
				if (DATA_RDATA = "00000000") then
					-- v paměti je 0 -> skoč za cyklus
					mux1_select <= '1'; -- program counter
					DATA_EN     <= '1';
					DATA_RDWR   <= '0'; -- čtení
					state_next  <= state_while_jmp_end;
				else
					-- jinak pokračuju dovnitř while
					state_next <= state_fetch;
				end if;
			when state_while_jmp_end =>
				if (DATA_RDATA = X"5D") then
					-- došli jsme na znak ']'
					program_counter_inc <= '1';
					state_next          <= state_fetch;
				else
					program_counter_inc <= '1'; -- přičítám dokud nenarazím na znak ']'
					mux1_select         <= '1'; -- program counter
					DATA_EN             <= '1';
					DATA_RDWR           <= '0'; -- čtení
					state_next          <= state_while_jmp_end;
				end if;

			when state_while_end =>
				mux1_select <= '0'; -- pointer
				DATA_EN     <= '1';
				DATA_RDWR   <= '0'; -- čtení
				state_next  <= state_while_end_compare;
			when state_while_end_compare =>
				if (DATA_RDATA /= "00000000") then
					-- v paměti není 0 -> skoč na začátek cyklu
					program_counter_dec <= '1';
					mux1_select         <= '1'; -- program counter
					DATA_EN             <= '1';
					DATA_RDWR           <= '0'; -- čtení
					state_next          <= state_while_jmp_start;
				else
					-- jinak pokračuju za while
					program_counter_inc <= '1';
					state_next          <= state_fetch;
				end if;
			when state_while_jmp_start =>
				if (DATA_RDATA = X"5B") then -- došli jsme na znak '['
					program_counter_inc <= '1';
					state_next          <= state_fetch;
				else
					program_counter_dec <= '1'; -- odčítám dokud nenarazím na '['
					mux1_select         <= '1'; -- program counter
					DATA_EN             <= '1';
					state_next          <= state_while_jmp_start;
				end if;
			when state_while_break =>
				mux1_select <= '1'; -- program counter
				DATA_EN     <= '1';
				DATA_RDWR   <= '0'; -- čtení
				state_next  <= state_while_break_jmp_end;
			when state_while_break_jmp_end =>
				if (DATA_RDATA = X"5D") then -- došli jsme na znak ']'
					program_counter_inc <= '1';
					state_next          <= state_fetch;
				else
					program_counter_inc <= '1'; -- přičítám dokud nenarazím na znak ']'
					mux1_select         <= '1'; -- program counter
					DATA_EN             <= '1';
					DATA_RDWR           <= '0'; -- čtení
					state_next          <= state_while_break;
				end if;
			when others => null;
		end case;
	end process;
end behavioral;
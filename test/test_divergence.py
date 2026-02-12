import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Combine


@cocotb.test()
async def test_divergence(dut):
    """
    Test Branch Divergence Logic
    Program:
    0: CONST R0, #2       (0x9002) - All thds R0=2
    1: CMP R15, R0        (0x20F0) - Compare %threadIdx with 2. T0,T1=Neg, T2=Zero, T3=Pos
    2: BRn #5             (0x1805) - Branch to 5 if Neg. T0,T1 taken. T2,T3 fallthrough.
    3: CONST R1, #0xFF    (0x91FF) - Fallthrough (T2,T3). Set R1=0xFF.
    4: NOP                (0x0000) - Just padding to reach 5
    5: CONST R1, #0xAA    (0x91AA) - Converge point. All thds set R1=0xAA.
    6: RET                (0xF000)
    """

    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    # --- Reset ---
    dut.reset.value = 1
    dut.start.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)

    # --- Setup Inputs ---
    dut.start.value = 1
    dut.thread_count.value = 4
    dut.block_id.value = 0
    
    # --- Memory Mock ---
    memory = {
        0: 0x9002,
        1: 0x20F0,
        2: 0x1805,
        3: 0x91FF,
        4: 0x0000,
        5: 0x91AA,
        6: 0xF000
    }

    # Background Coroutine to serve memory
    async def serve_memory():
        while True:
            await RisingEdge(dut.clk)
            if dut.program_mem_read_valid.value == 1:
                addr = int(dut.program_mem_read_address.value)
                if addr in memory:
                    dut.program_mem_read_data.value = memory[addr]
                    dut.program_mem_read_ready.value = 1
                    # Wait one cycle for core to accept (it accepts on ready high)
                    await RisingEdge(dut.clk) 
                    dut.program_mem_read_ready.value = 0
                else:
                    # Should not finish test, but maybe log warning
                    pass

    cocotb.start_soon(serve_memory())

    # --- Monitoring ---
    
    # Wait for PC=2 (Branch Instruction)
    while True:
        await RisingEdge(dut.clk)
        if hasattr(dut, 'current_pc') and dut.current_pc.value == 2:
            break
            
    dut._log.info("Reached Branch Instruction (PC=2)")
    
    # Wait for Divergence (PC should become 3 for active threads)
    # Active mask should be 0b1100 (T2, T3) -> 12 dec
    # Note: bit order depends on definition. 
    # [THREADS_PER_BLOCK-1:0] -> [3:0]. T3 is MSB.
    # T0, T1 branch. T2, T3 fallthrough.
    # Expected Active Mask for Fallthrough: T2(1), T3(1), T0(0), T1(0) -> 1100 (0xC)
    
    # Wait for PC=3
    while True:
        await RisingEdge(dut.clk)
        if dut.current_pc.value == 3:
            dut._log.info("Reached Fallthrough Path (PC=3)")
            await ReadOnly()
            # Check Active Mask via logic analyzer signal if available, 
            # Or check internal signal if exposing it
            # We exposed `active_mask_out` in core.sv! But it is internal to `scheduler` usage for `enable`.
            # We didn't add a port to `core` for checking active_mask from outside easily unless we spy.
            # Cocotb can spy internal signals.
            
            # Accessing internal signal `active_mask` in `scheduler_instance`
            active_mask = dut.scheduler_instance.active_mask.value
            dut._log.info(f"Active Mask at PC=3: {active_mask.binstr}")
            assert active_mask == 0xC, f"Expected Active Mask 1100 (T3,T2), got {active_mask.binstr}"
            break

    # Wait for PC=5 (Convergence)
    while True:
        await RisingEdge(dut.clk)
        if dut.current_pc.value == 5:
            dut._log.info("Reached Convergence Point (PC=5)")
            # Should be at start of FETCH/DECODE.
            # Wait a few cycles for Re-convergence logic (FETCH state CHECK)
            for _ in range(5): await RisingEdge(dut.clk)
            
            await ReadOnly()
            active_mask = dut.scheduler_instance.active_mask.value
            dut._log.info(f"Active Mask at PC=5: {active_mask.binstr}")
            assert active_mask == 0xF, f"Expected Active Mask 1111 (All threads), got {active_mask.binstr}"
            break

    # Wait for Done
    while True:
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            dut._log.info("Kernel Execution Done")
            break

    dut._log.info("Test Passed!")

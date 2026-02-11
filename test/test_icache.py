import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

@cocotb.test()
async def test_icache(dut):
    """Test Instruction Cache Hit and Miss Logic"""
    
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut.reset.value = 1
    dut.valid_in.value = 0
    dut.mem_read_ready.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)

    # Test 1: Cache Miss (Addr 0x05)
    # ---------------------------------------------
    addr1 = 0x05
    data1 = 0xAAAA
    
    dut.valid_in.value = 1
    dut.addr_in.value = addr1
    
    dut._log.info(f"Driven valid_in=1, addr_in={addr1}")
    
    # Wait for request to memory
    await RisingEdge(dut.mem_read_valid)
    await ReadOnly()
    dut._log.info(f"mem_read_valid went high. mem_read_address={dut.mem_read_address.value}")
    assert dut.mem_read_address.value == addr1, f"Memory Read Addr mismatch. Got {dut.mem_read_address.value}, expected {addr1}"
    
    # Simulate memory delay
    await RisingEdge(dut.clk)
    dut.mem_read_data.value = data1
    dut.mem_read_ready.value = 1
    await RisingEdge(dut.clk)
    dut.mem_read_ready.value = 0
    
    # Wait for data output
    await RisingEdge(dut.ready_out)
    assert dut.data_out.value == data1, f"Data Output mismatch. Got {dut.data_out.value}, expected {data1}"
    
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)
    
    # Test 2: Cache Hit (Addr 0x05)
    # ---------------------------------------------
    dut.valid_in.value = 1
    dut.addr_in.value = addr1
    
    # Should check valid_out immediately or shortly, without mem_read_valid
    # We wait a few cycles to ensure mem_read_valid does NOT go high
    for _ in range(3):
        assert dut.mem_read_valid.value == 0, "Cache Hit should not trigger memory read"
        if dut.ready_out.value == 1:
            break
        await RisingEdge(dut.clk)
        
    assert dut.ready_out.value == 1, "Cache Hit did not assert ready_out"
    assert dut.data_out.value == data1, f"Cache Hit Data mismatch. Got {dut.data_out.value}, expected {data1}"

    dut.valid_in.value = 0
    await RisingEdge(dut.clk)

    # Test 3: Conflict / Eviction (Addr 0x15) -> Same index 5, Tag different
    # ---------------------------------------------
    addr2 = 0x15 # Index 5, Tag 1
    data2 = 0xBBBB
    
    dut.valid_in.value = 1
    dut.addr_in.value = addr2
    
    # Wait for new request to memory (Miss)
    await RisingEdge(dut.mem_read_valid)
    await ReadOnly()
    assert dut.mem_read_address.value == addr2, f"Memory Read Addr mismatch for eviction. Got {dut.mem_read_address.value}, expected {addr2}"
    
    # Simulate memory response
    await RisingEdge(dut.clk)
    dut.mem_read_data.value = data2
    dut.mem_read_ready.value = 1
    await RisingEdge(dut.clk)
    dut.mem_read_ready.value = 0
    
    # Wait for data output
    await RisingEdge(dut.ready_out)
    assert dut.data_out.value == data2, f"Data Output mismatch after eviction. Got {dut.data_out.value}, expected {data2}"
    
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)

    # Test 4: Back to original address (Addr 0x05) -> Miss again due to eviction
    # ---------------------------------------------
    dut.valid_in.value = 1
    dut.addr_in.value = addr1
    
    await RisingEdge(dut.mem_read_valid)
    await ReadOnly()
    assert dut.mem_read_address.value == addr1, f"Memory Read Addr mismatch for re-miss. Got {dut.mem_read_address.value}, expected {addr1}"
    
    # Simulate memory response
    await RisingEdge(dut.clk)
    dut.mem_read_data.value = data1
    dut.mem_read_ready.value = 1
    await RisingEdge(dut.clk)
    dut.mem_read_ready.value = 0
    
    await RisingEdge(dut.ready_out)
    assert dut.data_out.value == data1, f"Data Output mismatch re-miss. Got {dut.data_out.value}, expected {data1}"
    
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)


"""Build the SRAM-macro wrapper without depending on RTL whitespace."""

import re


def macro_wrapper(text, top=None):
    if top is not None:
        text, count = re.subn(r"\bmodule\s+npu_soc\b", "module " + top, text)
        assert count == 1, "Expected one npu_soc module"
    instance = """RA1SHD_2048x32M8 i_sram(
      .Q(sram_rdata_i[b]), .CLK(clk_i), .CEN(~sram_req_o[b]),
      .WEN(~sram_wen_o[b]), .A(sram_addr_o[b]), .D(sram_wdata_o[b]), .OEN(1'b0));"""
    text, count = re.subn(
        r"\bsram_ff\s*#\s*\(.*?\)\s+i_sram\s*\(.*?\);", instance, text, flags=re.S
    )
    assert count == 1, "Expected one parameterized SRAM instance in bank generate"
    return text

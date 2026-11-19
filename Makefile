RTL   := rtl/dcache.sv
BUILD := build

.PHONY: test formal lint synth clean

test:
	@mkdir -p $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb.vvp $(RTL) tb/tb_dcache.sv
	vvp -n $(BUILD)/tb.vvp

# bounded model check + k-induction proof + cover traces
formal:
	cd formal && sby -f dcache.sby

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL --top-module dcache $(RTL)

synth:
	@mkdir -p $(BUILD)
	yosys -q -p "read_verilog -sv $(RTL); synth -top dcache; tee -o $(BUILD)/synth_stat.txt stat"

clean:
	rm -rf $(BUILD) formal/dcache_bmc formal/dcache_prove formal/dcache_cover

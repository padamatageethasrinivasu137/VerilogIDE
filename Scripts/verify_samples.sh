#!/bin/bash
# Exercises the same iverilog/vvp command lines the app generates, against the bundled sample projects.
# Usage: Scripts/verify_samples.sh      (requires iverilog + vvp on PATH)
set -u
cd "$(dirname "$0")/../Samples"
B=$(mktemp -d); pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "1. mux2_demo: compile + run + VCD"
( cd mux2_demo && rm -f simulation/waveform.vcd &&
  iverilog -g2012 -s mux2_tb -o "$B/a.vvp" src/mux2.v testbench/mux2_tb.v &&
  (cd simulation && vvp -n "$B/a.vvp" >/dev/null) && [ -s simulation/waveform.vcd ] && grep -q '\$enddefinitions' simulation/waveform.vcd ) && ok "VCD generated and valid" || bad "mux2_demo"

echo "2. no_testbench: nothing in the project is a testbench (the app refuses to run)"
grep -lE 'initial|\$finish' no_testbench/src/*.v >/dev/null 2>&1 && bad "unexpected testbench" || ok "no testbench constructs present"

echo "3. invalid_verilog: compile must fail with file:line diagnostics"
( cd invalid_verilog && iverilog -g2012 -s mux2_tb -o "$B/b.vvp" src/mux2.v testbench/mux2_tb.v 2>"$B/err.txt" ); rc=$?
[ $rc -ne 0 ] && grep -qE '^src/mux2.v:[0-9]+:' "$B/err.txt" && ok "exit $rc, first diagnostic: $(head -1 "$B/err.txt")" || bad "invalid_verilog"

echo "4. multiple_testbenches: two candidate testbench modules exist (the app shows a chooser)"
n=$(grep -hE '^\s*module\s+\w+_tb' multiple_testbenches/testbench/*.v | wc -l); [ "$n" -eq 2 ] && ok "$n testbenches" || bad "count=$n"

echo "5. missing_dumpvars: generated wrapper makes the VCD without touching the testbench"
( cd missing_dumpvars && cat > "$B/wrap.v" <<W
module __ide_wave_dump; initial begin \$dumpfile("$B/w.vcd"); \$dumpvars(0, mux2_tb); end endmodule
W
  iverilog -g2012 -s mux2_tb -s __ide_wave_dump -o "$B/c.vvp" "$B/wrap.v" src/mux2.v testbench/mux2_tb.v &&
  (cd "$B" && vvp -n "$B/c.vvp" >/dev/null) && [ -s "$B/w.vcd" ] && ! grep -q dumpvars testbench/mux2_tb.v ) && ok "wrapper VCD ok, testbench unchanged" || bad "missing_dumpvars"

echo; echo "passed=$pass failed=$fail"; rm -rf "$B"; [ $fail -eq 0 ]

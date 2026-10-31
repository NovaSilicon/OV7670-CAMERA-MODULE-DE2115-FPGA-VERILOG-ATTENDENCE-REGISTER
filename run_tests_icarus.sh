#!/bin/bash
# Runs every Icarus Verilog bench; writes <bench>.log; exits non-zero on any failure.
# tb_pipeline and tb_top_render stream whole synthetic frames and take several minutes.
cd "$(dirname "$0")" || exit 1
TOP="top_ov7670_vga_detect.v face_crop_16x16.v live_face_matcher.v presence_tracker.v box_label_overlay.v text_row.v font5x7.v attendance_display.v attendance_latch.v eeprom_store.v i2c_byte_master.v eeprom_model.v ov7670_controller.v ov7670_registers.v i2c_sender.v ov7670_capture.v frame_buffer.v vga_timing.v RGB2GREY.v RGB.v"
PIPE="face_crop_16x16.v live_face_matcher.v presence_tracker.v attendance_latch.v eeprom_store.v i2c_byte_master.v eeprom_model.v"
# name:sources:plusargs  (tb_pipeline runs twice: PHASE=1 writes the EEPROM image, PHASE=2 powers on from it)
declare -a RUNS=(
 "tb_font5x7|font5x7.v|"
 "tb_attendance_latch|attendance_latch.v|"
 "tb_face_crop_16x16|face_crop_16x16.v|"
 "tb_presence_tracker|presence_tracker.v|"
 "tb_eeprom_store|eeprom_store.v i2c_byte_master.v eeprom_model.v|"
 "tb_pipeline|$PIPE|+PHASE=1"
 "tb_pipeline|$PIPE|+PHASE=2"
 "tb_top_render|$TOP|"
)
fail=0
for r in "${RUNS[@]}"; do
  IFS='|' read -r n src args <<< "$r"
  tag="$n${args:+_phase${args##*=}}"
  if ! iverilog -g2012 -o "$n.vvp" $src "$n.v" > "$n.compile.txt" 2>&1; then
    echo "COMPILE FAIL: $n"; cat "$n.compile.txt"; fail=1; continue
  fi
  rm -f "$n.compile.txt"
  vvp "$n.vvp" $args > "$tag.log" 2>&1; rc=$?
  tail -n 2 "$tag.log"
  if [ $rc -ne 0 ] || ! grep -q '^PASS' "$tag.log"; then echo "FAIL: $tag"; fail=1; fi
  rm -f "$n.vvp"
done
[ $fail -eq 0 ] && echo "ALL BENCHES PASSED" || echo "SOME BENCHES FAILED"
exit $fail

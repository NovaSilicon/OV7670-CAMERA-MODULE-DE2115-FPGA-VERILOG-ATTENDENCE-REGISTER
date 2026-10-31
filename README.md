# DE2-115 camera attendance — three people, faces stored permanently (start here)

Open `top_ov7670_vga_detect.qpf` in Quartus Prime Lite 18.1 (target EP4CE115F29C7), **compile it**, and program the new `.sof`. This folder has no `.sof` (older ones belong to older designs).

## What changed in this version

**Latest update:** (1) **10 samples per person** instead of 5. (2) **Already-marked check:** if a person whose attendance is already marked is recognised again, the box turns **orange** and shows `ALREADY MARKED`; attendance is not marked a second time. Why 10 and not 15: the on-board EEPROM is only 4096 bytes. 15 samples x 3 people x 256 cells does not fit even at 4 bits per cell (5760 bytes). 10 samples x 3 people at 4 bits per cell = 3840 bytes does fit. The templates are therefore kept with 4-bit precision everywhere (matcher RAM and EEPROM), so the system behaves identically before and after a power cycle. **Old EEPROM contents from the previous version are not read** (new image format): enrol everyone once again.

| Request | Now |
|---|---|
| Third person | **SAHITI, 26MVD0036** is ID 2, with her own enrol key (KEY[3]) and her own attendance row. |
| Enrol once, keep forever | Enrolled faces are saved in the **on-board 32 Kbit EEPROM** and loaded automatically at every power-up or reprogramming. Switching off the board or loading a new `.sof` no longer forgets anyone. |
| Never lose a person by accident | Enrol keys only work while **SW[17] is up**. With SW[17] down (the normal state) no key can change or erase anything. A short tap that captured nothing changes nothing. |
| Name on the box, PRESENT held 1–2 s | Green box, `<NAME>` / `PRESENT <reg no>`, then back to `DETECTING`. Second time for the same person: orange box, `ALREADY MARKED`. |

Why it forgot before: the templates lived only in the FPGA's RAM. Anything that reconfigures the FPGA (power-off, re-programming the `.sof`) wipes that RAM, and the screen then went back to `UNKNOWN` and asked for enrolment. They are now written to a chip that keeps its data without power.

## Controls

| Control | Function |
|---|---|
| SW[17] | **Enrol enable.** Up only while enrolling; down otherwise. |
| KEY[1] / KEY[2] / KEY[3] (hold, with SW[17] up) | Enrol **ADVAITH** / **NAVANEETH** / **SAHITI**. |
| KEY[0] | Re-send camera configuration (unchanged). |
| SW[3] | Up = reset attendance and tracker (stored faces are kept). Put it back down. |
| SW[15:12] | Match threshold = `0x1000 + 0x200 x value` (all down = 0x1000). Up = more permissive. |
| SW[0] / SW[1] / SW[2] | Greyscale / freeze capture / test pattern (unchanged). |
| LEDG[0..2] | Attendance latched for ADVAITH, NAVANEETH, SAHITI. [3] new attendance event, [4] matcher result, [5] camera configured, [6] EEPROM busy, [7] LOCKED, [8] enrolling. |

## Enrolling (one time per person)

1. Put SW[17] up. The person stands so the face fills the yellow box, as they will stand later.
2. Hold that person's key (KEY[1], KEY[2] or KEY[3]), moving the head very slightly (small turn or tilt). The label shows `ENROLLING <NAME>` and `SAMPLE n OF 10`. When it says `DONE: RELEASE KEY` (about 1.5 s), release the key.
3. The label shows `SAVING <NAME>` / `DO NOT POWER OFF` for about 1 s (magenta box). Wait until it finishes; the status line then shows `MEM OK`.
4. Repeat for the other people, then put **SW[17] down**.

Enrolling a person again simply replaces that person's templates; the others are untouched. Ten samples per person are stored (what fits the 4 KB EEPROM for three people at 4 bits per cell). Move the head very slightly during the capture: different small poses make the match tolerant.

At every power-up the screen shows `LOADING SAVED FACES` for about half a second, then `MEM OK`. `MEM NEW` means the EEPROM holds no saved faces yet (first use). `MEM ERR` means the EEPROM did not answer: the system still works, but enrolments are then only kept until power-off — tell me if you see it.

## Reading the screen

- Label on the box, top-left: `DETECTING` (yellow) -> `<NAME>` + `PRESENT <reg no>` (green, held about 1.5 s) -> `DETECTING`. If the person was already marked: `<NAME>` + `ALREADY MARKED` (orange). `UNKNOWN` (red) = a face-like image that matches nobody. `ENROLLING ...` (cyan), `SAVING ...` / `LOADING ...` (magenta).
- Bottom left: attendance rows for the three people (PRESENT / NOT MARKED).
- Bottom right (hex numbers): `SA`, `SN`, `SS` = best score against ADVAITH / NAVANEETH / SAHITI (smaller = closer, `FFFF` = nobody enrolled), `T` = threshold, `C` = contrast of the current crop (needs at least `0A00`), and the EEPROM status (`MEM OK` ...).
- Bottom row: `A10 N10 S10` = number of stored samples per person.

## Tuning the threshold (needs the real camera)

Stand in as a correct person and note the usual score for that person (`SA`, `SN` or `SS`); then have someone else stand there and note their scores. Choose SW[15:12] so the threshold `T` lies between the two. Right person rejected too often: raise it. Stranger accepted: lower it.

## Limits

- Fixed guide box, not a face tracker: the face must be inside it, at about the distance used when enrolling.
- Small template matcher for three people, not security grade. Look-alikes, very different lighting or distance can fail; re-enrol (the same procedure) if conditions change a lot.
- Attendance is session-only (not stored; SW[3] clears it, after which everyone can be marked again).
- Templates are stored at 4-bit precision (see top). Saving uses the EEPROM bytes 0x000-0xF0F. If that chip holds anything else you need (for example a board ID from a lab demo), tell me before enrolling.

## Verification status

Run `./run_tests_icarus.sh` (Linux/macOS) or `.\run_tests_icarus.ps1` (PowerShell) with Icarus Verilog; the frame-streaming benches take several minutes.

| Bench | Checks |
|---|---|
| `tb_font5x7`, `tb_attendance_latch` | Glyphs; one attendance event per person, a repeat gives only the already-marked pulse |
| `tb_face_crop_16x16` | 256 cell averages exact, no leakage from outside the box, banks handed over once per frame |
| `tb_presence_tracker` | Lock needs consistent hits, hold length, dropped frames, UNKNOWN, ENROL/BUSY pause, ID2 |
| `tb_eeprom_store` | I2C load/save against a 24LC32-style EEPROM model: all 30 template slots (4-bit packed), means and counts reach the matcher RAM, save with ack polling, other persons untouched, blank = NEW, absent chip = ERR |
| `tb_pipeline` (two runs) | Run 1: blank EEPROM, write protection, enrol + save three people, recognition, stranger rejected. Run 2: **power cycle** — a fresh start from the saved image, **no enrolment**, all three recognised, stranger rejected. Both runs also lock the same person a second time: no second attendance event |
| `tb_top_render` | Whole top level on the VGA pins, including EEPROM: screens saved as `render_*.ppm` (PNG copies in `docs/docs/simulation_screens/`) |

All benches use **synthetic faces** and a **behavioural EEPROM model**. They prove the logic and the I2C protocol, not accuracy on real faces and not the real EEPROM chip. **Not done:** Quartus compile of this version (errors, resource use and timing are unverified; the previous design closed timing with +14.6 ns slack), any run on the board, and measurements with the real OV7670. The EEPROM pins (`EEP_I2C_SCLK` = D14, `EEP_I2C_SDAT` = E14) and address (0xA0 / 0xA1) are taken from the DE2-115 user manual. Fill in `BOARD_TEST_LOG.md` in the lab.

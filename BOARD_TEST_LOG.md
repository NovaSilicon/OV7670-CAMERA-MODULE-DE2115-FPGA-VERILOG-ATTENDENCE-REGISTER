# Board test log — DE2-115 + OV7670 (three people, EEPROM storage)

**Overall status: NOT TESTED.** Compile in Quartus first, then fill in the rows.

| Field | Value |
|---|---|
| Date / people present | |
| Quartus compile (errors / warnings / worst setup slack) | |
| Threshold switches SW[15:12] | |

| # | Check | Result | Notes (SA / SN / SS / C values, MEM status) |
|---|---|---|---|
| 1 | Power-up: `LOADING SAVED FACES`, then `MEM NEW` (first time) or `MEM OK`; never `MEM ERR` | | |
| 2 | Live image stable, yellow box, `DETECTING` | | |
| 3 | SW[17] down: pressing KEY[1..3] does nothing | | |
| 4 | SW[17] up, hold KEY[1] with Advaith: SAMPLE 1..10, `DONE`, release, `SAVING ADVAITH`, `MEM OK`, `A10` | | |
| 5 | Same for Navaneeth (KEY[2], `N10`) | | |
| 6 | Same for Sahiti (KEY[3], `S10`); then SW[17] down | | |
| 7 | **Power-cycle the board (and reload the .sof): no enrolment, `MEM OK`, `A10 N10 S10`** | | |
| 8 | After the power cycle each person: green box, name, `PRESENT`, attendance row | | |
| 9 | PRESENT stays about 1.5 s then returns to `DETECTING` | | |
| 10 | Typical correct-person score vs. other-person scores; threshold chosen | | |
| 11 | Fourth person / empty wall / skin close-up: never PRESENT | | |
| 12 | Still recognised after the board has run 30+ minutes | | |
| 13 | SW[3] up then down clears attendance rows; `A10 N10 S10` and names still work | | |
| 14 | Person already marked stands in front again: orange box, `ALREADY MARKED`, attendance row unchanged | | |
| 15 | After SW[3] up/down the same person can be marked again | | |

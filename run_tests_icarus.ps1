$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$iverilogExe = (Get-Command iverilog -ErrorAction SilentlyContinue).Source
$vvpExe = (Get-Command vvp -ErrorAction SilentlyContinue).Source
if (-not $iverilogExe -or -not $vvpExe) {
    $iverilogExe = 'C:\iverilog\bin\iverilog.exe'
    $vvpExe = 'C:\iverilog\bin\vvp.exe'
}
if (-not (Test-Path -LiteralPath $iverilogExe) -or -not (Test-Path -LiteralPath $vvpExe)) {
    throw 'Icarus Verilog was not found. Install it or add iverilog.exe and vvp.exe to PATH.'
}
Push-Location $projectDir
try {
    $top = @('top_ov7670_vga_detect.v','face_crop_16x16.v','live_face_matcher.v','presence_tracker.v','box_label_overlay.v','text_row.v','font5x7.v','attendance_display.v','attendance_latch.v','eeprom_store.v','i2c_byte_master.v','eeprom_model.v','ov7670_controller.v','ov7670_registers.v','i2c_sender.v','ov7670_capture.v','frame_buffer.v','vga_timing.v','RGB2GREY.v','RGB.v')
    $pipe = @('face_crop_16x16.v','live_face_matcher.v','presence_tracker.v','attendance_latch.v','eeprom_store.v','i2c_byte_master.v','eeprom_model.v')
    # tb_pipeline runs twice: PHASE=1 enrols and saves the EEPROM image, PHASE=2 powers on from it.
    # tb_pipeline and tb_top_render stream whole synthetic frames: several minutes each.
    $benches = @(
        @{ Name = 'tb_font5x7';          Tag = 'tb_font5x7';          Sources = @('font5x7.v'); Args = @() },
        @{ Name = 'tb_attendance_latch'; Tag = 'tb_attendance_latch'; Sources = @('attendance_latch.v'); Args = @() },
        @{ Name = 'tb_face_crop_16x16';  Tag = 'tb_face_crop_16x16';  Sources = @('face_crop_16x16.v'); Args = @() },
        @{ Name = 'tb_presence_tracker'; Tag = 'tb_presence_tracker'; Sources = @('presence_tracker.v'); Args = @() },
        @{ Name = 'tb_eeprom_store';     Tag = 'tb_eeprom_store';     Sources = @('eeprom_store.v','i2c_byte_master.v','eeprom_model.v'); Args = @() },
        @{ Name = 'tb_pipeline';         Tag = 'tb_pipeline_phase1';  Sources = $pipe; Args = @('+PHASE=1') },
        @{ Name = 'tb_pipeline';         Tag = 'tb_pipeline_phase2';  Sources = $pipe; Args = @('+PHASE=2') },
        @{ Name = 'tb_top_render';       Tag = 'tb_top_render';       Sources = $top; Args = @() }
    )
    foreach ($bench in $benches) {
        $simFile = "$($bench.Name).vvp"
        & $iverilogExe -g2012 -o $simFile @($bench.Sources) "$($bench.Name).v"
        if ($LASTEXITCODE -ne 0) { throw "Compile failed for $($bench.Name)" }
        & $vvpExe ".\$simFile" @($bench.Args) 2>&1 | Tee-Object -FilePath "$($bench.Tag).log"
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed for $($bench.Tag)" }
        if (-not (Select-String -Path "$($bench.Tag).log" -Pattern '^PASS' -Quiet)) { throw "No PASS line in $($bench.Tag)" }
    }
    Write-Host 'ALL BENCHES PASSED'
}
finally {
    Pop-Location
}

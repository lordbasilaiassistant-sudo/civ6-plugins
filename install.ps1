# Civ6 Plugins installer - copies every mod folder in this repo into the
# correct Civ6 Mods directory (Steam or Microsoft Store/Game Pass build,
# with or without OneDrive-redirected Documents).

$candidates = @(
    (Join-Path $env:USERPROFILE "Documents\My Games\Sid Meier's Civilization VI (WinApp)"),
    (Join-Path $env:USERPROFILE "OneDrive\Documents\My Games\Sid Meier's Civilization VI (WinApp)"),
    (Join-Path $env:USERPROFILE "Documents\My Games\Sid Meier's Civilization VI"),
    (Join-Path $env:USERPROFILE "OneDrive\Documents\My Games\Sid Meier's Civilization VI")
)

$target = $null
foreach ($c in $candidates) {
    if (Test-Path $c) { $target = Join-Path $c "Mods"; break }
}
if ($null -eq $target) {
    Write-Host "Could not find a Civ6 user folder. Launch the game once, then re-run." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target | Out-Null }

$installed = 0
Get-ChildItem -Path $PSScriptRoot -Directory | ForEach-Object {
    if (Test-Path (Join-Path $_.FullName "*.modinfo")) {
        Copy-Item -Path $_.FullName -Destination $target -Recurse -Force
        Write-Host ("Installed {0} -> {1}" -f $_.Name, $target) -ForegroundColor Green
        $installed++
    }
}
if ($installed -eq 0) {
    Write-Host "No mod folders (with a .modinfo) found next to this script." -ForegroundColor Yellow
} else {
    Write-Host "Done. Enable the mod(s) in game: Main Menu -> Additional Content." -ForegroundColor Cyan
}

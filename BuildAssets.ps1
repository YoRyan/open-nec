# To run this script, you'll probably have to use:
#   Set-ExecutionPolicy Bypass Process
#
# ConvertToTg.exe can only operate on drive letters. This presents a problem if
# the source code lives on WSL, which it probably will for performance reasons.
# You can map WSL to a drive letter using 'net use':
#   https://stackoverflow.com/a/71002897

$CompressonatorCli = 'C:\Compressonator_4.2.5185\bin\CLI\compressonatorcli.exe'
$RailWorks = 'C:\Program Files (x86)\Steam\steamapps\common\RailWorks'
if (Test-Path .\BuildAssets.config.ps1) {
    . .\BuildAssets.config.ps1
}

function FindModPaths {
    [CmdletBinding()]
    param(
        [string]$Filter
    )
    return Get-ChildItem -Name -Path .\src\mod -Recurse -FollowSymlink -Filter $Filter
}

function ToSource {
    param(
        [scriptblock]$Build,
        [string]$Extension
    )
    foreach ($ModPath in $Input) {
        $Build.Invoke(".\src\mod\$ModPath", ".\src\mod\$( $ModPath -replace '\.[\w]*$',$Extension )")
    }
}

function ToDist {
    param(
        [scriptblock]$Build,
        [string]$Extension
    )
    foreach ($ModPath in $Input) {
        $OutDir = ".\dist\$(Split-Path -Path $ModPath -Parent)"
        New-Item $OutDir -ItemType Directory -ErrorAction SilentlyContinue
        $Build.Invoke(".\src\mod\$ModPath", ".\dist\$( $ModPath -replace '\.[\w]*$',$Extension )")
    }
}

function Serz {
    [CmdletBinding()]
    param(
        [string]$In,
        [string]$Out
    )
    & "$RailWorks\serz.exe" $In "/bin:$Out"
}

function ConvertToDav {
    [CmdletBinding()]
    param(
        [string]$In,
        [string]$Out
    )
    & "$RailWorks\ConvertToDav.exe" -i $In -o $Out
}

function Compressonator {
    [CmdletBinding()]
    param(
        [string]$In,
        [string]$Out
    )
    & $CompressonatorCli -miplevels 5 -fd ARGB_8888 $In $Out
}

function ConvertToTg {
    [CmdletBinding()]
    param(
        [string]$In,
        [string]$Out
    )
    $FullIn = Resolve-Path $In
    $FullOut = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
    if (($FullIn -match '^\\\\') -or ($FullOut -match '^\\\\')) {
        throw "ConvertToTG.exe cannot operate on a UNC path."
    }
    & "$RailWorks\ConvertToTG.exe" -forcecompress -i $FullIn -o $FullOut
}

FindModPaths *.xml | ToDist $Function:Serz .bin
FindModPaths *.wav | ToDist $Function:ConvertToDav .dav
FindModPaths *.png | ToSource $Function:Compressonator .dds
FindModPaths *.dds | ToDist $Function:ConvertToTg .TgPcDx
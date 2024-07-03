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

Add-Type -Assembly System.IO.Compression.FileSystem

# Step 1: Extract and modify payware assets.

function Mkdir {
    param(
        [string]$Path
    )
    New-Item $Path -ItemType Directory -ErrorAction SilentlyContinue
}

function ExtractFromZip {
    param(
        [string]$Zip,
        [string]$Entry,
        [string]$Out
    )
    try {
        Mkdir $(Split-Path -Path $Out -Parent)
        $ZipFile = [IO.Compression.ZipFile]::OpenRead($Zip)
        $ZipEntry = $ZipFile.Entries | Where-Object FullName -EQ $Entry
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ZipEntry, $Out, $True)
    } finally {
        $ZipFile.Dispose()
    }
}

function UnSerz {
    [CmdletBinding()]
    param(
        [string]$In,
        [string]$Out
    )
    & "$RailWorks\serz.exe" $In "/xml:$Out"
}

ExtractFromZip "$RailWorks\Assets\RSC\AcelaPack01\AcelaPack01Assets.ap" `
    "InputMappers/AcelaExpert.bin" `
    ".\payware\Assets\RSC\AcelaPack01\InputMappers\AcelaExpert.bin"
UnSerz ".\payware\Assets\RSC\AcelaPack01\InputMappers\AcelaExpert.bin" `
    ".\payware\Assets\RSC\AcelaPack01\InputMappers\AcelaExpert.xml"
(Get-Content -Path ".\payware\Assets\RSC\AcelaPack01\InputMappers\AcelaExpert.xml").Replace(
    "</Map>",
    @"
<!-- Make the Q key operate the acknowledge plunger. -->
<iInputMapper-cInputMapEntry d:id="43587">
	<State d:type="sInt32">0</State>
	<Device d:type="cDeltaString">Keyboard</Device>
	<ButtonState d:type="cDeltaString">ButtonDown</ButtonState>
	<Button d:type="cDeltaString">Key_Q</Button>
	<ShiftButton d:type="cDeltaString">NoShift</ShiftButton>
	<Axis d:type="cDeltaString">NoAxis</Axis>
	<Name d:type="cDeltaString">IncreaseControlStart</Name>
	<Parameter d:type="cDeltaString">AWSReset</Parameter>
	<NewState d:type="sInt32">0</NewState>
</iInputMapper-cInputMapEntry>
<iInputMapper-cInputMapEntry d:id="43597">
	<State d:type="sInt32">0</State>
	<Device d:type="cDeltaString">Keyboard</Device>
	<ButtonState d:type="cDeltaString">ButtonUp</ButtonState>
	<Button d:type="cDeltaString">Key_Q</Button>
	<ShiftButton d:type="cDeltaString">NoShift</ShiftButton>
	<Axis d:type="cDeltaString">NoAxis</Axis>
	<Name d:type="cDeltaString">DecreaseControlStart</Name>
	<Parameter d:type="cDeltaString">AWSReset</Parameter>
	<NewState d:type="sInt32">0</NewState>
</iInputMapper-cInputMapEntry>
</Map>
"@) | Set-Content -Path ".\src\mod\Assets\RSC\AcelaPack01\InputMappers\AcelaExpert.xml"

# Step 2: Build our new assets.

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
        Mkdir $OutDir
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

function CopyOutput {
    Mkdir "dist\Assets\DTG\WashingtonBaltimore\InputMapper"
    Copy-Item `
        "dist\Assets\RSC\AcelaPack01\InputMappers\AcelaExpert.bin" `
        "dist\Assets\DTG\WashingtonBaltimore\InputMapper\AcelaExpert.bin"

    Mkdir "dist\Assets\DTG\WashingtonBaltimore\Audio\RailVehicles\Electric\Acela\Cab"
    Copy-Item `
        "dist\Assets\RSC\AcelaPack01\Audio\RailVehicles\Electric\Acela\Cab\*" `
        "dist\Assets\DTG\WashingtonBaltimore\Audio\RailVehicles\Electric\Acela\Cab"

    Mkdir "dist\Assets\DTG\WashingtonBaltimore\RailVehicles\Electric\Acela\Default\FirstCar\destinations"
    Copy-Item `
        "dist\Assets\RSC\AcelaPack01\RailVehicles\Electric\Acela\Default\FirstCar\destinations\*" `
        "dist\Assets\DTG\WashingtonBaltimore\RailVehicles\Electric\Acela\Default\FirstCar\destinations"
}

FindModPaths *.xml | ToDist $Function:Serz .bin
FindModPaths *.wav | ToDist $Function:ConvertToDav .dav
FindModPaths *.png | ToSource $Function:Compressonator .dds
FindModPaths *.dds | ToDist $Function:ConvertToTg .TgPcDx
# Wait for all ConvertToTG.exe jobs to finish (it forks).
while (Get-Process ConvertToTG -ErrorAction SilentlyContinue) {
    Start-Sleep -Milliseconds 1000
}
CopyOutput
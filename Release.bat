rem Build a distributable ZIP archive for a release.

xcopy Mod Release\Assets\ /s /y
copy Readme.md Release\Readme.md

rem Ensure compatibility with Fan Railer's AEM-7 overhaul mod.
copy Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Engine\RailVehicle_EngineScript.out^
    Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Engine\EngineScript.out /y
mkdir "Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Simulation\AC Physics\"
copy NUL "Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Simulation\AC Physics\AEM-7 SimScript.out"
mkdir "Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Simulation\DC Physics\"
copy NUL "Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Simulation\DC Physics\AEM-7 SimScript.out"

del Mod.zip
cd Release\
7z a ..\Mod.zip .
cd ..\
rmdir Release\ /s /q
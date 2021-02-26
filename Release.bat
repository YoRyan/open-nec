rem Build a distributable ZIP archive for a release.

xcopy Mod Release\Assets\ /s /y
rem Ensure compatibility with Fan Railer's AEM-7 overhaul mod.
copy Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Engine\RailVehicle_EngineScript.out^
    Release\Assets\RSC\NorthEastCorridor\RailVehicles\Electric\AEM7\Default\Engine\EngineScript.out /y
del OpenNEC.zip
cd Release\
7z a ..\OpenNEC.zip .
cd ..\
rmdir Release\ /s /q
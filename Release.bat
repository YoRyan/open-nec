rem Build a distributable ZIP archive for a release.

xcopy Mod Release\Assets\ /s /y /exclude:Release-exclude.txt
copy Readme.md Release\Readme.md

del Mod.zip
cd Release\
7z a ..\Mod.zip .
cd ..\
rmdir Release\ /s /q
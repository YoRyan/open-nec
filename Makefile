# Ensure these file paths are correct for your system. You can override them by
# passing new values through the command line.
RAILWORKS_DIR := C:\\Program Files (x86)\\Steam\\steamapps\\common\\RailWorks
COMPRESSONATOR_CLI := C:\\Compressonator_4.1.5083\\bin\\CLI\\compressonatorcli.exe
LUACHECK := luacheck
7ZIP := 7z

all : luac lua0 xml2serz png2tg wav2dav

clean :
	del /s /q Mod

dist : Mod.zip

Mod.zip : all
	xcopy Mod OpenNEC\Assets\ /e /y
	xcopy Docs OpenNEC\Docs\ /e /y
	copy Readme.md OpenNEC\Readme.md
	del Mod.zip
	$(7ZIP) a Mod.zip OpenNEC \
		-x!OpenNEC\Assets\RSC\M8Pack01 \
		-x!OpenNEC\Assets\RSC\NorthEastCorridor\RailNetwork
	rmdir OpenNEC\ /s /q

.PHONY : all clean dist

# enable parallel jobs on Windows
# see https://dannythorpe.com/2008/03/06/parallel-make-in-win32/
SHELL := cmd.exe

# recursive wildcard search
# see https://blog.jgc.org/2011/07/gnu-make-recursive-wildcard-function.html
rwildcard = $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2) $(filter $(subst *,%,$2),$d))

bslash = $(subst /,\,$1)

mkdir = if not exist $(call bslash,$1) mkdir $(call bslash,$1)

#
# Lua bytecode
#

LUASRC := $(call rwildcard,Src/Mod/,*.lua)
LUALIB := $(call rwildcard,Src/Lib/,*.lua)
LUAOUT := $(patsubst Src/Mod/%.lua, Mod/%.out, $(LUASRC))

luac : $(LUAOUT)

Mod/%.out : $(LUALIB) Src/Mod/%.lua
	$(call mkdir,$(@D))
	-$(LUACHECK) $^ --allow-defined-top --no-unused-args --read-globals=Call SysCall
	$(RAILWORKS_DIR)\luac -o $@ $^

#
# 0-byte Lua bytecode
#

LUAEMPTY := $(call rwildcard,Src/Mod/,*.emptylua)
LUAEMPTYOUT := $(patsubst Src/Mod/%.emptylua, Mod/%.out, $(LUAEMPTY))

lua0 : $(LUAEMPTYOUT)

$(LUAEMPTYOUT) :
	$(call mkdir,$(@D))
	copy NUL $(call bslash,$@)

#
# XML -> BIN Serz data
#

XMLSRC := $(call rwildcard,Src/Mod/,*.xml)
XMLOUT := $(patsubst Src/Mod/%.xml, Mod/%.bin, $(XMLSRC))

xml2serz : $(XMLOUT)

Mod/%.bin : Src/Mod/%.xml
	$(call mkdir,$(@D))
	$(RAILWORKS_DIR)\serz $< /xml:$@

#
# PNG -> TgPcDx texture
#

PNGSRC := $(call rwildcard,Src/Mod/,*.png)
PNGOUT := $(patsubst Src/Mod/%.png, Mod/%.TgPcDx, $(PNGSRC))

png2tg : $(PNGOUT)

Mod/%.TgPcDx : Src/Mod/%.dds
	$(call mkdir,$(@D))
	$(RAILWORKS_DIR)\converttotg -forcecompress -i $(call bslash,$<) -o $(call bslash,$@)

%.dds : %.png
	$(COMPRESSONATOR_CLI) -miplevels 5 -fd ARGB_8888 $< $@

#
# WAV -> DAV sound
#

WAVSRC = $(call rwildcard,Src/Mod/,*.wav)
WAVOUT = $(patsubst Src/Mod/%.wav, Mod/%.dav, $(WAVSRC))

wav2dav : $(WAVOUT)

Mod/%.dav : Src/Mod/%.wav
	$(call mkdir,$(@D))
	$(RAILWORKS_DIR)\ConvertToDav -i $< -o $@
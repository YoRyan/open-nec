# Developing for the project

Please use the project's [homepage](https://github.com/YoRYan/open-nec) on GitHub to file issues and submit pull requests.

All code for the Open NEC project is currently written in Lua, plus some Python to automate the building process.

Train Simulator uses Lua 5.0. It will compile .lua files, but if an .out file is present with the same filename, the bytecode will be prioritized over the source file. Therefore, unless we want to require our users to unpack their .ap files, we must replace the target .out file with our own compiled bytecode.

## Repository structure

- `Src\Mod\` maps to Train Simulator's Assets\ folder on a 1:1 basis. Replacement Lua code goes here.
- `Src\Lib\` contains any common Lua code. The build system automatically includes these files when linting or compiling files in Src\\Mod\\.
- `Docs` contains the Markdown text of this manual.
- `wscript` contains build instructions, which are written for WAF.

## Building the project

To compile the mod, you will need the following tools in your `%PATH%`:

- `python.exe`: a recent copy of [Python 3](https://www.python.org/) is required. Our build system uses WAF, which runs on Python.
- `luacheck.exe`: the [Luacheck](https://github.com/mpeterv/luacheck) linter. Its static analysis capabilities are much appreciated for an untyped language like Lua. Although it was designed for Lua 5.1+, it works well enough on 5.0—with the exception of variable length arguments, which it misinterprets as "unused variables." The static Windows executable will work just fine.
- `lua-format.exe`: the [LuaFormatter](https://github.com/Koihik/LuaFormatter) code formatter. You can obtain a [Windows executable](https://github.com/Koihik/vscode-lua-format/tree/master/bin/win32) from the repository for the official Visual Studio Code extension.
- `compressonatorcli.exe`: The CLI version of [AMD's Compressonator](https://gpuopen.com/compressonator/), a tool we use to generate DDS textures.

In the root directory of the project, run `python waf configure` to confirm that your system has met all of these requirements.

The build process also needs to be informed of the location of Train Simulator—the game comes with several essential command-line utilities. The WAF script attempts to infer its location using the Steam uninstallation path in the Registry. If this autodetection fails, you should set the `%RAILWORKS%` environment variable to the path to your copy of Train Simulator.

If all looks good after the configure step, run `python waf build` to compile the project. The compiled files will output to the Mod\ folder, from which they can be copied into Train Simulator's Assets\ folder. (But to ease testing, I recommend using symlinks instead of copying.) The build process will also run LuaFormatter on the code to enforce a consistent style.

Other useful WAF commands include:

- `python waf clean`: delete compiled files in the Mod\\ folder.
- `python waf distclean`: delete the Mod\\ folder entirely.
- `python waf package`: build a redistributable Zip archive for a release.

## Programming resources

- [Lua 5.0 Reference Manual](https://www.lua.org/manual/5.0/manual.html)
- [Programming in Lua, First Edition](https://www.lua.org/pil/contents.html)
- [AndiS's guide to signal messages](https://forums.uktrainsim.com/viewtopic.php?f=359&t=129485)
- [AndiS's guide to AI train behavior](https://www.trainsimdev.com/forum/viewtopic.php?p=509)

The following tools are not needed to compile project, but they may assist you in development work:

- [unluac](https://sourceforge.net/projects/unluac) can be used to decompile and study (to varying degrees of success) Dovetail's Lua bytecode.
- [MkDocs](https://www.mkdocs.org/) is used to build and maintain this manual's Markdown text.
- My [Rail Sim Remote](https://github.com/yoryan/railsim-remote) program exposes Train Simulator's RailDriver interface via a REST API. You can use this in conjunction with cURL or a browser developer console to experiment with a locomotive's controls.
- If you have Discord, join the Train Simulator community for modding tips, street cred, and comradery.

## Coding style

- Please follow the standard Lua style. That means 2-space indents.
- Dovetail's programmers don't take full advantage of the language's features, so don't use their source files as a reference.
- Write packages using PiL's suggested "privacy" [style](https://www.lua.org/pil/15.2.html), and classes using PiL's suggested "basic" [style](https://www.lua.org/pil/16.1.html). You should also check out Dovetail's own [Train Simulator SDK](https://sites.google.com/a/railsimdev.com/dtgts1sdk/reference-manual) docs—even if they are, unfortunately, incomplete.
- I use coroutines to keep the modeling of many independent subsystems down to a manageable level of complexity. They work perfectly in Train Simulator, with the exception of `Call()` and `SysCall()`, which only work from the main coroutine. I've created the `Scheduler` package to centralize the management of coroutines. Please do learn to use it, especially its `:select()` method.
- Lua places heavy emphasis on tables and their `pairs()` and `ipairs()` iterators. I've created the `Iterator` package to introduce useful transformations and compositions for such key-value iterators.

## Reference material

- [NORAC signal rules](https://signals.jovet.net/rules/NORAC%20Signal%20Rules.pdf)
- [cActUsjUiCe's guide to the Northeast Corridor](https://forums.dovetailgames.com/threads/nec-ny-signal-tutorials.4174/)
- [cActUsjUiCe's critique of Train Sim World](https://forums.dovetailgames.com/threads/nec-new-york-signals-atc-acses-and-how-to-fix-them.4057/)
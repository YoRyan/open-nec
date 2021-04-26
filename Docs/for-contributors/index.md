# Developing for the project

Please use the project's [homepage](https://github.com/YoRYan/open-nec) on GitHub to file issues and submit pull requests.

All code for the Open NEC project is currently written in Lua, plus some MSBuild and Batch to automate the building process.

Train Simulator uses Lua 5.0. It will compile .lua files, but if an .out file is present with the same filename, the bytecode will be prioritized over the source file. Therefore, we must replace the target .out file with our own compiled bytecode.

## Repository structure

- `Src\Mod\` maps to Train Simulator's Assets\ folder on a 1:1 basis. Replacement Lua code goes here.
- `Src\Lib\` contains any common Lua code. The build system automatically includes these files when linting or compiling files in Mod\\.
- `Src\Lua.xml` and `Src\OpenNec.proj` contain the MSBuild definitions used to build the project.
- `Release.bat` is used to produce a new release.
- `Docs` contains the Markdown text of this manual.

## Building the project

To compile the mod, you will need the following tools in your `%PATH%`:

- `MSBuild.exe`: Microsoft's take on the Makefile. This comes with any installation of Visual Studio. From VS, you can [open](https://docs.microsoft.com/en-us/dotnet/framework/tools/developer-command-prompt-for-vs) a developer console with this tool already included in `%PATH%`.
- `luacheck.exe`: the [Luacheck](https://github.com/mpeterv/luacheck) linter. Its static analysis capabilities are much appreciated for an untyped language like Lua. Although it was designed for Lua 5.1+, it works well enough on 5.0—with the exception of variable length arguments, which it misinterprets as "unused variables." The static Windows executable will work just fine.
- `compressonatorcli.exe`: The CLI version of [AMD's Compressonator](https://gpuopen.com/compressonator/), a tool we use to generate DDS textures.
- `luac.exe`: the Lua 5.0 compiler. A copy is included with the game.
- `serz.exe`: Train Simulator's .bin data packer. Included with the game.
- `ConvertToDav.exe`: Train Simulator's .dav sound compiler. Included with the game.
- `ConvertToTg.exe`: Train Simulator's .TgPcDx texture compiler. Included with the game.

It also helps to have the following tools handy:

- [unluac](https://sourceforge.net/projects/unluac) to decompile and study (to varying degrees of success) Dovetail's Lua bytecode.
- [MkDocs](https://www.mkdocs.org/) to build and maintain this manual's Markdown text.
- My [Rail Sim Remote](https://github.com/yoryan/railsim-remote) program, which exposes Train Simulator's RailDriver interface via a REST API. You can use this in conjunction with cURL or a browser developer console to experiment with a locomotive's controls.
- Discord so you can join the Train Simulator community for modding tips, street cred, and comradery.

With all of the tools installed and available in `%PATH%`, you run

```msbuild Src\\OpenNec.proj /t:build```

to build the project. The compiled files will output to the Mod\ folder, from which they can be copied into Train Simulator's Assets\ folder. But to ease testing, I recommend using symlinks instead of copying.

#### Suggested tasks.json for Visual Studio Code

```json
{
    // See https://go.microsoft.com/fwlink/?LinkId=733558
    // for the documentation about the tasks.json format
    "version": "2.0.0",
    "tasks": [
        {
            "label": "build",
            "type": "shell",
            "command": "C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\Community\\MSBuild\\Current\\Bin\\MSBuild.exe",
            "args": [
                "Src\\OpenNec.proj",
                "/t:build"
            ],
            "options": {
                "env": {
                    "PATH": "C:\\Users\\Ryan\\Downloads\\Programs\\luacheck;C:\\Program Files (x86)\\Steam\\steamapps\\common\\RailWorks;C:\\Compressonator_4.1.5083\\bin\\CLI"
                }
            },
            "group": {
                "kind": "build",
                "isDefault": true
            },
            "presentation": {
            },
            "problemMatcher": "$msCompile"
        }
    ]
}
```

## Programming resources

- [Lua 5.0 Reference Manual](https://www.lua.org/manual/5.0/manual.html)
- [Programming in Lua, First Edition](https://www.lua.org/pil/contents.html)
- [AndiS's guide to signal messages](https://forums.uktrainsim.com/viewtopic.php?f=359&t=129485)
- [AndiS's guide to AI train behavior](https://www.trainsimdev.com/forum/viewtopic.php?p=509)
- [NORAC signal rules](https://signals.jovet.net/rules/NORAC%20Signal%20Rules.pdf)

## Coding style

- Please follow the standard Lua style. That means 2-space indents.
- Dovetail's programmers don't take full advantage of the language's features, so don't use their source files as a reference.
- Write packages using PiL's suggested "privacy" [style](https://www.lua.org/pil/15.2.html), and classes using PiL's suggested "basic" [style](https://www.lua.org/pil/16.1.html). You should also check out Dovetail's own [Train Simulator SDK](https://sites.google.com/a/railsimdev.com/dtgts1sdk/reference-manual) docs—even if they are, unfortunately, incomplete.
- I use coroutines to keep the modeling of many independent subsystems down to a manageable level of complexity. They work perfectly in Train Simulator, with the exception of `Call()` and `SysCall()`, which only work from the main coroutine. I've created the `Scheduler` package to centralize the management of coroutines. Please do learn to use it, especially its `:select()` method.
- Lua places heavy emphasis on tables and their `pairs()` and `ipairs()` iterators. I've created the `Iterator` package to introduce useful transformations and compositions for such key-value iterators.
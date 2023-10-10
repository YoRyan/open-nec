![Open NEC logo](https://opennec.trinancrat.me/assets/opennec-logo.svg)

Open NEC is a free and open-source Train Simulator Classic mod that greatly enhances the functionality of passenger locomotives released for the Northeast Corridor (Washington, D.C. to Boston) locale. It’s a complete rescripting effort, using code written from scratch, to achieve an ultra-realistic driving experience.

To learn more, visit the [project homepage](https://opennec.trinancrat.me).

## Build the project

Open the project in its development container and run `npm run build`. The resulting engine scripts will be output to the `dist/` folder.

You also need to build the blueprint files, textures, and sounds using the tools shipped with Train Simulator. To do this, you will need the game installed, and you will also need a copy of [AMD Compressonator](https://gpuopen.com/compressonator/). Run `BuildAssets.ps1` and the assets will be output to the `dist/` folder.

If you are working with the source code in Windows Subsystem for Linux, you cannot just run `BuildAssets.ps1` from Windows because the Train Simulator tooling does not work with a UNC path like `\\wsl.localhost\`. As a workaround, you can [map WSL as a network drive](https://stackoverflow.com/a/71002897) using `net use`. The tooling works just fine as long as it is using paths that start with drive letters.

## Style guidelines

To lint your code, run `npm run fix:prettier`. I ask that any contributions conform to prettier's recommendations.

## Legal

All content in this repository is [licensed](License.md) under the GNU General Public License, version 3.

# railworks-tstl-template

Write scripts for Train Simulator Classic in TypeScript with the help of [TypeScriptToLua](https://typescripttolua.github.io/)! With TypeScript, you benefit from strong typing guarantees, modern tooling, and a vibrant community of users, which all add up to a vastly superior development experience compared to the Lua 5.0 ecosystem that Train Simulator ships with. It's like upgrading from a 🚂 to a 🚅.

This template includes type declarations and wrappers for Train Simulator's Lua API and a [functional reactive programming library](https://github.com/santoshrajan/frpjs) suitable for building engine scripts with.

## Scripts

| Command                | Description                                                                     |
| ---------------------- | ------------------------------------------------------------------------------- |
| `npm run lint`         | Check for linting issues with Prettier.                                         |
| `npm run fix:prettier` | Fix linting issues identified by Prettier.                                      |
| `npm run watch`        | Watch TypeScript files for changes and rebuild them as needed.                  |
| `npm run build`        | Transpile TypeScript source files to Lua bytecode suitable for Train Simulator. |

To install your newly built files, copy the contents of the dist/ folder to your Steam RailWorks folder.

## Development container

This template also includes a Visual Studio Code development container with all the necessary Node.js and Lua tooling to build a project.

/**
 * Load and execute a string of embedded Lua code.
 * @param source The Lua code, which can be in source form, or in bytecode form
 * as produced by luac. Bytecode can be embedded with Lua escape sequences
 * (as in "\27\76\117") but due to
 * https://github.com/TypeScriptToLua/TypeScriptToLua/issues/1551, these
 * sequences are not currently compatible with TypeScriptToLua.
 * @returns The value returned by the Lua code.
 */
export function loadScript(source: string) {
    const [chunk] = loadstring(source);
    if (chunk) {
        return chunk();
    } else {
        return undefined;
    }
}

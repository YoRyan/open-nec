# encoding: utf-8

import itertools
import re
import os
import winreg
from zipfile import ZipFile, ZIP_LZMA

from waflib.Task import Task


APPNAME = 'OpenNEC'
VERSION = '0.5.0'

top = '.'
out = 'Mod'


def configure(conf):
    # RailWorks game and utilities
    conf.env.RAILWORKS = os.environ.get('RAILWORKS', None)
    if not conf.env.RAILWORKS:
        try:
            reg = winreg.ConnectRegistry(None, winreg.HKEY_LOCAL_MACHINE)
            key = 'SOFTWARE\\Microsoft\\Windows\\' \
                'CurrentVersion\\Uninstall\\Steam App 24010'
            conf.env.RAILWORKS, _ = \
                winreg.QueryValueEx(winreg.OpenKey(reg, key), 'InstallLocation')
        except OSError:
            conf.env.RAILWORKS = \
                r'C:\Program Files (x86)\Steam\steamapps\common\RailWorks'
    conf.msg('Setting Train Simulator path to', conf.env.RAILWORKS, color='CYAN')

    # other dependencies
    conf.find_program('CompressonatorCLI')
    conf.find_program('luacheck')
    conf.find_program('lua-format')


def build(bld):
    out = bld.root.make_node(bld.out_dir)
    mod = bld.path.find_node('Src/Mod')
    lib = bld.path.find_node('Src/Lib')

    # Building tasks by hand like this is super ghetto, but it gives us precise
    # control over every step.
    # There's likely some WAF syntactic sugar I'm missing here...

    class ConvertToDav(Task):
        def run(self):
            return self.exec_command(
                f'"{self.env.RAILWORKS}/ConvertToDav" '
                f'-i "{self.inputs[0].abspath()}" '
                f'-o "{self.outputs[0].abspath()}"')

    class Compressonator(Task):
        def run(self):
            return self.exec_command(
                f'CompressonatorCLI -miplevels 5 -fd ARGB_8888 '
                f'"{self.inputs[0].abspath()}" '
                f'"{self.outputs[0].abspath()}"')

    class ConvertToTg(Task):
        def run(self):
            return self.exec_command(
                f'"{self.env.RAILWORKS}/ConvertToTg" -forcecompress '
                f'-i "{self.inputs[0].abspath()}" '
                f'-o "{self.outputs[0].abspath()}"')

    class Serz(Task):
        def run(self):
            return self.exec_command(
                f'"{self.env.RAILWORKS}/serz" '
                f'"{self.inputs[0].abspath()}" '
                f'/xml:"{self.outputs[0].abspath()}"')

    class Luac(Task):
        def run(self):
            # Use relative paths to minimize the length of the command.
            cwd = self.get_cwd()
            return self.exec_command(
                f'"{self.env.RAILWORKS}/luac" '
                f'-o "{self.outputs[0].path_from(cwd)}" '
                + ' '.join(f'"{inp.path_from(cwd)}"' for inp in self.inputs))

    class LuaFormat(Task):
        def run(self):
            config = bld.path.find_node('luaformatter.cfg')
            return self.exec_command(
                f'lua-format --config="{config.abspath()}" --in-place '
                f'"{self.inputs[0].abspath()}"')

    class Luacheck(Task):
        def run(self):
            # Use relative paths to minimize the length of the command.
            cwd = self.get_cwd()
            return self.exec_command(
                f'luacheck --allow-defined-top --no-unused-args '
                + ' '.join(f'"{inp.path_from(cwd)}"' for inp in self.inputs)
                + ' --read-globals Call SysCall '
                '--ignore Initialise Update OnControlValueChange '
                    'OnCustomSignalMessage OnConsistMessage '
                    'OnSignalMessage OnConsistPass')

    def maketask(cls, inputs, outputs, **kwargs):
        task = cls(env=bld.env, **kwargs)
        task.set_inputs(inputs)
        task.set_outputs(outputs)
        return task

    def lualibs(src):
        nodes = set()
        with open(src.abspath(), 'rt') as f:
            for line in f:
                m = re.search(r'^--\s*@include\s+([^\s]+)\s*$', line)
                if m:
                    path = m.group(1)
                    node = lib.find_node(path)
                    if not node:
                        bld.fatal(f'Lua library not found: {path}')
                    nodes.add(node)
                    nodes.update(lualibs(node))
        return nodes

    def maketasks(src):
        tgt = out.make_node(src.path_from(mod))
        ext = src.suffix()
        if ext == '.wav':
            return (
                maketask(ConvertToDav, [src], [tgt.change_ext('.dav')]),
            )
        elif ext == '.png':
            dds = tgt.change_ext('.dds')
            return (
                maketask(Compressonator, [src], [dds]),
                maketask(ConvertToTg, [dds], [tgt.change_ext('.TgPcDx')])
            )
        elif ext == '.xml':
            return (
                maketask(Serz, [src], [tgt.change_ext('.bin')]),
            )
        elif ext == '.lua':
            libs = lualibs(src)
            lint = maketask(Luacheck, [*libs, src], [],
                            always_run=True, before=[LuaFormat])
            formats = (maketask(LuaFormat, file, [], always_run=True, before=[Luac])
                       for file in [*libs, src])
            return (
                lint,
                *formats,
                maketask(Luac, [*libs, src], [tgt.change_ext('.out')])
            )
        else:
            return ()

    for task in itertools.chain(*(maketasks(f) for f in mod.ant_glob('**/*'))):
        bld.add_to_group(task)


def package(ctx):
    exclude = [
        '.*',
        'c4che',
        'config.log',

        '**/*.dds',

        'RSC/M8Pack01/**/*',
    ]
    root = f'{APPNAME}-{VERSION}'
    out_dir = ctx.path.find_node(out)
    with ZipFile(f'{APPNAME}-{VERSION}.zip', 'w', compression=ZIP_LZMA) as zip:
        for f in out_dir.ant_glob('**/*', excl=exclude):
            zip.write(f.abspath(), arcname=f'{root}/Assets/{f.path_from(out_dir)}')
        for f in ctx.path.ant_glob('Docs/**/*'):
            zip.write(f.abspath(), arcname=f'{root}/{f.path_from(ctx.path)}')
        zip.write('Readme.md', arcname=f'{root}/Readme.md')

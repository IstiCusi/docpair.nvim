#!/usr/bin/env python3
"""Smoke test with Neovim's real terminal UI and typed keys, not --headless.

Commands/navigation go through a pseudo-terminal. A Lua command records state
to a temporary JSON file for assertions. Dependency: pexpect.
"""
import argparse
import json
import os
import tempfile
import time
from pathlib import Path

import pexpect

parser = argparse.ArgumentParser()
parser.add_argument('--nvim', default='nvim')
parser.add_argument('--output')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
steps = []

with tempfile.TemporaryDirectory(prefix='docpair-tui-') as directory:
    root = Path(directory)
    (root/'.documented').mkdir()
    for name, lines in [('large.c',50000),('other.c',80000)]:
        (root/name).write_text(''.join(f'int counter_{i} = {i};\n' for i in range(lines)))
        (root/'.documented'/(name+'_info')).write_text(''.join(f'## {name} line {i+1}: purpose and boundary cases\n' for i in range(lines)))
    init = root/'init.lua'
    state_file=root/'state.json'
    init.write_text('vim.opt.rtp:append('+json.dumps(str(repo))+')\n'
                    'vim.opt.number=true\nvim.opt.mouse="a"\n'
                    'vim.opt.hidden=true\nvim.opt.swapfile=false\n'
                    'vim.opt.shortmess:append("I")\nrequire("docpair").setup({})\n'
                    'function DocpairSnapshot()\n'
                    'local state={pairs=require("docpair").inspect(),current=vim.api.nvim_get_current_win()}\n'
                    'for _,p in ipairs(state.pairs) do\n'
                    'p.actual_source=vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(p.source_window))\n'
                    'p.actual_notes=vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(p.notes_window))\n'
                    'p.note_line=vim.api.nvim_buf_get_lines(p.notes_buffer,24999,25000,false)[1]\n'
                    'end\nvim.fn.writefile({vim.json.encode(state)},'+json.dumps(str(state_file))+')\nend\n')
    terminal = pexpect.spawn(args.nvim,['-u',str(init),'-i','NONE'],
                              encoding='utf-8',timeout=5,dimensions=(40,160),env={**os.environ,'TERM':'xterm-256color'})

    def drain():
        # Drain output so redraws cannot block on the PTY's finite output buffer.
        while True:
            try:terminal.read_nonblocking(65536,timeout=.04)
            except pexpect.TIMEOUT:return

    try:
        drain()

        def type_keys(keys):
            terminal.send(keys);drain()

        def check(label, count, filename=None):
            if state_file.exists():state_file.unlink()
            type_keys(':lua DocpairSnapshot()\r')
            deadline=time.monotonic()+5
            while not state_file.exists() and time.monotonic()<deadline:drain()
            snapshot=json.loads(state_file.read_text());state=snapshot['pairs']
            assert len(state)==count,(label,state)
            for pair in state:
                for role in ['source','notes']:
                    assert pair['actual_'+role]==pair[role]
            if filename:
                pair=next(p for p in state if snapshot['current'] in [p['source_window'],p['notes_window']])
                assert Path(pair['source']).name==filename,(label,pair)
            steps.append({'step':label,'pairs':count,'passed':True})
            return state

        type_keys(':Documented '+str(root/'large.c')+'\r');check('open 50,000 lines',1,'large.c')
        type_keys('25000Gzt');check('jump and scroll',1)
        type_keys('\x17l');type_keys('iA note entered through the terminal. \x1b')
        p=check('edit notes in terminal',1)[0]
        assert 'A note entered' in p['note_line']
        type_keys('\x17h');type_keys(':edit '+str(root/'other.c')+'\r');check('edit other source',1,'other.c')
        type_keys(':tab split\r');check('native tab split',2)
        type_keys('gt');type_keys('gT');check('native gt and gT',2)
        type_keys(':only\r');check('only retains a complete pair',2)
        type_keys('\x17T');check('Ctrl-W T moves a complete pair',2)
        type_keys(':tabclose\r');check('tabclose keeps remaining tab',1)
        type_keys(':edit '+str(root/'large.c')+'\r');p=check('return to edited notes',1,'large.c')[0]
        assert 'A note entered' in p['note_line']
        type_keys(':wall\r');check('save source and notes',1)
        # :tabonly removes the original empty tab. :q must then quit the final
        # pair rather than resurrecting a companion forever.
        type_keys(':tabonly\r');check('tabonly',1)
        type_keys(':lua vim.api.nvim_open_win(vim.api.nvim_create_buf(false,true),false,{relative="editor",row=2,col=3,width=30,height=5})\r')
        check('unfocused floating window beside final pair',1)
        terminal.send(':q\r');terminal.expect(pexpect.EOF);terminal.close()
        assert terminal.exitstatus==0,terminal.exitstatus
        steps.append({'step':'quit final pair exits cleanly','passed':True})
    finally:
        if terminal.isalive():terminal.close(force=True)

report={'interface':'Neovim terminal UI on a pseudo-terminal','steps':steps,'passed':len(steps)}
if args.output:Path(args.output).write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))

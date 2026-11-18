#!/usr/bin/env python3
"""Typed-key regression for comment views in a real Neovim terminal."""
import argparse
import json
import os
import tempfile
import time
from pathlib import Path
import pexpect

parser=argparse.ArgumentParser()
parser.add_argument('--nvim',default='nvim')
parser.add_argument('--output')
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1]
steps=[]

with tempfile.TemporaryDirectory(prefix='docpair-comment-tui-') as directory:
    root=Path(directory)
    source=root/'large.c'
    source.write_text('/**\n'+''.join(' * Paragraph '+str(i)+' explains this short function.\n' for i in range(1000))
        +' */\nint first(void) { return 1; }\n'+''.join('int value_'+str(i)+' = 0;\n' for i in range(50000))
        +'/// Second function\nint second(void) { return 2; }\n')
    state_file=root/'state.json'
    init=root/'init.lua'
    init.write_text('vim.opt.rtp:append('+json.dumps(str(repo))+')\n'
      'vim.opt.hidden=true;vim.opt.swapfile=false;vim.opt.shortmess:append("I")\n'
      'vim.cmd("filetype plugin on");vim.cmd("syntax enable")\n'
      'require("docpair").setup({})\n'
      'function DocpairSnapshot()\n'
      'vim.wait(120) -- allow scheduled lifecycle/source callbacks to settle\n'
      'local data={pairs=require("docpair").inspect(),current=vim.api.nvim_get_current_win(),messages=vim.api.nvim_exec2("messages",{output=true}).output}\n'
      'for _,p in ipairs(data.pairs) do\n'
      'p.source_cursor=vim.api.nvim_win_get_cursor(p.source_window)\n'
      'p.doc_cursor=vim.api.nvim_win_get_cursor(p.notes_window)\n'
      'p.first=vim.api.nvim_buf_get_lines(p.doc_buffer,0,1,false)[1]\n'
      'p.count=vim.api.nvim_buf_line_count(p.doc_buffer)\n'
      'p.actual_doc=vim.api.nvim_win_get_buf(p.notes_window)\n'
      'end\nvim.fn.writefile({vim.json.encode(data)},'+json.dumps(str(state_file))+')\nend\n')
    terminal=pexpect.spawn(args.nvim,['-u',str(init),'-i','NONE'],encoding='utf-8',timeout=8,
      dimensions=(45,160),env={**os.environ,'TERM':'xterm-256color'})

    def drain():
        while True:
            try:terminal.read_nonblocking(65536,timeout=.06)
            except pexpect.TIMEOUT:return

    def keys(value):terminal.send(value);drain()

    def check(label,mode=None,count=1):
        if state_file.exists():state_file.unlink()
        keys(':lua DocpairSnapshot()\r')
        deadline=time.monotonic()+8
        while not state_file.exists() and time.monotonic()<deadline:drain()
        data=json.loads(state_file.read_text())
        assert len(data['pairs'])==count,(label,data)
        current=next(p for p in data['pairs'] if data['current'] in [p['source_window'],p['notes_window']])
        if mode:assert current['view']==mode,(label,current)
        for p in data['pairs']:assert p['actual_doc']==p['doc_buffer'],(label,p)
        steps.append({'step':label,'passed':True})
        return current

    try:
        drain();keys(':Documented! '+str(source)+'\r')
        p=check('open 51,005 source lines with 1,000-line comment','text')
        assert p['count']==1000 and p['source_cursor'][0]==1003,p
        keys('\x17l');keys('Gzt');p=check('scroll documentation independently','text')
        assert p['doc_cursor'][0]==1000 and p['source_cursor'][0]==1003,p
        keys('ggIAdditional: \x1b');p=check('edit comment in text view','text')
        assert p['first'].startswith('Additional: '),p
        keys('g\t');check('g<Tab> selects Markdown','markdown')
        keys('g\t');p=check('g<Tab> selects original comment','raw');assert p['first']=='/**',p
        keys('g\t');check('g<Tab> selects external notes','notes')
        keys('ggIExternal notebook entry\x1b')
        keys('g\t');p=check('g<Tab> returns to source comment','text');assert p['first'].startswith('Additional: '),p
        keys('\x17h');keys('51005G');p=check('source cursor selects second function','text')
        assert p['first']=='Second function',p
        keys('\x17l');keys('A edited\x1b');keys(':write\r')
        check('write from projection saves ordinary C file','text')
        assert '/// Second function edited' in source.read_text()
        keys(':tab split\r');p=check('tab split preserves second section','text',2)
        assert p['first']=='Second function edited',p
        keys('g\t');check('second tab chooses its own Markdown view','markdown',2)
        keys('gT');check('original tab retains text view','text',2)
        keys(':only\r');check('only keeps complete pair','text',2)
        keys(':wall\r');check('save comments and external notes','text',2)
        assert (root/'.documented/large.c_info').read_text().startswith('External notebook entry')
        keys(':tabonly\r');check('tabonly retains one pair','text')
        terminal.send(':q\r');terminal.expect(pexpect.EOF);terminal.close()
        assert terminal.exitstatus==0,terminal.exitstatus
        steps.append({'step':'quit last pair cleanly','passed':True})
    finally:
        if terminal.isalive():terminal.close(force=True)

report={'interface':'real terminal with filetype plugins and syntax highlighting','passed':len(steps),'steps':steps}
if args.output:Path(args.output).write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))

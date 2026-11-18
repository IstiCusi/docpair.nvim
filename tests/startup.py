#!/usr/bin/env python3
"""Exercise native plugin sourcing before Lazy-style explicit setup.

Unlike the integration fixtures, this does not initialize setup before
plugin/docpair.lua is sourced. This is the ordering that caused E5113.
"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--nvim',required=True)
parser.add_argument('--output')
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='docpair-startup-') as directory:
    root=Path(directory)
    script=root/'startup.lua'
    source=root/'example.c'
    source.write_text('/// Existing documentation\nint example(void) {return 1;}\n')
    report_file=root/'report.json'
    script.write_text('vim.opt.rtp:prepend('+json.dumps(str(repo))+')\n'
      'vim.cmd("runtime plugin/docpair.lua")\n'
      'assert(vim.fn.exists(":Documented")==2,"native loader must register Documented")\n'
      'local c=require("docpair.compat").capabilities()\n'
      'if c.supported then\n'
      'assert(require("docpair").setup({mappings={cycle="gV"}}))\n'
      'vim.cmd("Documented! "..vim.fn.fnameescape('+json.dumps(str(source))+'))\n'
      'vim.wait(150)\n'
      'local pairs=require("docpair").inspect();assert(#pairs==1,"pair must open")\n'
      'local p=pairs[1];vim.api.nvim_set_current_win(p.notes_window)\n'
      'assert(vim.fn.maparg("gV","n")~="","explicit options must win")\n'
      'vim.api.nvim_buf_set_lines(p.doc_buffer,0,-1,false,{"Changed through comment view"})\n'
      'vim.cmd("write")\n'
      'vim.cmd("DocumentedView raw");vim.cmd("DocumentedView text")\n'
      'vim.cmd("tab split");vim.wait(150);assert(#require("docpair").inspect()==2)\n'
      'vim.cmd("checkhealth docpair")\n'
      'assert(not vim.api.nvim_exec2("messages",{output=true}).output:find("E5113",1,true))\n'
      'end\n'
      'vim.fn.writefile({vim.json.encode({passed=true,version=c.version,hide_comments=c.hide_comments,supported=c.supported})},'
      +json.dumps(str(report_file))+')\n'
      'vim.cmd("qa!")\n')
    result=subprocess.run([args.nvim,'--headless','-u','NONE','-i','NONE','-l',str(script)],capture_output=True,text=True,timeout=20)
    assert result.returncode==0,(result.stdout,result.stderr)
    assert report_file.exists(),(result.stdout,result.stderr)
    report=json.loads(report_file.read_text())
    if report['supported']:assert source.read_text().startswith('/// Changed through comment view\n')
    if args.output:Path(args.output).write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))

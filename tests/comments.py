#!/usr/bin/env python3
"""Projection integration tests: real Neovim, actual source writes and UI input.

Includes lossless round trips, independent tabs, stale edits, invalid drafts,
source undo, native sessions, language fixtures and a large inline document.
"""
import argparse
import json
import tempfile
import time
import unittest
from pathlib import Path
import pynvim

parser = argparse.ArgumentParser()
parser.add_argument('--nvim', default='nvim')
parser.add_argument('--output')
args = parser.parse_args()
REPO = Path(__file__).resolve().parents[1]
TIMINGS = []
SOURCE = '''/**
 * # First function
 *
 * A detailed explanation.
 * * Markdown list
 */
int first(void) {
    int number = 1;
    return number;
}

/// # Second function
/// Another explanation.
int second(void) {
    return 2;
}
'''


class Comments(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='docpair-comments-')
        self.root = Path(self.temp.name)
        self.path = self.root / 'sample.c'
        self.path.write_text(SOURCE)
        self.n = pynvim.attach('child', argv=[args.nvim, '--embed', '--headless', '-u', 'NONE', '-i', 'NONE', '-n'])
        self.n.ui_attach(180, 50, rgb=True)
        self.n.exec_lua('''
          vim.opt.rtp:append(...)
          vim.opt.hidden = true
          vim.opt.shortmess:append('I')
          _G.messages={}
          vim.notify=function(m,l) table.insert(_G.messages,{text=tostring(m),level=l or 2}) end
          require('docpair').setup({})
        ''', str(REPO))

    def tearDown(self):
        try: self.n.command('qa!')
        except (EOFError, OSError): pass
        self.n.close()
        self.temp.cleanup()

    def settle(self): self.n.exec_lua('vim.wait(100);vim.cmd("redraw")')
    def can_hide(self): return self.n.exec_lua('return require("docpair.compat").capabilities().hide_comments')
    def cmd(self, cmd): self.n.command(cmd); self.settle()
    def keys(self, keys): self.n.input(keys); self.settle()
    def pairs(self): return self.n.exec_lua('return require("docpair").inspect()')
    def pair(self):
        w=self.n.current.window.handle
        return next(p for p in self.pairs() if w in (p['source_window'],p['notes_window']))
    def open(self, path=None):
        self.cmd('Documented! '+self.n.funcs.fnameescape(str(path or self.path)))
        return self.pair()
    def focus(self, p, role='source'): self.n.api.set_current_win(p[role+'_window']);self.settle()
    def lines(self, b): return self.n.api.buf_get_lines(b,0,-1,False)
    def doc(self): return self.lines(self.pair()['doc_buffer'])
    def edit(self, lines):
        p=self.pair();self.focus(p,'notes')
        self.n.api.buf_set_lines(p['doc_buffer'],0,-1,False,lines);self.settle()
    def check_pairs(self, count):
        self.assertEqual(len(self.pairs()),count)
        for p in self.pairs():
            self.assertEqual(self.n.api.win_get_buf(p['source_window']).handle,p['source_buffer'])
            self.assertEqual(self.n.api.win_get_buf(p['notes_window']).handle,p['doc_buffer'])
            self.assertEqual(self.n.api.win_get_tabpage(p['source_window']),self.n.api.win_get_tabpage(p['notes_window']))
        errors=self.n.exec_lua('return vim.tbl_filter(function(m) return m.level>=4 end,messages)')
        self.assertEqual(errors,[],errors)

    def test_default_text_and_no_sidecar(self):
        p=self.open()
        self.assertEqual(p['view'],'text')
        self.assertEqual(self.doc(),['# First function','','A detailed explanation.','* Markdown list'])
        self.assertFalse((self.root/'.documented').exists())
        self.assertFalse(self.n.buffers[p['source_buffer']].options['modified'])
        self.check_pairs(1)

    def test_scope_switch_and_cursor_independence(self):
        p=self.open();self.keys('9G')
        self.assertEqual(self.doc()[0],'# First function')
        self.focus(p,'notes');self.keys('G')
        self.assertEqual(self.n.api.win_get_cursor(p['source_window'])[0],9)
        self.focus(p);self.keys('15G')
        self.assertEqual(self.doc()[0],'# Second function')
        self.focus(p);self.keys('9G')
        self.assertEqual(self.n.api.win_get_cursor(p['notes_window'])[0],4)

    def test_blank_between_scopes(self):
        self.open();self.keys('11G')
        self.assertEqual(self.doc(),[''])
        self.assertFalse(self.n.current.buffer.options['modified'])

    def test_default_mapping_cycles_only_document(self):
        p=self.open()
        self.assertEqual(self.n.exec_lua('return vim.fn.maparg("g<Tab>","n")'),'')
        self.focus(p,'notes')
        for name in ['markdown','raw','notes','text']:
            self.keys('g\t');self.assertEqual(self.pair()['view'],name)
        self.assertFalse(self.n.buffers[p['source_buffer']].options['modified'])

    def test_configured_key_order_and_initial_view(self):
        self.n.exec_lua('require("docpair").setup({initial_view="raw",views={"raw","text"},mappings={cycle="gV",create=false,source=false}})')
        p=self.open();self.assertEqual(p['view'],'raw');self.focus(p,'notes')
        self.keys('gV');self.assertEqual(self.pair()['view'],'text')
        self.keys('gV');self.assertEqual(self.pair()['view'],'raw')
        self.assertEqual(self.n.exec_lua('return vim.fn.maparg("g<Tab>","n")'),'')

    def test_edit_and_write_projection(self):
        p=self.open();self.edit(['# New title','','* first','* second','Third paragraph'])
        self.assertTrue(self.n.buffers[p['source_buffer']].options['modified'])
        self.assertFalse(self.n.buffers[p['doc_buffer']].options['modified'])
        self.cmd('write')
        self.assertIn(' * * second',self.path.read_text())
        self.assertIn('int second(void)',self.path.read_text())
        self.assertFalse((self.root/'.documented').exists())

    def test_immediate_save_flushes_pending_edit(self):
        p=self.open()
        self.n.exec_lua('''local p=...;vim.api.nvim_buf_set_lines(p.doc_buffer,0,-1,false,{'Immediate'});
          vim.api.nvim_buf_call(p.source_buffer,function() vim.cmd('write') end)''',p)
        self.assertIn('Immediate',self.path.read_text());self.settle()

    def test_noop_all_modes_byte_identical(self):
        p=self.open();original=self.path.read_bytes()
        for mode in ['raw','markdown','text']:
            self.cmd('DocumentedView '+mode)
            self.assertFalse(self.n.buffers[p['source_buffer']].options['modified'])
        self.focus(p,'notes');self.cmd('write')
        self.assertEqual(self.path.read_bytes(),original)

    def test_markdown_asterisks_preserved(self):
        p=self.open();self.edit(['* item','**bold**','```c','int x;','```'])
        self.cmd('DocumentedView raw')
        self.assertIn(' * * item',self.doc())
        self.cmd('DocumentedView markdown');self.assertEqual(self.doc()[1],'**bold**')
        self.assertEqual(self.n.buffers[p['doc_buffer']].options['filetype'],'markdown')

    def test_raw_edit(self):
        p=self.open();self.cmd('DocumentedView raw')
        self.edit(['/**',' * Raw changed',' */'])
        self.cmd('DocumentedView text');self.assertEqual(self.doc(),['Raw changed'])
        self.assertIn(' * Raw changed',self.lines(p['source_buffer']))

    def test_invalid_block_delimiter_preserves_draft_and_source(self):
        p=self.open();before=self.lines(p['source_buffer'])
        self.edit(['unsafe */ int executable;'])
        self.assertEqual(self.lines(p['source_buffer']),before)
        self.assertTrue(self.n.buffers[p['doc_buffer']].options['modified'])
        self.cmd('DocumentedView raw');self.assertEqual(self.pair()['view'],'text')
        with self.assertRaises(Exception): self.n.command('write')
        self.cmd('DocumentedDiscard');self.assertEqual(self.doc()[0],'# First function')

    def test_invalid_raw_not_accepted(self):
        p=self.open();self.cmd('DocumentedView raw');before=self.lines(p['source_buffer'])
        self.edit(['/** ok */','int injected;'])
        self.assertEqual(self.lines(p['source_buffer']),before)
        self.assertTrue(self.n.buffers[p['doc_buffer']].options['modified'])

    def test_stale_projection_does_not_overwrite(self):
        p=self.open();self.focus(p,'notes')
        self.n.exec_lua('''local p=...;
          vim.api.nvim_buf_set_lines(p.source_buffer,1,2,false,{' * External edit'});
          vim.api.nvim_buf_set_lines(p.doc_buffer,0,-1,false,{'Stale edit'})''',p)
        self.settle()
        self.assertIn(' * External edit',self.lines(p['source_buffer']))
        self.assertEqual(self.doc(),['Stale edit'])
        self.assertTrue(self.n.buffers[p['doc_buffer']].options['modified'])

    def test_source_undo_redo_from_document(self):
        p=self.open();self.edit(['Changed'])
        self.keys('u');self.assertEqual(self.doc()[0],'# First function')
        self.keys('\x12');self.assertEqual(self.doc(),['Changed'])

    def test_insert_session_undo_groups_multiple_keystrokes(self):
        p=self.open();self.focus(p,'notes')
        self.keys('iA');self.keys('B');self.keys('C');self.keys('\x1b')
        self.assertEqual(self.doc()[0],'ABC# First function')
        self.keys('u');self.assertEqual(self.doc()[0],'# First function')

    def test_cannot_create_inside_multiline_string(self):
        path=self.root/'literal.py';path.write_text('text = """\ncontent\n"""\n')
        p=self.open(path);self.keys('2G');before=self.lines(p['source_buffer'])
        self.cmd('DocumentedAdd');self.assertEqual(self.lines(p['source_buffer']),before)

    def test_create_preserves_shebang(self):
        path=self.root/'new.sh';path.write_text('#!/bin/sh\necho hi\n')
        p=self.open(path);self.cmd('DocumentedAdd');self.edit(['A script']);self.cmd('write')
        self.assertTrue(path.read_text().startswith('#!/bin/sh\n# A script\n'))

    def test_source_edit_refreshes_projection(self):
        p=self.open()
        self.n.api.buf_set_lines(p['source_buffer'],1,2,False,[' * # Edited in source']);self.settle()
        self.assertEqual(self.doc()[0],'# Edited in source')

    def test_create_in_empty_source(self):
        self.path.write_text('int empty(void) {\n return 0;\n}\n')
        p=self.open();self.keys('2G');self.cmd('DocumentedAdd')
        self.assertEqual(self.n.current.window.handle,p['notes_window'])
        self.edit(['# New documentation','More detail'])
        self.cmd('write')
        self.assertTrue(self.path.read_text().startswith('/// # New documentation\n/// More detail\nint empty'))

    def test_create_existing_opens_without_duplicate(self):
        p=self.open();self.keys('9G');self.cmd('DocumentedAdd')
        self.assertEqual(self.lines(p['source_buffer']),SOURCE.splitlines())
        self.assertEqual(self.n.current.window.handle,p['notes_window'])

    def test_create_after_comment_edit_preserves_existing_identity(self):
        self.path.write_text(SOURCE+'\nint third(void) { return 3; }\n')
        p=self.open();identity=p['comment_id'];self.edit(['Changed first'])
        self.focus(p);self.keys('G');self.cmd('DocumentedAdd')
        self.edit(['New third'])
        old=self.n.exec_lua('local b,id=...;return require("docpair.comments").by_id(b,id)',p['source_buffer'],identity)
        self.assertIsNotNone(old);self.assertIn(' * Changed first',old['raw'])
        self.assertIn('/// New third',self.lines(p['source_buffer']))

    def test_inline_edit_in_two_tabs_shared_content(self):
        p=self.open();self.cmd('tab split');q=self.pair()
        self.edit(['Shared update']);self.check_pairs(2)
        self.assertEqual(self.lines(p['doc_buffer']),['Shared update'])
        self.assertNotEqual(p['doc_buffer'],q['doc_buffer'])

    def test_two_tabs_independent_sections_and_views(self):
        p=self.open();self.keys('9G');self.cmd('tab split');q=self.pair();self.keys('15G')
        self.cmd('DocumentedView raw')
        self.assertEqual(self.lines(p['doc_buffer'])[0],'# First function')
        self.assertTrue(self.doc()[0].startswith('///'))
        self.focus(p,'notes');self.edit(['Other tab edit'])
        self.assertTrue(self.lines(q['doc_buffer'])[0].startswith('/// # Second'))
        self.check_pairs(2)

    def test_source_duplicate_inherits_view(self):
        p=self.open();self.cmd('DocumentedView raw');self.cmd('tab split')
        self.assertEqual(self.pair()['view'],'raw');self.check_pairs(2)

    def test_split_from_document(self):
        p=self.open();self.focus(p,'notes');self.cmd('DocumentedView raw');self.cmd('tab split')
        self.check_pairs(2);self.assertEqual(self.pair()['view'],'raw')
        self.assertTrue(self.doc()[0].startswith('/**'))

    def test_buffer_switch_in_source(self):
        p=self.open();other=self.root/'other.c';other.write_text('/// Other\nint other(void) {return 0;}\n')
        self.cmd('edit '+str(other));self.check_pairs(1)
        self.assertEqual(self.doc(),['Other'])
        self.assertEqual(self.pair()['source'],str(other))

    def test_repeated_switches_do_not_accumulate_projections(self):
        p=self.open();other=self.root/'other.c';other.write_text('/// Other\nint other;\n')
        for i in range(30):self.cmd('edit '+str(other if i%2==0 else self.path))
        count=self.n.exec_lua('local n=0;for _,b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].buftype=="acwrite" then n=n+1 end end;return n')
        self.assertEqual(count,1);self.check_pairs(1)

    def test_buffer_switch_from_document(self):
        p=self.open();self.focus(p,'notes')
        other=self.root/'other.c';other.write_text('/// Other\nint other(void) {return 0;}\n')
        self.cmd('edit '+str(other));self.check_pairs(1)
        self.assertEqual(self.doc(),['Other'])

    def test_notes_preserved_after_cycle(self):
        p=self.open();self.focus(p,'notes');self.cmd('DocumentedView notes')
        notes=self.pair()['notes_buffer'];self.n.api.buf_set_lines(notes,0,1,False,['External notebook']);self.settle()
        self.cmd('DocumentedView text');self.edit(['Inline comment'])
        self.cmd('DocumentedView notes');self.assertEqual(self.doc()[0],'External notebook')
        self.cmd('wall');self.assertTrue(Path(p['notes']).read_text().startswith('External notebook'))

    def test_only_both_sides(self):
        p=self.open();self.cmd('only');self.check_pairs(1)
        p=self.pair();self.focus(p,'notes');self.cmd('only');self.check_pairs(1)

    def test_move_document_to_new_tab(self):
        p=self.open();self.focus(p,'notes');self.keys('\x17T');self.check_pairs(1)

    def test_detach_removes_conceal(self):
        p=self.open();self.cmd('DocumentedDetach');self.assertEqual(self.pairs(),[])
        self.assertEqual(self.n.api.get_option_value('conceallevel',{'win':p['source_window']}),0)

    def test_toggle_source_does_not_modify(self):
        p=self.open();self.cmd('DocumentedSource')
        self.assertEqual(self.n.api.get_option_value('conceallevel',{'win':p['source_window']}),0)
        self.cmd('DocumentedSource');self.assertEqual(self.n.api.get_option_value('conceallevel',{'win':p['source_window']}),2 if self.can_hide() else 0)
        self.assertFalse(self.n.buffers[p['source_buffer']].options['modified'])

    def test_screen_lines_hidden_without_blanks_and_cursor_visible(self):
        if not self.can_hide():self.skipTest('Whole-line hiding requires Neovim 0.11')
        p=self.open()
        screen=self.n.exec_lua('local r={};for i=1,8 do local s="";for j=1,70 do s=s..vim.fn.screenstring(i,j) end;r[#r+1]=s end;return r')
        self.assertIn('int first(void)',screen[0])
        self.assertIn('int number = 1',screen[1])
        self.assertEqual(self.n.api.win_get_cursor(p['source_window'])[0],7)
        self.cmd('DocumentedSource')
        self.keys('ggzt')
        self.assertIn('/**',self.n.exec_lua('local s="";for j=1,70 do s=s..vim.fn.screenstring(1,j) end;return s'))

    def test_ordinary_float_same_source_not_concealed(self):
        if not self.can_hide():self.skipTest('Window-scoped hiding requires Neovim 0.11')
        p=self.open()
        self.n.exec_lua('local p=...;_G.float=vim.api.nvim_open_win(p.source_buffer,false,{relative="editor",row=2,col=10,width=50,height=10});vim.wo[_G.float].conceallevel=2',p)
        self.settle()
        scopes=self.n.exec_lua('local p=...;return vim.api.nvim__ns_get(vim.api.nvim_get_namespaces()["docpair-hidden-"..p.source_buffer]).wins',p)
        self.assertEqual(scopes,[p['source_window']])
        self.check_pairs(1)

    def test_mode_switch_does_not_change_source_undo(self):
        p=self.open();before=self.n.exec_lua('return vim.api.nvim_buf_call(...,vim.fn.undotree)',p['source_buffer'])
        for name in ['raw','markdown','text']:self.cmd('DocumentedView '+name)
        after=self.n.exec_lua('return vim.api.nvim_buf_call(...,vim.fn.undotree)',p['source_buffer'])
        self.assertEqual(before,after)

    def test_initial_markdown_calls_renderer_hook(self):
        self.n.exec_lua('require("docpair").setup({initial_view="markdown",on_markdown=function(b,w) _G.rendered={b,w} end})')
        p=self.open();self.assertEqual(self.n.exec_lua('return rendered'),[p['doc_buffer'],p['notes_window']])

    def test_crlf_unicode_and_indentation_noop_roundtrip(self):
        original='\t/**\r\n\t * Größe α 中文\r\n\t */\r\nint f(void) {return 1;}\r\n'.encode()
        self.path.write_bytes(original);p=self.open();self.assertEqual(self.doc(),['Größe α 中文'])
        self.focus(p,'notes');self.cmd('write');self.assertEqual(self.path.read_bytes(),original)

    def test_edited_comments_leave_compilable_c(self):
        import shutil,subprocess
        compiler=shutil.which('cc')
        if not compiler:self.skipTest('C compiler unavailable')
        self.open();self.edit(['# Description','A formula: x * y','```c','int value = 0;','```']);self.cmd('write')
        result=subprocess.run([compiler,'-fsyntax-only',str(self.path)],text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_split_from_second_document_preserves_section(self):
        p=self.open();self.keys('15G');self.focus(p,'notes');self.cmd('tab split')
        self.check_pairs(2);self.assertEqual(self.doc()[0],'# Second function')

    def test_close_document_buffer_removes_pair(self):
        p=self.open();self.focus(p,'notes');self.cmd('bdelete');self.assertEqual(self.pairs(),[])

    def test_projection_saveas_rejected(self):
        p=self.open();self.focus(p,'notes')
        with self.assertRaises(Exception):self.n.command('saveas '+str(self.root/'fragment.md'))
        self.assertFalse((self.root/'fragment.md').exists())
        self.assertEqual(self.path.read_text(),SOURCE)

    def test_recover_draft_after_file_switch(self):
        p=self.open();self.edit(['Invalid */ draft'])
        self.focus(p);other=self.root/'other.c';other.write_text('/// Other\nint other;\n')
        self.cmd('edit '+str(other))
        self.n.exec_lua('vim.ui.select=function(items,opts,cb) cb(items[1]) end')
        self.cmd('DocumentedDrafts')
        self.assertEqual(self.doc(),['Invalid */ draft'])
        self.assertTrue(self.n.buffers[self.pair()['doc_buffer']].options['modified'])
        self.cmd('DocumentedDiscard');self.assertEqual(self.doc()[0],'# First function')

    def test_empty_block_comment_and_c_splicing(self):
        self.path.write_text('/**/\nint x;\n');p=self.open();self.assertEqual(self.doc(),[''])
        self.edit(['unsafe'+chr(92)])
        self.assertEqual(self.lines(p['source_buffer']),['/**/','int x;'])
        self.assertTrue(self.n.buffers[p['doc_buffer']].options['modified'])

    def test_heredoc_and_text_block_are_not_comments(self):
        for ext,text in [
          ('sh',"cat <<'DOC'\n# body\nDOC\n# real\necho hi\n"),
          ('rb','puts <<~DOC\n# body\nDOC\n# real\nx=1\n'),
          ('java','String s = """\n"quoted"\n/// body\n""";\n/// real\nclass C {}\n'),
        ]:
            with self.subTest(language=ext):
                path=self.root/('string.'+ext);path.write_text(text);p=self.open(path)
                items=self.n.exec_lua('return require("docpair.comments").index(...).items',p['source_buffer'])
                self.assertEqual(len(items),1);self.assertIn('real',items[0]['raw'][0])

    def test_many_small_comments(self):
        self.path.write_text(''.join('/// Function '+str(i)+'\nint f'+str(i)+'(void) {\n return '+str(i)+';\n}\n' for i in range(20000)))
        start=time.perf_counter();p=self.open();self.keys('79999G')
        self.assertEqual(self.doc(),['Function 19999'])
        TIMINGS.append({'case':'80000 lines, 20000 comments','open_and_jump_seconds':time.perf_counter()-start})

    def test_scope_nesting(self):
        self.path.write_text('/// Function\nint f(void) {\n /// Local statement\n int x = 1;\n return x;\n}\n')
        p=self.open();self.keys('4G');self.assertEqual(self.doc(),['Local statement'])
        self.keys('5G');self.assertEqual(self.doc(),['Function'])

    def test_session_restores_views(self):
        p=self.open();self.cmd('DocumentedView raw')
        session=self.root/'session.vim';self.cmd('mksession! '+str(session))
        self.cmd('tabnew');self.cmd('tabonly');self.cmd('source '+str(session))
        self.check_pairs(1);self.assertEqual(self.pair()['view'],'raw')
        self.assertTrue(self.doc()[0].startswith('/**'))

    def test_session_restores_document_reading_position(self):
        p=self.open();self.focus(p,'notes');self.keys('G')
        session=self.root/'read.vim';self.cmd('mksession! '+str(session))
        self.cmd('tabnew');self.cmd('tabonly');self.cmd('source '+str(session))
        p=self.pair();self.assertEqual(self.n.api.win_get_cursor(p['notes_window'])[0],4)
        self.check_pairs(1)

    def test_readonly_source_projection_readonly(self):
        self.cmd('edit '+str(self.path));self.cmd('setlocal readonly');p=self.open()
        self.assertFalse(self.n.buffers[p['doc_buffer']].options['modifiable'])

    def test_no_comment_inside_strings_or_trailing_code(self):
        text='char *literal = "/* not a comment */";\nint x; // trailing\n/// Real\nint f(void) {return 1;}\n'
        self.path.write_text(text);p=self.open()
        items=self.n.exec_lua('return require("docpair.comments").index(...).items',p['source_buffer'])
        self.assertEqual(len(items),1);self.assertEqual(items[0]['first'],2)

    def test_language_adapters_and_roundtrips(self):
        fixtures={
          'c':('/**\n * # C\n */\nint f(void) {return 0;}\n','# C'),
          'cpp':('/// C++\nint f() {return 0;}\n','C++'),
          'zig':('/// Zig\npub fn f() void {}\n','Zig'),
          'rs':('/// Rust\nfn f() {}\n','Rust'),
          'py':('# Python\ndef f():\n    return 0\n','Python'),
          'lua':('--[[\nLua\n]]\nlocal function f() return 1 end\n','Lua'),
          'js':('/** JavaScript */\nfunction f() {}\n','JavaScript'),
          'ts':('/// TypeScript\nfunction f(): void {}\n','TypeScript'),
          'java':('/** Java */\nclass Example {}\n','Java'),
          'go':('// Go\nfunc f() {}\n','Go'),
          'cs':('/// <summary>C#</summary>\nclass Example {}\n','<summary>C#</summary>'),
          'pas':('(* Pascal *)\nprocedure f;\nbegin\nend;\n','Pascal'),
          'html':('<!-- HTML -->\n<p>Body</p>\n','HTML'),
          'css':('/* CSS */\np { color: red; }\n','CSS'),
          'sql':('-- SQL\nSELECT 1;\n','SQL'),
          'sh':('# Shell\necho hello\n','Shell'),
          'rb':('# Ruby\ndef f\nend\n','Ruby'),
        }
        for ext,(text,expected) in fixtures.items():
            with self.subTest(language=ext):
                path=self.root/('language.'+ext);path.write_text(text)
                p=self.open(path);self.assertEqual(self.doc()[0],expected)
                self.focus(p,'notes');self.cmd('write');self.assertEqual(path.read_text(),text)
                self.edit([expected+' updated']);self.cmd('write')
                self.assertIn(expected+' updated',path.read_text())

    def test_directives_and_python_docstrings_not_hidden(self):
        for ext,text,expected in [
          ('py','"""Docstring\n# inside string\n"""\n# real\nx=1\n',1),
          ('pas','{$MODE OBJFPC}\n// real\nprogram p;\n',1),
          ('sh','#!/bin/sh\n# real\necho hi\n',1),
          ('cpp','auto s = R"x(\n/// string\n)x";\n/// real\nint f() {}\n',1),
          ('lua','local s = [=[\n-- string\n]=]\n-- real\nlocal f = 1\n',1),
        ]:
            with self.subTest(language=ext):
                path=self.root/('directives.'+ext);path.write_text(text);p=self.open(path)
                items=self.n.exec_lua('return require("docpair.comments").index(...).items',p['source_buffer'])
                self.assertEqual(len(items),expected)

    def test_large_source_and_large_document(self):
        # 200k code lines plus 50k comment lines (~23 MB explanation). The
        # cursor remains in a short function while its document scrolls freely.
        self.path.write_text('/**\n'+''.join(' * Paragraph '+str(i)+': '+('explanation '*38)+'\n' for i in range(50000))
          +' */\nint large(void) { return 1; }\n'+''.join('int value_'+str(i)+' = 0;\n' for i in range(200000)))
        start=time.perf_counter();p=self.open();elapsed=time.perf_counter()-start
        self.assertEqual(len(self.doc()),50000)
        self.focus(p,'notes');self.keys('Gzt')
        self.assertEqual(self.n.api.win_get_cursor(p['source_window'])[0],50003 if self.can_hide() else 1)
        self.assertEqual(self.n.api.win_get_cursor(p['notes_window'])[0],50000)
        start=time.perf_counter();self.cmd('DocumentedView raw');self.cmd('DocumentedView text')
        switch_seconds=time.perf_counter()-start
        start=time.perf_counter()
        self.n.api.buf_set_lines(self.pair()['doc_buffer'],0,1,False,['Updated first paragraph'])
        self.settle()
        edit_seconds=time.perf_counter()-start
        self.assertIn(' * Updated first paragraph',self.lines(p['source_buffer'])[:3])
        TIMINGS.append({'case':'250003 lines, 50000 doc lines','open_seconds':elapsed,'two_view_switches_seconds':switch_seconds,
                        'source_bytes':self.path.stat().st_size,'document_edit_seconds':edit_seconds})
        self.check_pairs(1)


if __name__=='__main__':
    start=time.perf_counter()
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Comments))
    report={'tests':result.testsRun,'failures':[(str(t),e) for t,e in result.failures],
            'errors':[(str(t),e) for t,e in result.errors], 'skipped':[(str(t),reason) for t,reason in result.skipped],
            'seconds':time.perf_counter()-start,'timings':TIMINGS}
    if args.output:Path(args.output).write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2));raise SystemExit(not result.wasSuccessful())

#!/usr/bin/env python3
"""Integration tests against a REAL Neovim process with an attached UI.

No Lua mocks: commands and key sequences exercise native buffer/tab/window
events. Large fixtures are generated in a temporary directory, not vendored.
Run: python tests/run.py --nvim /path/to/nvim --output /tmp/docpair-results.json
Dependency: python -m pip install pynvim
"""
import argparse
import json
import os
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
TEMP = tempfile.TemporaryDirectory(prefix='docpair-test-')
ROOT = Path(TEMP.name)
TIMINGS = []


def fixture(name, lines=300):
    source = ROOT / name
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text('\n'.join(f'int value_{i} = {i};' for i in range(lines))+'\n')
    notes = source.parent / '.documented' / (source.name+'_info')
    notes.parent.mkdir(exist_ok=True)
    notes.write_text('\n'.join(f'Explanation for {name} line {i+1}' for i in range(lines))+'\n')
    return source


A = fixture('alpha.c', 50000)
B = fixture('beta.c', 80000)
HUGE = fixture('huge.c', 200000)
HUGE.write_text(''.join(
    f'/* Calibration stage {i}: constrain the scaled sample to its domain. */\n'
    f'static double evaluate_sample_{i}(double sample, double gain)\n'
    '{\n'
    '    double scaled = sample * gain;\n'
    '    if (scaled < 0.0) {\n'
    '        return 0.0;\n'
    '    }\n'
    '    return scaled > 1.0 ? 1.0 : scaled;\n'
    '}\n'
    '\n' for i in range(20000)))
HUGE.with_name('.documented').joinpath('huge.c_info').write_text('\n'.join(
    f'Line {i+1}: '+('Calculation, assumptions, and boundary conditions. '*10 if i%5==0 else '')
    for i in range(200000))+'\n')
SPACE = fixture('directory with spaces/a file.c', 500)


def boot():
    n = pynvim.attach('child', argv=[args.nvim, '--embed', '--headless', '-u', 'NONE', '-i', 'NONE', '-n'])
    n.ui_attach(180, 50, rgb=True)
    n.command('set hidden noswapfile shortmess+=I')
    n.exec_lua('''
      _G.docpair_messages = {}
      vim.notify = function(text, level)
        table.insert(_G.docpair_messages, {text=tostring(text), level=level or 2})
      end
      vim.opt.rtp:append(...)
      require('docpair').setup({ initial_view = 'notes', comments = { hide = false } })
    ''', str(REPO))
    return n


def shutdown(n):
    try: n.command('qa!')
    except (EOFError, OSError): pass
    n.close()


class Integration(unittest.TestCase):
    def setUp(self):
        self.n = boot()

    def tearDown(self):
        shutdown(self.n)

    def settle(self):
        self.n.exec_lua('vim.wait(15); vim.cmd("redraw")')

    def command(self, command):
        self.n.command(command)
        self.settle()

    def keys(self, keys):
        self.n.input(keys)
        self.settle()

    def open(self, path=A, bang=False, notes=None):
        command = 'Documented'+('!' if bang else '')+' '+self.n.funcs.fnameescape(str(path))
        if notes: command += ' '+notes
        self.command(command)
        return self.current_pair()

    def pairs(self):
        return self.n.exec_lua('return require("docpair").inspect()')

    def current_pair(self):
        current = self.n.current.window.handle
        return next(p for p in self.pairs() if current in [p['source_window'], p['notes_window']])

    def focus(self, pair, role='source'):
        self.n.api.set_current_win(pair[role+'_window'])
        self.settle()

    def assert_pairs(self, expected=None):
        pairs = self.pairs()
        if expected is not None: self.assertEqual(len(pairs), expected)
        owners = set()
        for pair in pairs:
            source, notes = pair['source_window'], pair['notes_window']
            self.assertNotEqual(source, notes)
            self.assertNotIn(source, owners)
            self.assertNotIn(notes, owners)
            owners.update([source, notes])
            self.assertEqual(self.n.api.win_get_tabpage(source), self.n.api.win_get_tabpage(notes))
            self.assertEqual(self.n.api.buf_get_name(self.n.api.win_get_buf(source)), pair['source'])
            self.assertEqual(self.n.api.buf_get_name(self.n.api.win_get_buf(notes)), pair['notes'])
        errors = self.n.exec_lua('return vim.tbl_filter(function(m) return m.level >= vim.log.levels.ERROR end, _G.docpair_messages)')
        self.assertEqual(errors, [], errors)
        return pairs

    def test_default_split_direction(self):
        p=self.open()
        self.assertLess(self.n.api.win_get_position(p['source_window'])[1], self.n.api.win_get_position(p['notes_window'])[1])
        self.assertEqual(self.n.options['scrollopt'], 'ver,jump')
        self.assert_pairs(1)

    def test_splitright_enabled(self):
        self.command('set splitright')
        p=self.open()
        self.assertLess(self.n.api.win_get_position(p['source_window'])[1], self.n.api.win_get_position(p['notes_window'])[1])
        self.assert_pairs(1)

    def test_edit_in_source_pane(self):
        p=self.open(); self.focus(p)
        self.keys(':edit '+str(B)+'\r')
        self.assertEqual(self.current_pair()['source'],str(B)); self.assert_pairs(1)

    def test_buffer_and_alternate_file(self):
        p=self.open(); self.focus(p)
        self.command('edit '+str(B))
        self.keys('\x1e')  # Ctrl-^, native alternate buffer
        self.assertEqual(self.current_pair()['source'],str(A)); self.assert_pairs(1)

    def test_bnext_bprevious_skip_notebooks(self):
        p=self.open(); self.focus(p)
        self.command('badd '+str(B)); self.command('bnext')
        self.assertEqual(self.current_pair()['source'],str(B))
        self.command('bprevious')
        self.assertEqual(self.current_pair()['source'],str(A)); self.assert_pairs(1)

    def test_edit_while_in_notes_pane(self):
        p=self.open(); self.focus(p,'notes')
        self.command('edit '+str(B))
        self.assertEqual(self.current_pair()['source'],str(B)); self.assert_pairs(1)
        self.assertEqual(self.n.current.window.handle,self.current_pair()['source_window'])

    def test_tab_split_source(self):
        p=self.open(); self.focus(p); self.keys(':tab split\r')
        self.assert_pairs(2)

    def test_tab_split_notes(self):
        p=self.open(); self.focus(p,'notes'); self.command('tab split')
        self.assert_pairs(2)

    def test_two_pairs_in_one_tab(self):
        p=self.open(); self.focus(p); self.command('split '+str(B))
        self.command('Documented!')
        self.assert_pairs(2)

    def test_two_views_same_buffer(self):
        p=self.open(); self.focus(p); self.command('split')
        pairs=self.assert_pairs(2)
        self.assertEqual(pairs[0]['source_buffer'],pairs[1]['source_buffer'])
        self.assertEqual(pairs[0]['notes_buffer'],pairs[1]['notes_buffer'])

    def test_scroll_isolation_same_tab(self):
        p=self.open(); self.focus(p); self.command('split '+str(B)); q=self.open(B,True)
        self.focus(q); self.keys('20000Gzt')
        before=self.n.api.win_get_cursor(q['source_window'])
        self.focus(p); self.keys('10000Gzt')
        self.assertEqual(self.n.api.win_get_cursor(p['notes_window'])[0],10000)
        self.assertEqual(self.n.api.win_get_cursor(q['source_window']),before)
        self.assert_pairs(2)

    def test_tabs_preserve_independent_positions(self):
        p=self.open(); self.focus(p); self.keys('12345Gzt'); self.command('tab split')
        q=self.current_pair(); self.keys('34567Gzt')
        self.command('tabprevious')
        self.assertEqual(self.n.api.win_get_cursor(p['source_window'])[0],12345)
        self.assertEqual(self.n.api.win_get_cursor(q['source_window'])[0],34567)
        self.assert_pairs(2)

    def test_move_source_to_new_tab(self):
        p=self.open(); self.focus(p); self.keys('\x17T')
        self.assert_pairs(1)

    def test_move_notes_to_new_tab(self):
        p=self.open(); self.focus(p,'notes'); self.keys('\x17T')
        self.assert_pairs(1)

    def test_only_source_preserves_pair(self):
        p=self.open(); self.focus(p); self.command('only')
        self.assert_pairs(1)

    def test_only_notes_preserves_pair(self):
        p=self.open(); self.focus(p,'notes'); self.command('only')
        self.assert_pairs(1)

    def test_close_source_closes_pair(self):
        p=self.open(); self.focus(p); self.command('close')
        self.assert_pairs(0)

    def test_close_notes_closes_pair(self):
        p=self.open(); self.focus(p,'notes'); self.command('close')
        self.assert_pairs(0)

    def test_tabclose_does_not_resurrect(self):
        p=self.open(); self.command('tab split'); self.command('tabclose')
        self.assert_pairs(1)

    def test_tabonly_does_not_resurrect(self):
        self.open(); self.command('tab split'); self.command('tabonly')
        self.assert_pairs(1); self.assertEqual(len(self.n.tabpages),1)

    def test_delete_source_buffer(self):
        p=self.open(); self.focus(p); self.command('bdelete')
        self.assert_pairs(0)

    def test_delete_source_from_notes(self):
        p=self.open(); self.focus(p,'notes'); self.command('bdelete '+str(p['source_buffer']))
        self.assert_pairs(0)

    def test_unsaved_notes_survive_switch(self):
        p=self.open(); self.focus(p,'notes'); self.keys('iUNSAVED NOTE\x1b')
        self.focus(p); self.command('edit '+str(B)); self.command('edit '+str(A))
        self.assertTrue(self.n.buffers[p['notes_buffer']][0].startswith('UNSAVED NOTE'))
        self.assertTrue(self.n.buffers[p['notes_buffer']].options['modified']); self.assert_pairs(1)

    def test_unsaved_source_used_for_padding(self):
        path=fixture('padding.c',3)
        self.command('edit '+str(path)); self.n.current.buffer.append(['extra']*20)
        p=self.open(path,True)
        self.assertEqual(len(self.n.buffers[p['notes_buffer']]),23)
        self.assertEqual(len(path.read_text().splitlines()),3)

    def test_documented_repeat_is_idempotent(self):
        p=self.open(); self.focus(p); self.keys('15000Gzt')
        for _ in range(3): self.command('Documented')
        self.assert_pairs(1)
        self.assertEqual(self.n.api.win_get_cursor(p['source_window'])[0],15000)

    def test_current_tab_preserves_unrelated_windows(self):
        self.command('edit '+str(B)); other=self.n.current.window.handle
        self.command('split '+str(A)); self.command('Documented!')
        self.assertTrue(self.n.api.win_is_valid(other)); self.assert_pairs(1)

    def test_help_quickfix_float_are_not_paired(self):
        self.open(); self.command('help windows'); self.command('copen')
        self.n.exec_lua('local b=vim.api.nvim_create_buf(false,true); vim.api.nvim_open_win(b,false,{relative="editor",row=2,col=3,width=30,height=5})')
        self.settle(); self.assert_pairs(1)

    def test_quickfix_jump_updates_notes(self):
        p=self.open(); self.focus(p)
        self.n.funcs.setqflist([{'filename':str(B),'lnum':23456,'text':'Review this line'}])
        self.command('cfirst')
        self.assertEqual(self.current_pair()['source'],str(B))
        self.assertEqual(self.n.current.window.cursor[0],23456); self.assert_pairs(1)

    def test_spaces_in_paths(self):
        self.open(SPACE); self.assert_pairs(1)

    def test_new_notes_save_creates_directory(self):
        path=ROOT/'newdir/new.c';path.parent.mkdir(exist_ok=True);path.write_text('int main(void) { return 0; }\n')
        p=self.open(path); self.focus(p,'notes'); self.keys('iNew explanation\x1b'); self.command('write')
        self.assertTrue(Path(p['notes']).read_text().startswith('New explanation')); self.assert_pairs(1)

    def test_native_session_reload(self):
        self.open(); self.command('tab split'); self.command('edit '+str(B))
        session=ROOT/'session.vim'; self.command('mksession! '+str(session))
        shutdown(self.n); self.n=boot(); self.command('source '+str(session))
        self.assert_pairs(2)

    def test_custom_notes_session_reload(self):
        path=fixture('custom.c',50); p=self.open(path,notes='my_notes.md')
        self.focus(p,'notes');self.keys('iCustom notebook\x1b');self.command('write')
        session=ROOT/'custom-session.vim';self.command('mksession! '+str(session))
        shutdown(self.n);self.n=boot();self.command('source '+str(session))
        pairs=self.assert_pairs(1);self.assertEqual(Path(pairs[0]['notes']).name,'my_notes.md')

    def test_detach_restores_options(self):
        self.command('set wrap foldenable scrolloff=5'); p=self.open(A,True)
        self.command('DocumentedDetach'); self.assert_pairs(0)
        self.assertTrue(self.n.api.get_option_value('wrap',{'win':p['source_window']}))
        self.command('tabnext');self.assert_pairs(0)

    def test_resize_and_reorder(self):
        p=self.open();self.focus(p);self.keys('\x17x');self.command('wincmd H')
        self.n.ui_try_resize(70,20);self.settle();self.assert_pairs(1)

    def test_large_files_and_rapid_switches(self):
        start=time.perf_counter();p=self.open(HUGE);open_time=time.perf_counter()-start
        start=time.perf_counter()
        for i in range(25):
            self.command('edit '+str(B if i%2==0 else HUGE))
            self.keys(str(30000+i*1000)+'Gzt')
            self.assert_pairs(1)
        TIMINGS.append({'case':'200k_open_seconds','value':open_time})
        TIMINGS.append({'case':'25_large_switches_including_ui_settle_seconds','value':time.perf_counter()-start})
        pid=self.n.funcs.getpid()
        status=Path(f'/proc/{pid}/status').read_text()
        TIMINGS.append({'case':'large_process_memory','value':[line for line in status.splitlines() if line.startswith(('VmRSS:','VmHWM:'))]})

    def test_large_notes_long_line_horizontal_isolation(self):
        path=fixture('long.c',1000);p=self.open(path)
        self.n.buffers[p['notes_buffer']][99]='L'*16000
        self.focus(p);self.keys('100Gzt');before=self.n.api.win_get_cursor(p['source_window'])
        self.focus(p,'notes');self.keys('$')
        self.assertEqual(self.n.api.win_get_cursor(p['source_window']),before);self.assert_pairs(1)

    def test_repeated_command_extends_padding(self):
        path=fixture('growing.c',10);p=self.open(path)
        self.n.buffers[p['source_buffer']].append(['new line']*25)
        self.command('Documented')
        self.assertEqual(len(self.n.buffers[p['notes_buffer']]),35);self.assert_pairs(1)

    def test_nohidden_keeps_edited_notes(self):
        self.command('set nohidden');p=self.open();self.focus(p,'notes')
        self.keys('iKeep this note\x1b');self.focus(p);self.command('edit '+str(B))
        self.assertTrue(self.n.buffers[p['notes_buffer']][0].startswith('Keep this note'))
        self.assertTrue(self.n.buffers[p['notes_buffer']].options['modified']);self.assert_pairs(1)

    def test_cancelled_qall_continues_tracking(self):
        p=self.open();self.focus(p,'notes');self.keys('iDo not lose\x1b')
        self.focus(p);self.command('edit '+str(B))
        # Older Neovim versions show a hit-enter prompt for this error when a
        # UI is attached. Suppress the prompt, not the error or safety check.
        with self.assertRaises(pynvim.api.common.NvimError):self.n.command('silent qall')
        self.command('edit '+str(A));self.assert_pairs(1)
        self.assertTrue(self.n.buffers[p['notes_buffer']][0].startswith('Do not lose'))

    def test_delete_notes_buffer(self):
        p=self.open();self.focus(p,'notes');self.command('bdelete')
        self.assert_pairs(0)

    def test_wipe_source_shared_across_tabs(self):
        p=self.open();self.command('tab split');self.command('bwipeout '+str(p['source_buffer']))
        self.assert_pairs(0)

    def test_source_undo_survives_switch(self):
        p=self.open();self.keys('iTemporary code\x1b')
        self.command('edit '+str(B));self.command('edit '+str(A));self.keys('u')
        self.assertEqual(self.n.buffers[p['source_buffer']][0],'int value_0 = 0;');self.assert_pairs(1)

    def test_enew_then_registered_source(self):
        p=self.open();self.command('enew');self.assert_pairs(0)
        self.command('buffer '+str(p['source_buffer']));self.assert_pairs(1)

    def test_tabmove_and_tab_navigation(self):
        p=self.open();self.open(B);self.command('tabmove 0')
        self.keys('gt');self.keys('gT');self.assert_pairs(2)

    def test_user_write_all_includes_hidden_notes(self):
        path=fixture('wall.c',50);p=self.open(path);self.focus(p,'notes')
        self.keys('iSaved hidden note\x1b');self.focus(p);self.command('edit '+str(B))
        self.command('wall');self.assertTrue(Path(p['notes']).read_text().startswith('Saved hidden note'))

    def test_syntax_enabled_large_source_and_markdown(self):
        self.command('filetype plugin indent on');self.command('syntax enable')
        start=time.perf_counter();p=self.open(HUGE)
        self.keys('150000Gzt');self.focus(p,'notes');self.keys('5j');self.assert_pairs(1)
        self.assertEqual(self.n.buffers[p['source_buffer']].options['filetype'],'c')
        self.assertEqual(self.n.buffers[p['notes_buffer']].options['filetype'],'markdown')
        TIMINGS.append({'case':'200k_syntax_open_and_navigation_seconds','value':time.perf_counter()-start})

    def test_mouse_scroll_in_unfocused_notes(self):
        self.command('set mouse=a');p=self.open();self.keys('15000Gzt')
        row,col=self.n.api.win_get_position(p['notes_window'])
        for _ in range(3):self.n.api.input_mouse('wheel','down','',0,row+5,col+5)
        self.settle()
        views=self.n.exec_lua('local p=...;return {vim.api.nvim_win_call(p.source_window,vim.fn.winsaveview),vim.api.nvim_win_call(p.notes_window,vim.fn.winsaveview)}',p)
        self.assertGreater(views[1]['topline'],15000)
        self.assertEqual(views[0]['topline'],views[1]['topline']);self.assert_pairs(1)

    def test_source_saveas_keeps_association(self):
        path=fixture('rename.c',300);p=self.open(path)
        self.command('saveas '+str(ROOT/'renamed.c'))
        q=self.current_pair();self.assertEqual(q['source'],str(ROOT/'renamed.c'))
        self.assertEqual(q['notes'],p['notes']);self.assert_pairs(1)

    def test_notes_saveas_keeps_association(self):
        path=fixture('rename-notes.c',300);p=self.open(path);self.focus(p,'notes')
        self.command('saveas '+str(ROOT/'renamed-notes.md'))
        q=self.current_pair();self.assertEqual(q['notes'],str(ROOT/'renamed-notes.md'))
        self.assertEqual(q['source'],str(path));self.assert_pairs(1)

    def test_notes_longer_than_source_clamps_without_loop(self):
        path=fixture('short-source.c',30);p=self.open(path)
        self.n.buffers[p['notes_buffer']].append(['Additional explanation']*10000)
        self.focus(p,'notes');self.keys('Gzt')
        self.assertEqual(self.n.api.win_get_cursor(p['source_window'])[0],30)
        self.assertEqual(self.n.api.win_get_cursor(p['notes_window'])[0],10030);self.assert_pairs(1)

    def test_repair_after_suppressed_events(self):
        p=self.open();self.command('noautocmd edit '+str(B))
        self.command('DocumentedRepair')
        self.assertEqual(self.current_pair()['source'],str(B));self.assert_pairs(1)

    def test_registered_source_in_float_is_not_paired(self):
        p=self.open()
        self.n.exec_lua('vim.api.nvim_open_win(...,false,{relative="editor",row=2,col=3,width=30,height=5})',p['source_buffer'])
        self.settle();self.assert_pairs(1)

    def test_readonly_directory_uses_existing_fallback(self):
        directory=ROOT/'readonly';directory.mkdir();path=directory/'source.c'
        path.write_text('int value = 0;\n');directory.chmod(0o555)
        home=ROOT/'fallback-home';home.mkdir()
        self.n.exec_lua('vim.env.HOME=...',str(home))
        try:
            p=self.open(path)
            self.assertEqual(p['notes'],str(home/'.config/docpair/tree')+str(directory)+'/source.c_info')
            self.focus(p,'notes');self.keys('iFallback note\x1b');self.command('write')
            self.assertTrue(Path(p['notes']).read_text().startswith('Fallback note'));self.assert_pairs(1)
        finally:directory.chmod(0o755)

    def test_native_loader_respects_explicit_setup(self):
        self.n.exec_lua('require("docpair").setup({info_filetype="text",initial_view="notes",comments={hide=false}})')
        self.command('runtime plugin/docpair.lua');p=self.open()
        self.assertEqual(self.n.buffers[p['notes_buffer']].options['filetype'],'text');self.assert_pairs(1)


if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(Integration)
    started=time.perf_counter()
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    report={'neovim':args.nvim,'tests':result.testsRun,'failures':[(str(t),e) for t,e in result.failures],
            'errors':[(str(t),e) for t,e in result.errors], 'seconds':time.perf_counter()-started,'timings':TIMINGS,
            'fixture_sizes':{p.name:{'source_lines':len(p.read_text().splitlines()),'source_bytes':p.stat().st_size,
              'notes_bytes':(p.parent/'.documented'/(p.name+'_info')).stat().st_size} for p in [A,B,HUGE]}}
    if args.output: Path(args.output).write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))
    raise SystemExit(not result.wasSuccessful())

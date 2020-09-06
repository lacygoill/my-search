if exists('g:autoloaded_search')
    finish
endif
let g:autoloaded_search = 1

" TODO(Vim9): refactor the whole plugin in Vim9 script{{{
"
" Problem: Refactoring `search#blink()` is tricky:
"
"     def search#blink(): string
"         s:blink.ticks = 4
"         s:blink.delay = 50
"
"         s:blink.delete()
"         s:blink.tick(0)
"         return ''
"     enddef
"
"     Error detected while processing function search#blink:~
"     line    1:~
"     Not supported yet: s:blink.ticks = 4~
"
"     def search#blink(): string
"         s:blink['ticks'] = 4
"         s:blink['delay'] = 50
"
"         s:blink.delete()
"         s:blink.tick(0)
"         return ''
"     enddef
"
"     Error detected while processing function search#blink:~
"     line    1:~
"     E1088: cannot use an index on s:blink~
"
" MWE:
"
"     vim9script
"     let s:d = {}
"     def Func()
"         s:d.key = 0
"     enddef
"     Func()
"
"     Not supported yet: s:d.key = 0~
"
" ---
"
" Idea: Use `get()`:
"
"     def search#blink(): string
"         s:blink['ticks'] = 4
"         s:blink['delay'] = 50
"         get(s:, 'blink')->get('delete')()
"         get(s:, 'blink')->get('tick')(0)
"         return ''
"     enddef
"
" Issue:
"
"     E1075: Namespace not supported: s:, 'blink')->get('delete')()
"
" We cannot refer to the `s:` dictionary in a `:def` function.
"}}}

fu search#blink() abort "{{{1
    " every time `search#blink()` is called, we  must reset the keys `ticks` and
    " `delay` in the dictionary `s:blink`
    let [s:blink.ticks, s:blink.delay] = [4, 50]

    call s:blink.delete()
    call s:blink.tick(0)
    return ''
endfu

fu s:delete() abort dict "{{{1
    " This function has  side effects (it changes  the state of the  buffer), but we
    " also use it for its output.  In `s:blink.tick()`, we test the latter to decide
    " whether we should create a match.
    if exists('w:blink_id')
        call matchdelete(w:blink_id)
        unlet w:blink_id
        return 1
    endif
    return 0
endfu

fu search#escape(is_fwd) abort "{{{1
    let unnamed = getreg('"', 1, 1)
    call map(unnamed, {_, v -> escape(v, '\' .. (a:is_fwd ? '/' : '?'))})
    if len(unnamed) == 1
        let pat = unnamed[0]
    else
        let pat = join(unnamed, '\n')
    endif
    return '\V' .. pat
endfu

fu search#hls_after_slash() abort "{{{1
    call search#toggle_hls('restore')
    " don't enable `'hls'` when this function is called because the command-line
    " was entered from the rhs of a mapping (especially useful for `/ Up CR C-o`)
    if getcmdline() == '' || state() =~# 'm'
        return
    endif
    call search#set_hls()
    " Why `v:errmsg...` ?{{{
    "
    " Open 2 windows with 2 buffers A and B.
    " In A, search for a pattern which has a match in B but not in A.
    " Move the cursor: the highlighting should be disabled in B, but it's not.
    " This is because Vim stops processing a mapping as soon as an error occurs:
    "
    " https://github.com/junegunn/vim-slash/issues/5
    " `:h map-error`
    "}}}
    " Why the timer?{{{
    "
    " Because we haven't performed the search yet.
    " `CmdlineLeave` is fired just before.
    "}}}
    "   Why not a one-shot autocmd listening to `SafeState`?{{{
    "
    " Too early.  If the match is beyond the current screen, Vim will redraw the
    " latter, and – in the process – erase the message.
    "}}}
    " Do *not* move `feedkeys()` outside the timer!{{{
    "
    " It could trigger a hit-enter prompt.
    "
    " If you move it outside the timer,  it will be run unconditionally; even if
    " the search fails.
    " And sometimes, when we would search for some pattern which is not matched,
    " Vim could display 2 messages.  One for the pattern, and one for E486:
    "
    "     /garbage
    "     E486: Pattern not found: garbage~
    "
    " This causes a hit-enter prompt, which is annoying/distracting.
    " The fed keys don't even seem to matter.
    " It's hard to reproduce; probably a weird Vim bug...
    "
    " Anyway,   after  a   failed   search,   there  is   no   reason  to   feed
    " `<plug>(ms_custom)`;  there  is no  cursor  to  make  blink, no  index  to
    " print...  It should be fed only if the pattern was found.
    "}}}
    call timer_start(0, {->
        \ v:errmsg[:4] is# 'E486:'
        \   ? search#nohls(1)
        \   : mode() =~# '[nv]' ? feedkeys("\<plug>(ms_custom)", 'i') : 0})
endfu

def search#index(): string #{{{1
# This function is called frequently, and is potentially costly.
# Let's rewrite it in Vim9 script to make it as fast as possible.
    let incomplete: number
    let total: number
    let current: number
    let result: dict<any>
    try
        result = searchcount({'maxcount': s:MAXCOUNT, 'timeout': s:TIMEOUT})
        current = result.current
        total = result.total
        incomplete = result.incomplete
    # in case the pattern is invalid (`E54`, `E55`, `E871`, ...)
    catch
        echohl ErrorMsg | echom v:exception | echohl NONE
        return ''
    endtry
    let msg = ''
    # we don't want a NUL to be translated into a newline when echo'ed as a string;
    # it would cause an annoying hit-enter prompt
    let pat = getreg('/')->substitute('\%x00', '^@', 'g')
    if incomplete == 0
        # `printf()`  adds a  padding  of  spaces to  prevent  the pattern  from
        # "dancing" when cycling through many matches by smashing `n`
        msg = printf('[%*d/%d] %s', len(total), current, total, pat)
    elseif incomplete == 1 # recomputing took too much time
        msg = printf('[?/??] %s', pat)
    elseif incomplete == 2 # too many matches
        if result.total == (result.maxcount + 1) && result.current <= result.maxcount
            msg = printf('[%*d/>%d] %s', len(total - 1), current, total - 1, pat)
        else
            msg = printf('[>%*d/>%d] %s', len(total - 1), current - 1, total - 1, pat)
        endif
    endif

    # We don't want a hit-enter prompt when the message is too long.{{{
    #
    # Let's emulate what Vim does by default:
    #
    #    - cut the message in 2 halves
    #    - truncate the end of the 1st half, and the start of the 2nd one
    #    - join the 2 halves with `...` in the middle
    #}}}
    if strchars(msg, 1) > (v:echospace + (&cmdheight - 1) * &columns)
    #                      ├─────────┘    ├────────────────────────┘{{{
    #                      │              └ space available on previous lines of the command-line
    #                      └ space available on last line of the command-line
    #}}}
        let n = v:echospace - 3
        #                     │
        #                     └ for the middle '...'
        let n1 = n % 2 ? n / 2 : n / 2 - 1
        let n2 = n / 2
        msg = matchlist(msg, '\(.\{' .. n1 .. '}\).*\(.\{' .. n2 .. '}\)')[1:2]->join('...')
    endif

    echo msg
    return ''
enddef

fu search#nohls(...) abort "{{{1
    augroup my_search | au!
        au CursorMoved,CursorMovedI * exe 'au! my_search' | aug! my_search | set nohls
        " Necessary when a search fails (`E486`), and we search for another pattern right afterward.{{{
        "
        " Otherwise, if there is no cursor  motion between the two searches, and
        " the second one succeeds, the cursor does not blink.
        "}}}
        if a:0
            au CmdlineEnter * exe 'au! my_search' | aug! my_search | set nohls
        endif
    augroup END
    return ''
endfu

" nohls_on_leave {{{1

" when we do:
"
"     c / pattern CR
"
" `CR` enables `'hls'`, we need to disable it
fu search#nohls_on_leave()
    augroup my_search | au!
        au InsertLeave * ++once set nohls
    augroup END
    " return an empty string, so that the function doesn't insert anything
    return ''
endfu

fu search#restore_cursor_position() abort "{{{1
    if exists('s:curpos')
        call setpos('.', s:curpos)
        unlet! s:curpos
    endif
endfu

fu search#restore_unnamed_register() abort "{{{1
    " restore unnamed register if we've made it mutate
    if exists('s:unnamed_reg_save')
        call setreg('"', s:unnamed_reg_save)
        unlet! s:unnamed_reg_save
    endif
endfu

fu search#set_hls() abort "{{{1
    " If we don't  remove the autocmd, when  `n` will be typed,  the cursor will
    " move, and `'hls'` will be disabled.   We want `'hls'` to stay enabled even
    " after the `n` motion.  Same issue with  the motion after a `/` search (not
    " the first one; the next ones).  And probably with `gd`, `*`.
    "
    " Besides, during the evaluation  of `search#blink()`, `s:blink.tick()` will
    " be called several times,  but the condition to install a  hl will never be
    " satisfied (it makes  sure `'hls'` is enabled, to avoid  installing the hl,
    " if the cursor has just moved).  So, no blinking either.
    sil! au! my_search
    sil! aug! my_search
    set hls
endfu

fu s:tick(_) abort dict "{{{1
"         │
"         └ when `timer_start()` will call this function, it will send
"           the timer ID

    let self.ticks -= 1

    let active = self.ticks > 0

    " What does the next condition do? {{{
    "
    " Part1:
    "
    " We need the blinking to stop and not go on forever.
    " 2 solutions:
    "
    "    1. use the 'repeat' option of the `timer_start()` function:
    "
    "         call timer_start(self.delay, self.tick, {'repeat' : 6})
    "
    "    2. decrement a counter every time `blink.tick()` is called
    "
    " We'll use the 2nd solution, because by adding the counter to the
    " dictionary `s:blink`, we have a single object which includes the whole
    " configuration of the blinking:
    "
    "    - how does it blink?                           `s:blink.tick`
    "    - how many times does it blink?                `s:blink.ticks`
    "    - how much time does it wait between 2 ticks?  `s:blink.delay`
    "
    " It gives us a consistent way to change the configuration of the blinking.
    "
    " This explains the `if active` part of the next condition.
    "
    " Part2:
    "
    " If we move  the cursor right after  the blinking has begun,  we don't want
    " the blinking  to go on,  because it would follow  our cursor (look  at the
    " pattern passed to  `matchadd()`).  Although the effect is  only visible if
    " the delay between 2 ticks is big enough (ex: 500 ms).
    "
    " We need to stop the blinking if the cursor moves.
    " How to detect that the cursor is moving?
    " We already have an autocmd listening to the `CursorMoved` event.
    " When our autocmd is fired, `'hls'` is disabled.
    " So, if `'hls'` is disabled, we should stop the blinking.
    "
    " This explains the `if &hls` part of the next condition.
    "
    " Part3:
    "
    " For a blinking to occur, we need a condition which is satisfied only once
    " out of twice.
    " We could use the output of `blink.delete()`  to know whether a hl has just
    " been deleted.  And in this case, we  could decide to *not* re-install a hl
    " immediately.  Otherwise, re-install one.
    "
    " This explains the `if !self.delete()` part of the next condition.
    "}}}

    "  (re-)install the hl if:
    "
    "  ┌ try to delete the hl, and check we haven't been able to do so
    "  │ if we have, we don't want to re-install a hl immediately (only next tick)
    "  │                 ┌ the cursor hasn't moved
    "  │                 │       ┌ the blinking is still active
    "  │                 │       │
    if !self.delete() && &hls && active
        "                                1 list describing 1 “position”;                ┐
        "                                 `matchaddpos()` can accept up to 8 positions; │
        "                                each position can match:                       │
        "                                                                               │
        "                                    - a whole line                             │
        "                                    - a part of a line                         │
        "                                    - a character                              │
        "                                                                               │
        "                                The column index starts from 1,                │
        "                                like with `col()`.  Not from 0.                │
        "                                                                               │
        "                                          ┌────────────────────────────────────┤
        let w:blink_id = matchaddpos('IncSearch', [[line('.'), max([1, col('.') - 3]), 6]])
        "                                           │          │                       │
        "                                           │          │                       └ with a length of 6 bytes
        "                                           │          └ begin 3 bytes before cursor
        "                                           └ on the current line
    endif

    " if the blinking still has ticks to process, recall this function later
    if active
        " call `s:blink.tick()` (current function) after `s:blink.delay` ms
        call timer_start(self.delay, self.tick)
        "                            │
        "                            └ we need `self.key` to be evaluated as a key in a dictionary,
        "                              whose value is a funcref, so don't put quotes around
    endif
endfu
" What does `s:tick()` do? {{{
"
" It cycles between installing and removing the highlighting:
" If the initial numerical value of the variable `s:blink.ticks` is even,
" here's what happens:
"
" ticks = 4   (immediately decremented)
"         3 → install hl
"         2 → remove hl (when evaluating `self.delete()`)
"         1 → install hl
"         0 → remove hl
"
" If it's odd:
"
" ticks = 5
"         4 → install hl
"         3 → remove hl
"         2 → install hl
"         1 → remove hl
"         0 → don't do anything because inactive
"
"}}}
" Do *not* make this function anonymous!{{{
"
" Originally, junegunn wrote this function as an anonymous one:
"
"     fu s:blink.tick()
"         ...
"     endfu
"
" It works,  but debugging an  anonymous function  is hard.  In  particular, our
" `:WTF` command can't show us the location of the error.
"
" For more info: https://github.com/LucHermitte/lh-vim-lib/blob/master/doc/OO.md
"
" Instead, we give it a proper name, and at the end of the script, we assign its
" funcref to `s:blink.tick`.
"
" Same remark for `s:delete()`.  Don't make it anonymous.
"}}}

fu search#toggle_hls(action) abort "{{{1
    if a:action is# 'save'
        let s:hls_on = &hls
        set hls
    elseif a:action is# 'restore'
        if exists('s:hls_on')
            exe 'set ' .. (s:hls_on ? '' : 'no') .. 'hls'
            unlet! s:hls_on
        endif
    endif
endfu

fu search#view() abort "{{{1
" make a nice view, by opening folds if any, and by restoring the view if
" it changed but we wanted to stay where we were (happens with `*` & friends)

    let seq = foldclosed('.') != -1 ? 'zMzv' : ''

    " What are `s:winline` and `s:windiff`? {{{
    "
    " `s:winline` exists only if we hit `*`, `#` (visual/normal), `g*` or `g#`.
    "
    " Note:
    "
    " The goal of `s:windiff` is to restore the state of the window after we
    " search with `*` & friends.
    "
    " When we hit `*`, the rhs is evaluated into the output of `search#wrap_star()`.
    " During the evaluation, the variable `s:winline` is set.
    " The result of the evaluation is (broken on 3 lines to make it more
    " readable):
    "
    "     *<plug>(ms_prev)
    "      <plug>(ms_slash)<plug>(ms_up)<plug>(ms_cr)<plug>(ms_prev)
    "      <plug>(ms_nohls)<plug>(ms_view)<plug>(ms_blink)<plug>(ms_index)
    "
    " What's  important to  understand here,  is that  `view()` is  called AFTER
    " `search#wrap_star()`.  Therefore, `s:winline` is  not necessarily the same
    " as the current output of `winline()`, and we can use:
    "
    "     winline() - s:winline
    "
    " ...  to compute  the number  of times  we have  to hit  `C-e` or  `C-y` to
    " position the current line  in the window, so that the  state of the window
    " is restored as it was before we hit `*`.
    "}}}

    if exists('s:winline')
        let windiff = winline() - s:winline
        unlet s:winline

        " If `windiff` is positive, it means the current line is further away
        " from the top line of the window, than it was originally.
        " We have to move the window down to restore the original distance
        " between current line and top line.
        " Thus,  we use  `C-e`.  Otherwise,  we use  `C-y`.  Each  time we  must
        " prefix the key with the right count (± `windiff`).

        let seq ..= windiff > 0
            \ ?     windiff .. "\<c-e>"
            \ : windiff < 0
            \ ?     -windiff .. "\<c-y>"
            \ :     ''
    endif

    return seq
endfu

fu search#wrap_gd(is_fwd) abort "{{{1
    call search#set_hls()
    " If we press `gd`  on the 1st occurrence of a  keyword, the highlighting is
    " still not disabled.
    call timer_start(0, {-> search#nohls()})
    return (a:is_fwd ? 'gd' : 'gD') .. "\<plug>(ms_custom)"
endfu

fu search#wrap_n(is_fwd) abort "{{{1
    call search#set_hls()

    " We want `n`  and `N` to move  consistently no matter the  direction of the
    " search `/`, or `?`.  Toggle the key `n`/`N` if necessary.
    let seq = (a:is_fwd ? 'Nn' : 'nN')[v:searchforward]

    " If  we toggle  the key  (`n` to  `N` or  `N` to  `n`), when  we perform  a
    " backward search `E223` is raised:
    "
    "     E223: recursive mapping~
    "
    " Why? Because we are stuck going back and forth between 2 mappings:
    "
    "     echo v:searchforward  →  0
    "
    "     hit `n`  →  wrap_n() returns `N`  →  returns `n`  →  returns `N`  →  ...
    "
    " To prevent being stuck in an endless expansion, use non-recursive versions
    " of `n` and `N`.
    let seq = (seq is# 'n' ? "\<plug>(ms_n)" : "\<plug>(ms_N)")

    call timer_start(0, {-> v:errmsg[:4] is# 'E486:' ? search#nohls(1) : ''})

    return seq .. "\<plug>(ms_custom)"

    " Vim doesn't wait for everything to be expanded, before beginning typing.
    " As soon as it finds something which can't be remapped, it types it.
    " And `n` can't be remapped, because of `:h recursive_mapping`:
    "
    "    > If the {rhs} starts with {lhs}, the first character is not mapped
    "    > again (this is Vi compatible).
    "
    " Therefore, here, Vim  types `n` immediately, *before*  processing the rest
    " of the mapping.
    " This explains why Vim *first* moves  the cursor with `n`, *then* makes the
    " current position blink.
    " If  Vim expanded  everything before  even beginning  typing, the  blinking
    " would occur at the current position, instead of the next match.
endfu

fu search#wrap_star(seq) abort "{{{1
    let seq = a:seq
    let s:curpos = getcurpos()
    " if  the function  is invoked  from visual  mode, it  will yank  the visual
    " selection, because  `seq` begins with the  key `y`; in this  case, we save
    " the unnamed register to restore it later
    if mode() =~# "^[vV\<c-v>]$"
        let s:unnamed_reg_save = getreginfo('"')
        if seq is# '*'
            " append keys at the end to add some fancy features
            let seq = "y/\<c-r>\<c-r>=search#escape(1)"
            "          ││├───────────┘│ {{{
            "          │││            │
            "          │││            └ escape unnamed register
            "          │││
            "          ││└ insert an expression
            "          ││  (literally hence why two C-r;
            "          ││  this matters, e.g., if the selection is "xxx\<c-\>\<c-n>yyy")
            "          ││
            "          │└ search for
            "          │
            "          └ copy visual selection
            "}}}
        elseif seq is# '#'
            let seq = "y?\<c-r>\<c-r>=search#escape(0)"
            "                                       │{{{
            "               direction of the search ┘
            "
            " Necessary to  know which  character among  `[/?]` is  special, and
            " needs to be escaped.
            "}}}
        endif
        let seq ..= "\<plug>(ms_cr)\<plug>(ms_cr)\<plug>(ms_restore_unnamed_register)\<plug>(ms_prev)"
        "            │             │{{{
        "            │             └ validate search
        "            └ validate expression
        "}}}
    endif

    " `winline()` returns the position of the  current line from the top line of
    " the window.  The position / index of the latter is 1.
    let s:winline = winline()

    call search#set_hls()

    " Make sure we're not in a weird state if an error is raised.{{{
    "
    " If we press `*` on nothing, it raises `E348` or `E349`, and Vim highlights
    " the last  search pattern.   But because  of the  error, Vim  didn't finish
    " processing the mapping.  As a result, the highlighting is not cleared when
    " we move the cursor.  Make sure it is.
    "
    " ---
    "
    " Same issue if we press `*` while a block is visually selected:
    "
    "     " visually select the block `foo` + `bar`, then press `*`
    "     foo
    "     bar
    "     /\Vfoo\nbar~
    "     E486: Pattern not found: \Vfoo\nbar~
    "
    " Now, search  for `foo`: the highlighting  stays active even after  we move
    " the  cursor (✘).  Press `n`,  then move  the cursor:  the highlighting  is
    " disabled (✔).  Now, search for `foo` again: the highlighting is not enabled
    " (✘).
    "}}}
    call timer_start(0, {-> v:errmsg[:4] =~# 'E34[89]:\|E486'
        \ ?   search#nohls()
        \ :   ''})

    " Why `\<plug>(ms_slash)\<plug>(ms_up)\<plug>(ms_cr)...`?{{{
    "
    " By default `*` is stupid, it ignores `'smartcase'`.
    " To work around this issue, we type this:
    "
    "     / Up CR C-o
    "
    " It searches for the same pattern than `*` but with `/`.
    " The latter takes `'smartcase'` into account.
    "
    " In visual mode, we already do this, so, it's not necessary from there.
    " But we let the function do it again anyway, because it doesn't cause any issue.
    " If it causes an issue, we should test the current mode, and add the
    " keys on the last 2 lines only from normal mode.
    "}}}
    return seq .. (mode() !~# "^[vV\<c-v>]$"
        \ ? "\<plug>(ms_slash)\<plug>(ms_up)\<plug>(ms_cr)\<plug>(ms_prev)" : '')
        \     .. "\<plug>(ms_custom)"
endfu

" Variables {{{1

" don't let `searchcount()` search more than this number of matches
const s:MAXCOUNT = 1000
" don't let `searchcount()` search for more than this duration (in ms)
const s:TIMEOUT = 500

" `s:blink` must be initialized *after* defining the functions
" `s:tick()` and `s:delete()`.
let s:blink = {'ticks': 4, 'delay': 50}
let s:blink.tick = function('s:tick')
let s:blink.delete = function('s:delete')


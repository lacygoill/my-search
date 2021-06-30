vim9script noclear

# Config {{{1

# don't let `searchcount()` search more than this number of matches
const MAXCOUNT: number = 1'000
# don't let `searchcount()` search for more than this duration (in ms)
const TIMEOUT: number = 500

const BLINKWIDTH: number = 8
const TICKS: number = 6
const TICKDELAY: number = 50

# Declarations {{{1

var blink_ids: dict<number>
var hlsearch_on: number
var recent_search_was_slow: bool = false
var reg_save: dict<dict<any>>
var timer_id: number
var view: dict<number>
var winline: number

# Interface {{{1
def search#wrapN(is_fwd: bool): string #{{{2
    search#setHls()

    # We want `n`  and `N` to move  consistently no matter the  direction of the
    # search `/`, or `?`.  Toggle the key `n`/`N` if necessary.
    var seq: string = (is_fwd ? 'Nn' : 'nN')[v:searchforward]

    # If  we toggle  the key  (`n` to  `N` or  `N` to  `n`), when  we perform  a
    # backward search `E223` is raised:
    #
    #     E223: recursive mapping˜
    #
    # Why? Because we are stuck going back and forth between 2 mappings:
    #
    #     echo v:searchforward  →  0
    #
    #     hit `n`  →  wrapN() returns `N`  →  returns `n`  →  returns `N`  →  ...
    #
    # To prevent being stuck in an endless expansion, use non-recursive versions
    # of `n` and `N`.
    seq = (seq == 'n' ? "\<Plug>(ms_n)" : "\<Plug>(ms_N)")

    timer_start(0, (_) => {
        if v:errmsg[: 4] == 'E486:'
            search#nohls(true)
        endif
    })

    return seq .. "\<Plug>(ms_custom)"

    # Vim doesn't wait for everything to be expanded, before beginning typing.
    # As soon as it finds something which can't be remapped, it types it.
    # And `n` can't be remapped, because of `:help recursive_mapping`:
    #
    #    > If the {rhs} starts with {lhs}, the first character is not mapped
    #    > again (this is Vi compatible).
    #
    # Therefore, here, Vim  types `n` immediately, *before*  processing the rest
    # of the mapping.
    # This explains why Vim *first* moves  the cursor with `n`, *then* makes the
    # current position blink.
    # If  Vim expanded  everything before  even beginning  typing, the  blinking
    # would occur at the current position, instead of the next match.
enddef

def search#wrapStar(arg_seq: string): string #{{{2
    var seq: string = arg_seq
    # Why not just saving the cursor position?{{{
    #
    # If the next  match starts on a  column far away, saving  and restoring the
    # cursor position is not enough.  The view will still be altered.
    #}}}
    view = winsaveview()
    # if  the function  is invoked  from visual  mode, it  will yank  the visual
    # selection, because  `seq` begins with the  key `y`; in this  case, we save
    # the unnamed register to restore it later
    if mode() =~ "^[vV\<C-V>]$"
        reg_save['"'] = getreginfo('"')
        reg_save['0'] = getreginfo('0')
        if seq == '*'
            # append keys at the end to add some fancy features
            seq =
                # copy visual selection
                'y'
                # enter search command-line
                .. '/'
                # Insert an expression.{{{
                #
                # Literally  hence why  two `C-r`;  this matters,  e.g., if  the
                # selection is "xxx\<C-\>\<C-N>yyy".
                #}}}
                .. "\<C-R>\<C-R>="
                # escape unnamed register
                .. "search#escape(v:true)"

        elseif seq == '#'
            seq = "y?\<C-R>\<C-R>=search#escape(v:false)"
            #                                   │{{{
            #           direction of the search ┘
            #
            # Necessary to  know which  character among  `[/?]` is  special, and
            # needs to be escaped.
            #}}}
        endif
        # validate expression
        seq ..= "\<Plug>(ms_cr)"
            .. "\<Plug>(ms_cr)"
            # validate search
            .. "\<Plug>(ms_restore_registers)\<Plug>(ms_prev)"
    endif

    # `winline()` returns the position of the  current line from the top line of
    # the window.  The position / index of the latter is 1.
    winline = winline()

    search#setHls()

    # Make sure we're not in a weird state if an error is raised.{{{
    #
    # If we press `*` on nothing, it raises `E348` or `E349`, and Vim highlights
    # the last  search pattern.   But because  of the  error, Vim  didn't finish
    # processing the mapping.  As a result, the highlighting is not cleared when
    # we move the cursor.  Make sure it is.
    #
    # ---
    #
    # Same issue if we press `*` while a block is visually selected:
    #
    #     # visually select the block `foo` + `bar`, then press `*`
    #     foo
    #     bar
    #     /\Vfoo\nbar˜
    #     E486: Pattern not found: \Vfoo\nbar˜
    #
    # Now, search  for `foo`: the highlighting  stays active even after  we move
    # the  cursor (✘).  Press `n`,  then move  the cursor:  the highlighting  is
    # disabled (✔).  Now, search for `foo` again: the highlighting is not enabled
    # (✘).
    #}}}
    timer_start(0, (_) => {
        if v:errmsg[: 4] =~ 'E34[89]:\|E486'
            search#nohls()
        endif
    })

    return seq .. (
        mode() !~ "^[vV\<C-V>]$"
            # Force `*` to honor `'smartcase'`.{{{
            #
            # By default `*` is stupid, it ignores `'smartcase'`.
            # To work around this issue, we type this:
            #
            #     / Up CR C-o
            #
            # It searches for the same pattern than `*` but with `/`.
            # The latter takes `'smartcase'` into account.
            #
            # In visual mode, we already do this, so, it's not necessary from there.
            # But we let the function do it again anyway, because it doesn't cause any issue.
            # If it causes an issue, we should test the current mode, and add the
            # keys on the last 2 lines only from normal mode.
            #}}}
            ? "\<Plug>(ms_slash)\<Plug>(ms_up)\<Plug>(ms_cr)\<Plug>(ms_prev)"
            : ''
    ) .. "\<Plug>(ms_custom)"
enddef

def search#wrapGd(is_fwd: bool): string #{{{2
    search#setHls()
    # If we press `gd`  on the 1st occurrence of a  keyword, the highlighting is
    # still not disabled.
    timer_start(0, (_) => search#nohls())
    return (is_fwd ? 'gd' : 'gD') .. "\<Plug>(ms_custom)"
enddef

def search#blink() #{{{2
    BlinkDelete()
    timer_stop(timer_id)
    timer_id = timer_start(TICKDELAY, Blink, {repeat: TICKS})
enddef

def search#index() #{{{2
    # don't make Vim lag when we smash `n` with a slow-to-compute pattern
    if recent_search_was_slow
        return
    endif

    var incomplete: number
    var total: number
    var current: number
    var result: dict<number>
    try
        result = searchcount({maxcount: MAXCOUNT, timeout: TIMEOUT})
        current = result.current
        total = result.total
        incomplete = result.incomplete
    # in case the pattern is invalid (`E54`, `E55`, `E871`, ...)
    catch
        echohl ErrorMsg | echomsg v:exception | echohl NONE
        return
    endtry
    var msg: string = ''
    # we don't want a NUL to be translated into a newline when echo'ed as a string;
    # it would cause an annoying hit-enter prompt
    var pat: string = getreg('/')->substitute('\%x00', '^@', 'g')
    if incomplete == 0
        # `printf()`  adds a  padding  of  spaces to  prevent  the pattern  from
        # "dancing" when cycling through many matches by smashing `n`
        msg = printf('[%*d/%d] %s', len(total), current, total, pat)
    elseif incomplete == 1 # recomputing took too much time
        recent_search_was_slow = true
        autocmd SafeState * ++once recent_search_was_slow = false
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
    if strcharlen(msg) > (
        # space available on last line of the command-line
        v:echospace
        # space available on previous lines of the command-line
        + (&cmdheight - 1) * &columns
    )

        var n: number = v:echospace - 3
        #                             │
        #                             └ for the middle '...'
        var n1: number = n % 2 ? n / 2 : n / 2 - 1
        var n2: number = n / 2
        msg = msg
            ->matchlist('\(.\{' .. n1 .. '}\).*\(.\{' .. n2 .. '}\)')[1 : 2]
            ->join('...')
    endif

    echo msg
enddef

def search#hlsAfterSlash() #{{{2
    search#toggleHls('restore')
    # don't enable `'hlsearch'` when this function is called because the command-line
    # was entered from the rhs of a mapping (especially useful for `/ Up CR C-o`)
    if getcmdline() == '' || state() =~ 'm'
        return
    endif
    search#setHls()
    # Why the timer?{{{
    #
    # Because we haven't performed the search yet.
    # `CmdlineLeave` is fired just before.
    #}}}
    #   Why not a one-shot autocmd listening to `SafeState`?{{{
    #
    # Too early.  If the match is beyond the current screen, Vim will redraw the
    # latter, and – in the process – erase the message.
    #}}}
    timer_start(0, (_) =>
        # Corner Case: `'hlsearch'` is not always disabled.{{{
        #
        # Open 2 windows with 2 buffers A and B.
        # In A, search for a pattern which has a match in B but not in A.
        # Move the cursor: the highlighting should be disabled in B, but it's not.
        # This is because Vim stops processing a mapping as soon as an error occurs:
        #
        # https://github.com/junegunn/vim-slash/issues/5
        # `:help map-error`
        #}}}
        v:errmsg[: 4] == 'E486:'
          ?     search#nohls(true)
          : mode() =~ '[nv]'
          # Do *not* move `feedkeys()` outside the timer!{{{
          #
          # It could trigger a hit-enter prompt.
          #
          # If you move it outside the timer,  it will be run unconditionally; even if
          # the search fails.
          # And sometimes, when we would search for some pattern which is not matched,
          # Vim could display 2 messages.  One for the pattern, and one for E486:
          #
          #     /garbage
          #     E486: Pattern not found: garbage˜
          #
          # This causes a hit-enter prompt, which is annoying/distracting.
          # The fed keys don't even seem to matter.
          # It's hard to reproduce; probably a weird Vim bug...
          #
          # Anyway,   after  a   failed   search,   there  is   no   reason  to   feed
          # `<Plug>(ms_custom)`;  there  is no  cursor  to  make  blink, no  index  to
          # print...  It should be fed only if the pattern was found.
          #}}}
          ?     feedkeys("\<Plug>(ms_custom)", 'i')
          : 0
    )
enddef

def search#setHls() #{{{2
    # If we don't  remove the autocmd, when  `n` will be typed,  the cursor will
    # move, and  `'hlsearch'` will  be disabled.  We  want `'hlsearch'`  to stay
    # enabled even after the `n` motion.  Same issue with the motion after a `/`
    # search (not the first one; the next ones).  And probably with `gd`, `*`.
    #
    # Besides,  during the  evaluation  of `search#blink()`,  `Blink()` will  be
    # called several  times, but  the condition  to install a  hl will  never be
    # satisfied (it makes sure `'hlsearch'`  is enabled, to avoid installing the
    # hl, if the cursor has just moved).  So, no blinking either.
    silent! autocmd! MySearch
    silent! augroup! MySearch
    &hlsearch = true
enddef

def search#nohls(on_CmdlineEnter = false) #{{{2
    augroup MySearch | autocmd!
        autocmd CursorMoved,CursorMovedI * execute 'autocmd! MySearch'
            | augroup! MySearch
            | &hlsearch = false
        # Necessary when a search fails (`E486`), and we search for another pattern right afterward.{{{
        #
        # Otherwise, if there is no cursor  motion between the two searches, and
        # the second one succeeds, the cursor does not blink.
        #}}}
        if on_CmdlineEnter
            autocmd CmdlineEnter * execute 'autocmd! MySearch'
                | augroup! MySearch
                | &hlsearch = false
        endif
    augroup END
enddef

def search#nohlsOnLeave() #{{{2
# When we do:
#
#     c / pattern CR
#
# `CR` enables `'hlsearch'`, we need to disable it
    augroup MySearch | autocmd!
        autocmd InsertLeave * ++once &hlsearch = false
    augroup END
enddef

def search#toggleHls(action: string) #{{{2
    if action == 'save'
        hlsearch_on = &hlsearch ? 1 : 0
        &hlsearch = true
    elseif action == 'restore'
        if hlsearch_on != -1
            &hlsearch = hlsearch_on ? true : false
            hlsearch_on = -1
        endif
    endif
enddef

def search#view(): string #{{{2
# make a nice view, by opening folds if any, and by restoring the view if
# it changed but we wanted to stay where we were (happens with `*` & friends)

    var seq: string = foldclosed('.') >= 0 ? 'zMzv' : ''

    # What are `winline` and `windiff`? {{{
    #
    # `winline` exists only if we hit `*`, `#` (visual/normal), `g*` or `g#`.
    #
    # Note:
    #
    # The goal of `windiff` is to restore the state of the window after we
    # search with `*` & friends.
    #
    # When we hit `*`, the rhs is evaluated into the output of `search#wrapStar()`.
    # During the evaluation, the variable `winline` is set.
    # The result of the evaluation is (broken on 3 lines to make it more
    # readable):
    #
    #     *<Plug>(ms_prev)
    #      <Plug>(ms_slash)<Plug>(ms_up)<Plug>(ms_cr)<Plug>(ms_prev)
    #      <Plug>(ms_nohls)<Plug>(ms_view)<Plug>(ms_blink)<Plug>(ms_index)
    #
    # What's  important to  understand here,  is that  `view()` is  called AFTER
    # `search#wrapStar()`.  Therefore, `winline` is  not necessarily the same
    # as the current output of `winline()`, and we can use:
    #
    #     winline() - winline
    #
    # ...  to compute  the number  of times  we have  to hit  `C-e` or  `C-y` to
    # position the current line  in the window, so that the  state of the window
    # is restored as it was before we hit `*`.
    #}}}

    if winline != 0
        var windiff: number = winline() - winline
        winline = 0

        # If `windiff` is positive, it means the current line is further away
        # from the top line of the window, than it was originally.
        # We have to move the window down to restore the original distance
        # between current line and top line.
        # Thus,  we use  `C-e`.  Otherwise,  we use  `C-y`.  Each  time we  must
        # prefix the key with the right count (± `windiff`).

        seq ..= windiff > 0
            ?     windiff .. "\<C-E>"
            : windiff < 0
            ?     -windiff .. "\<C-Y>"
            :     ''
    endif

    return seq
enddef

def search#restoreCursorPosition() #{{{2
    if !empty('view')
        winrestview(view)
        view = {}
    endif
enddef

def search#restoreRegisters() #{{{2
# restore unnamed and zero registers if we've made them mutate
    if !empty(reg_save['"'])
        setreg('"', reg_save['"'])
        reg_save['"'] = {}
    endif
    if !empty(reg_save['0'])
        setreg('0', reg_save['0'])
        reg_save['0'] = {}
    endif
enddef

def search#escape(is_fwd: bool): string #{{{2
    var unnamed: list<string> = getreg('"', true, true)
        ->map((_, v: string): string => escape(v, '\' .. (is_fwd ? '/' : '?')))
    var pat: string
    if len(unnamed) == 1
        pat = unnamed[0]
    else
        pat = unnamed->join('\n')
    endif
    return '\V' .. pat
enddef
#}}}1
# Core {{{1
def Blink(_) #{{{2
#         │
#         └ timer id

    # What does the next condition do? {{{
    #
    # For a blinking to occur, we need a condition which is satisfied only once
    # out of twice.
    # We could use the  output of `BlinkDelete()` to know whether  a hl has just
    # been deleted.  And in this case, we  could decide to *not* re-install a hl
    # immediately.  Otherwise, re-install one.
    #
    # This explains the `if !BlinkDelete()` part of the next condition.
    #
    # ---
    #
    # If we move  the cursor right after  the blinking has begun,  we don't want
    # the blinking to  go on, because it would follow  our cursor.  Although the
    # effect  is  only visible  if  the  delay between  2  ticks  is big  enough
    # (e.g.: 500 ms).
    #
    # We need to stop the blinking if the cursor moves.
    # How to detect that the cursor is moving?
    # We already have an autocmd listening to the `CursorMoved` event.
    # When our autocmd is fired, `'hlsearch'` is disabled.
    # So, if `'hlsearch'` is disabled, we should stop the blinking.
    #
    # This explains the `if &hlsearch` part of the next condition.
    #}}}
    #  (re-)install the hl if:
    #
    #  ┌ try to delete the hl, and check we haven't been able to do so
    #  │ if we have, we don't want to re-install a hl immediately (only next tick)
    #  │                 ┌ the cursor hasn't moved
    #  │                 │
    if !BlinkDelete() && &hlsearch
        # 1 list describing 1 “position”.{{{
        #
        # `matchaddpos()` can accept up to 8 positions; each position can match:
        #
        #    - a whole line
        #    - a part of a line
        #    - a character
        #
        # The column index starts from 1, like with `col()`.  Not from 0.
        #}}}
        var pos: list<list<number>> = [[
            line('.'), max([1, col('.') - BLINKWIDTH / 2]),
            +BLINKWIDTH
        ]]
        # remember that you might focus a different window in the middle of a blinking
        blink_ids = {matchid: matchaddpos('IncSearch', pos), winid: win_getid()}
    endif
enddef

def BlinkDelete(): bool #{{{2
# This function has  side effects (it changes  the state of the  buffer), but we
# also  use it  for its  output.  In  `Blink()`, we  test the  latter to  decide
# whether we should create a match.
    if blink_ids != {}
        try
            matchdelete(blink_ids.matchid, blink_ids.winid)
        # E957: Invalid window number{{{
        #
        # Can happen if  you smash `n`, then right afterward,  close a window in
        # the middle of a blinking.
        #}}}
        catch /^Vim\%((\a\+)\)\=:E957:/
        endtry
        blink_ids = {}
        return true
    endif
    return false
enddef


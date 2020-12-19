vim9script

if exists('g:loaded_search')
    finish
endif
g:loaded_search = 1

# TODO: Prevent the plugin from highlighting matches after a search run from operator-pending/visual mode.{{{
#
# You can't do that right now, because  `mode()` returns `v`, `V`, `^V` when the
# search command-line  has been entered  from visual mode,  and `c` when  it was
# entered from operator-pending mode.
#
# You need to wait for `mode(1)` to be able to return `c/v` and `c/o` (see `:h todo /c\/o`).
# More generally,  disable anything fancy  when the search command-line  was not
# entered from normal mode.
#}}}
# TODO: We don't have any mapping in visual mode for `n` and `N`.{{{
#
# So, we don't have any count when pressing `n` while in visual mode.  Add a mapping?
#}}}

# Mappings {{{1
# Disable unwanted recursivity {{{2

# We remap the following keys *recursively*:
#
#     CR
#     n N
#     * #
#     g* g#
#     gd gD
#
# Each time, we use a wrapper in the rhs.
#
# Any key returned by a wrapper will be remapped.
# We want this remapping, but only for `<plug>(...)` keys.
# For anything else, remapping should be forbidden.
# So, we  install non-recursive mappings for  various keys we may  return in our
# wrappers.

cno <plug>(ms_cr)    <cr>
cno <plug>(ms_up)    <up>
nno <plug>(ms_slash) /
nno <plug>(ms_n)     n
nno <plug>(ms_N)     N
nno <plug>(ms_prev) <cmd>call search#restoreCursorPosition()<cr>

# CR  gd  n {{{2

# Note:
# Don't add `<silent>` to the next mapping.
# When we search for a pattern which has no match in the current buffer,
# the combination of `set shm+=s` and `<silent>`, would make Vim display the
# search command, which would cause 2 messages to be displayed + a prompt:
#
#     /garbage
#     E486: Pattern not found: garbage
#     Press ENTER or type command to continue
#
# Without `<silent>`, Vim behaves as expected:
#
#     E486: Pattern not found: garbage

augroup MsCmdwin | au!
    au CmdWinEnter * if getcmdwintype() =~ '[/?]'
        \ |     nmap <buffer><nowait> <cr> <cr><plug>(ms_index)
        \ | endif
augroup END

nmap <expr><unique> gd search#wrapGd(v:true)
nmap <expr><unique> gD search#wrapGd(v:false)

nmap <expr><unique> n search#wrapN(v:true)
nmap <expr><unique> N search#wrapN(v:false)

# Star & friends {{{2

# By default,  you can search automatically  for the word under  the cursor with
# `*` or `#`.  But you can't do the same for the text visually selected.
# The following mappings work  in normal mode, but also in  visual mode, to fill
# that gap.
#
# `<silent>` is useful to avoid `/ pattern CR` to display a brief message on
# the command-line.
nmap <expr><silent><unique> * search#wrapStar('*')
#                             │
#                             └ * C-o
#                               / Up CR C-o
#                               <plug>(ms_nohls)
#                               <plug>(ms_view)  ⇔  {number} C-e / C-y
#                               <plug>(ms_blink)
#                               <plug>(ms_index)

nmap <expr><silent><unique> #  search#wrapStar('#')
nmap <expr><silent><unique> g* search#wrapStar('g*')
nmap <expr><silent><unique> g# search#wrapStar('g#')
# Why don't we implement `g*` and `g#` mappings?{{{
#
# If we search a visual selection, we probably don't want to add the anchors:
#
#     \< \>
#
# So our implementation of `v_*` and `v_#` doesn't add them.
#}}}

xmap <expr><silent><unique> * search#wrapStar('*')
xmap <expr><silent><unique> # search#wrapStar('#')
# Why?{{{
#
# I often press `g*` by accident, thinking it's necessary to avoid that Vim adds
# anchors.
# In reality, it's useless, because Vim doesn't add anchors.
# `g*` is not a default visual command.
# It's interpreted as a motion which moves the end of the visual selection to the
# next occurrence of the word below the cursor.
# This can result in a big visual selection spanning across several windows.
# Too distracting.
#}}}
xmap g* *

# Customizations (blink, index, ...) {{{2

nno <plug>(ms_restore_registers) <cmd>call search#restoreRegisters()<cr>
nno <expr> <plug>(ms_view) search#view()
nno <plug>(ms_blink) <cmd>call search#blink()<cr>
nno <plug>(ms_nohls) <cmd>call search#nohls()<cr>
# Why don't you just remove the `S` flag from `'shm'`?{{{
#
# Because of 2 limitations.
# You can't position the indicator on the command-line (it's at the far right).
# You can't get the index of a match beyond 99:
#
#     /pat    [1/>99]   1
#     /pat    [2/>99]   2
#     /pat    [3/>99]   3
#     ...
#     /pat    [99/>99]  99
#     /pat    [99/>99]  100
#     /pat    [99/>99]  101
#
# And because of 1 pitfall: the count is not always visible.
#
# In the case of `*`, you won't see it at all.
# In the case of `n`, you will see it, but if you enter the command-line
# and leave it, you won't see the count anymore when pressing `n`.
# The issue is due to Vim which does not redraw enough when `'lz'` is set.
#
# MWE:
#
#     $ vim -Nu <(cat <<'EOF'
#         set lz
#         nmap n <plug>(a)<plug>(b)
#         nno <plug>(a) n
#         nno <plug>(b) <nop>
#     EOF
#     ) ~/.zshrc
#
# Search for  `the`, then press  `n` a  few times: the  cursor does not  seem to
# move.  In reality,  it does move, but  you don't see it because  the screen is
# not redrawn enough; press `C-l`, and you should see it has correctly moved.
#
# It think that's because  when `'lz'` is set, Vim doesn't  redraw in the middle
# of a mapping.
#
# In any case, all these issues stem from a lack of control:
#
#    - we can't control the maximum count of matches
#    - we can't control *where* to display the info
#    - we can't control *when* to display the info
#}}}
nno <plug>(ms_index) <cmd>call search#index()<cr>

# Regroup all customizations behind `<plug>(ms_custom)`
#                             ┌ install a one-shot autocmd to disable 'hls' when we move
#                             │               ┌ unfold if needed, restore the view after `*` & friends
#                             │               │
nmap <plug>(ms_custom) <plug>(ms_nohls)<plug>(ms_view)<plug>(ms_blink)<plug>(ms_index)
#                                                            │               │
#                               make the current match blink ┘               │
#                                            print `[12/34]` kind of message ┘

# We need this mapping for when we leave the search command-line from visual mode.
xno <plug>(ms_custom) <cmd>call search#nohls()<cr>

# Without the next mappings, we face this issue:{{{
#
# https://github.com/junegunn/vim-slash/issues/4
#
#     c /pattern CR
#
# ... inserts  a succession of literal  `<plug>(...)` strings in the  buffer, in
# front of `pattern`.
# The problem comes from the wrong assumption that after a `/` search, we are in
# normal mode.  We could also be in insert mode.
#}}}
# Why don't you disable `<plug>(ms_nohls)`?{{{
#
# Because the  search in  `c /pattern  CR` has  enabled `'hls'`,  so we  need to
# disable it.
#}}}
ino <plug>(ms_nohls) <cmd>call search#nohlsOnLeave()<cr>
ino <plug>(ms_index) <nop>
ino <plug>(ms_blink) <nop>
ino <plug>(ms_view)  <nop>
# }}}1
# Options {{{1

# ignore the case when searching for a pattern containing only lowercase characters
set ignorecase

# but don't ignore the case if it contains an uppercase character
set smartcase

# incremental search
set incsearch

# Autocmds {{{1

augroup HlsAfterSlash | au!
    # If `'hls'` and `'is'` are set, then *all* matches are highlighted when we're
    # writing a regex.  Not just the next match.  See `:h 'is`.
    # So, we make sure `'hls'` is set when we enter a search command-line.
    au CmdlineEnter /,\? search#toggleHls('save')

    # Restore the state of `'hls'`.
    au CmdlineLeave /,\? search#hlsAfterSlash()
augroup END

augroup HoistNoic | au!
    # Why an indicator for the `'ignorecase'` option?{{{
    #
    # Recently, it  was temporarily  reset by  `$VIMRUNTIME/indent/vim.vim`, but
    # was not properly set again.
    # We should be  immediately informed when that happens,  because this option
    # has many effects;  e.g. when reset, we can't tab  complete custom commands
    # written in lowercase.
    #}}}
    au User MyFlags statusline#hoist('global', '%2*%{!&ic? "[noic]" : ""}', 17,
        \ expand('<sfile>:p') .. ':' .. expand('<sflnum>'))
    au OptionSet ignorecase timer_start(0, {-> execute('redrawt')})
augroup END


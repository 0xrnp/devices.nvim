" Log buffers from devices.nvim. Levels are highlighted by the plugin; this adds the details.
if exists("b:current_syntax")
  finish
endif

" Android threadtime: "11-13 20:49:44.298   917  1126 D Tag: message"
syntax match deviceslogTime /^\d\d-\d\d \d\d:\d\d:\d\d\.\d\+/
" iOS compact: "2026-11-13 20:56:36.411 Df Process[pid:tid] message"
syntax match deviceslogTime /^\d\{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d\+/
syntax match deviceslogNotice /^-- .* --$/

highlight default link deviceslogTime Comment
highlight default link deviceslogNotice Title

let b:current_syntax = "deviceslog"

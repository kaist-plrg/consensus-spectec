  $ ./main.exe fold-var-or-else-premise.spectec 2>&1
  error[elab/fold-var-or-else-premise]: `var` and `otherwise` premises cannot be folded
    --> fold-var-or-else-premise.spectec:11:7
     |
  11 |   -- (var x_cur : foo)*{ x_0 -> x_cur ... x_next -> x_n }
     |       ^^^^^^^^^^^^^^^
     |
     | note: `var` and `otherwise` premises apply once per rule, so a fold cannot
     |       contain either premise.
  
  warning[elab/relation-missing-rules]: relation R has no rules defined
    --> fold-var-or-else-premise.spectec:5:1
    |
  5 | relation R:
    | ^^^^^^^^^^^
  6 |   foo |- foo
    | ^^^^^^^^^^^^
  7 |   hint(input %0)
    | ^^^^^^^^^^^^^^^^
  [1]

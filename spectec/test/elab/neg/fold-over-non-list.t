  $ ./main.exe fold-over-non-list.spectec 2>&1
  error[elab/fold-over-non-list]: a fold can only iterate over a list `*`
    --> fold-over-non-list.spectec:19:7
     |
  19 |   -- (Step: acc_cur |- n : acc_next)?{ acc_0 -> acc_cur ... acc_next -> acc_n }
     |       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
     |
     | note: A fold applies its body in list order and passes each accumulator
     |       value to the next iteration, so only `*` can be folded, not `?`.
  
  warning[elab/relation-missing-rules]: relation Sum has no rules defined
    --> fold-over-non-list.spectec:13:1
     |
  13 | relation Sum:
     | ^^^^^^^^^^^^^
  14 |   nat |- nat* : nat
     | ^^^^^^^^^^^^^^^^^^^
  15 |   hint(input %0 %1)
     | ^^^^^^^^^^^^^^^^^^^
  [1]

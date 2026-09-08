  $ ./main.exe fold-accumulator-dimension-mismatch.spectec 2>&1
  error[elab/fold-accumulator-dimension-mismatch]: a fold body produces its accumulator at the wrong dimension
    --> fold-accumulator-dimension-mismatch.spectec:21:32
     |
  21 |        *{ acc_0 -> acc_cur ... acc_next -> acc_n }
     |                                ^^^^^^^^
     |
     | note: The next accumulator value produced by the fold body must have the
     |       dimension declared on the accumulator endpoint.
  
  warning[elab/relation-missing-rules]: relation IterInFold has no rules defined
    --> fold-accumulator-dimension-mismatch.spectec:13:1
     |
  13 | relation IterInFold:
     | ^^^^^^^^^^^^^^^^^^^^
  14 |   nat |- nat** : nat
     | ^^^^^^^^^^^^^^^^^^^^
  15 |   hint(input %0 %1)
     | ^^^^^^^^^^^^^^^^^^^
  [1]

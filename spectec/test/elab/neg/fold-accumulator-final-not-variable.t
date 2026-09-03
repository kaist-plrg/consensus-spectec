  $ ./main.exe fold-accumulator-final-not-variable.spectec 2>&1
  error[parse/unexpected-token]: syntax error: unexpected token
    --> fold-accumulator-final-not-variable.spectec:19:73
     |
  19 |   -- (Step: acc_cur |- n : acc_next)*{ acc_0 -> acc_cur ... acc_next -> $(acc_0 + acc_0) }
     |                                                                         ^
  [1]

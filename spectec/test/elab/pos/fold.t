  $ ./main.exe fold.spectec 2>&1
  ;; fold.spectec:3:1-5:20:
  relation Step: nat |- nat : nat
  
     ;; fold.spectec:10:1-11:24:
     rule add: acc |- n : (acc + n)
  
  ;; fold.spectec:13:1-15:20:
  relation Sum: nat |- nat* : nat
  
     ;; fold.spectec:17:1-19:80:
     rule fold: acc_0 |- n*{n <- n*} : acc_n
        -- (rel Step: acc_cur |- n : acc_next)*{n <- n*, acc_0 -> acc_cur ... acc_next -> acc_n}

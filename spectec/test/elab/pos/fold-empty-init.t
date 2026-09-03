  $ ./main.exe fold-empty-init.spectec 2>&1
  ;; fold-empty-init.spectec:3:20-3:26:
  syntax pair<K, V> = 
     | K -> V (from pair<K, V>)
  
  ;; fold-empty-init.spectec:4:19-4:31:
  syntax map<K, V> = pair<K, V>*
  
  ;; fold-empty-init.spectec:6:14-6:23:
  syntax key = 
     | text (from key)
  
  ;; fold-empty-init.spectec:7:14-7:22:
  syntax val = 
     | nat (from val)
  
  ;; fold-empty-init.spectec:12:1-14:20:
  relation Insert: map<key, val> |- key : map<key, val>
  
     ;; fold-empty-init.spectec:16:1-17:28:
     rule one: m |- k : k -> 0 :: m
  
  ;; fold-empty-init.spectec:19:1-21:17:
  relation Collect: |- key*
  
     ;; fold-empty-init.spectec:23:1-25:74:
     rule fold: |- k*{k <- k*}
        -- (rel Insert: m_cur |- k : m_next)*{k <- k*, [] -> m_cur ... m_next -> m_final}

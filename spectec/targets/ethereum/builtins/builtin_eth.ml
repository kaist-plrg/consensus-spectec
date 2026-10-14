module Engine = Engine
module SszImpl = SszImpl

let builtins =
  [
    BlsImpl.builtins;
    Bytes.builtins;
    Debug.builtins;
    Engine.builtins;
    HashImpl.builtins;
    Lists.builtins;
    Math.builtins;
    MerkleImpl.builtins;
    SszImpl.builtins;
  ]
  |> List.concat

module Engine = Engine

let builtins =
  [
    BlsImpl.builtins;
    BlsPointImpl.builtins;
    Bytes.builtins;
    Debug.builtins;
    Engine.builtins;
    HashImpl.builtins;
    Lists.builtins;
    Math.builtins;
    MerkleImpl.builtins;
  ]
  |> List.concat

type document = Typed.t

exception Rejected = Error.Rejected

let load = Typed.load
let translate = Translate.translate

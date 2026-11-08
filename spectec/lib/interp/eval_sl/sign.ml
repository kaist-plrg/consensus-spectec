open Lang.Sl

type t = Bound of Ctx.t | Cont | Res of value list | Ret of value

Capella and Deneb specifications structure into SL.

  $ spectec struct ../../../spec/spec_capella/*.spectec --color never > capella.sl
  $ test -s capella.sl
  $ spectec struct ../../../spec/spec_deneb/*.spectec --color never > deneb.sl
  $ test -s deneb.sl

The forked package includes Ethereum and leaves upstream targets independent.

  $ grep -q 'target_plugins/ethereum/META' ../../../../spectec.install

  $ grep -q 'capella_specs/00-types.spectec' ../../../../spectec.install

  $ grep -q 'deneb_specs/00-types.spectec' ../../../../spectec.install

  $ grep -q 'targets/ethereum/pyspec/pyspec.cmi' ../../../../spectec.install

  $ spectec --help | grep '^  ethereum'
    ethereum                   . Ethereum commands

  $ spectec ethereum --help | grep '^  translate'
    translate                  . Translate pyspec source documents into SpecTec

  $ grep -Eq 'target_plugins/(impty|miniml|p4)/META' ../../../../spectec.install
  [1]

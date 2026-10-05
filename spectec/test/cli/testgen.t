Unsupported verification is rejected before reading inputs or creating output.

  $ spectec ethereum testgen --coverage missing.ckpt --verify --output rejected --color never
  error: testgen verification is not supported
  
    source: config
  [1]
  $ test ! -e rejected

Test generation reads the Ethereum configuration namespace.

  $ ../testgen_checkpoint/main.exe coverage.ckpt
  $ echo 'ethereum.spec_dir = missing-spec' > spectecx.config
  $ spectec ethereum testgen --coverage coverage.ckpt --premises 7 --output rejected --color never
  error: spec directory missing-spec does not exist; pass --spec or --spec-dir
  
    source: config
  [1]
  $ test ! -e rejected

Both specification flags override the configured directory.

  $ spectec ethereum testgen --coverage coverage.ckpt --premises 7 --spec-dir ../../specs/impty/base --test-dir missing-tests --output from-dir --color never > /dev/null
  [TypeTree] Loaded 5 types: env, map, prog, tenv, value
  $ test -d from-dir
  $ spectec ethereum testgen --coverage coverage.ckpt --premises 7 --spec ../../specs/impty/base/spec.spectec --test-dir missing-tests --output from-file --color never > /dev/null
  [TypeTree] Loaded 5 types: env, map, prog, tenv, value
  $ test -d from-file

Conflicting configuration is diagnosed even for list-only requests.

  $ echo 'ethereum.spec = ignored.spectec' >> spectecx.config
  $ spectec ethereum testgen --coverage coverage.ckpt --list --color never
  error: spectecx.config sets both 'ethereum.spec' and 'ethereum.spec_dir'; use one or the other
  
    source: config
  [1]

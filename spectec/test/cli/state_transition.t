State transitions export the post-state only after successful evaluation.

  $ gunzip -c ../dep_pos/pre.json.gz > pre.json
  $ spectec ethereum run state-transition --spec-dir ../../../spec/spec_capella --fork capella --pre pre.json --block ../dep_pos/block.json --output post.json --color never
  State transition succeeded
  $ python3 - <<'PY'
  > import json
  > with open('post.json') as f:
  >     post = json.load(f)
  > with open('../dep_pos/block.json') as f:
  >     block = json.load(f)
  > assert int(post['slot']) == block['message']['slot']
  > assert len(post['validators']) == 256
  > print('Post-state exported')
  > PY
  Post-state exported

Output cannot be shared by a batch.

  $ spectec ethereum run state-transition --fork capella --batch --output batch.json --color never
  error: --output requires a single input
  
    source: config
  [1]
  $ test ! -e batch.json

Failed transitions do not produce an output file.

  $ spectec ethereum run state-transition --spec-dir ../../../spec/spec_capella --fork capella --pre missing.json --block ../dep_pos/block.json --output failed.json --color never > /dev/null 2>&1
  [1]
  $ test ! -e failed.json

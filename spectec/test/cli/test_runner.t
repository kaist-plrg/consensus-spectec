The differential runner selects the current state-transition command in each mode without site packages.

  $ python3 -S - <<'PY'
  > import subprocess
  > import sys
  > from pathlib import Path
  > from tempfile import TemporaryDirectory
  > from unittest.mock import patch
  > sys.path.insert(0, '../../..')
  > from run_test_suite import TestRunner
  > with TemporaryDirectory(prefix='runner paths ') as directory:
  >     root = Path(directory).resolve()
  >     for mode in ('il', 'sl', 'pl'):
  >         runner = TestRunner(str(root / 'Converter'), str(root / 'spectecx'), run_mode=mode, fork='capella')
  >         output = root / 'post.json'
  >         output.touch()
  >         with patch('run_test_suite.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
  >             assert runner.run_spectec(root / 'pre.json', root / 'block.json', output) == (True, None)
  >             expected = [str(root / 'spectecx'), 'ethereum', 'run', 'state-transition', '--spec-dir', str(root / 'spec/spec_capella'), '--pre', str(root / 'pre.json'), '--block', str(root / 'block.json'), '--output', str(output)]
  >             if mode != 'il':
  >                 expected.append('--' + mode)
  >             assert run.call_args.args[0] == expected
  >             assert run.call_args.kwargs['check']
  > print('Runner command checks passed')
  > PY
  Runner command checks passed

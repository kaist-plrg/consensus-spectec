The Ethereum parser takes -t for the input's IL type and --tree for tree output.

  $ spectec ethereum parse -help | grep -e '-t TYPE' -e '--tree'
    -t TYPE                    . IL type name
    [--tree]                   . print the parsed values as a tree with locations

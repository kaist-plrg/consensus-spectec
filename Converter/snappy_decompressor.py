import sys
from pathlib import Path

import snappy


def decompress(input_file, output_file) -> bool:
    """Decompress a Snappy file, creating the output directory if needed.

    Input that does not decompress is written unchanged. Returns False if
    the file could not be read or written.
    """
    try:
        data = Path(input_file).read_bytes()
        # Official vectors use Snappy blocks without a stream identifier,
        # so decompression is attempted before treating input as raw SSZ.
        try:
            raw = snappy.decompress(data)
        except Exception:
            raw = data
        output_path = Path(output_file)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(raw)
        return True
    except OSError as e:
        print(f"  ✗ Snappy decompression failed: {e}")
        return False


if __name__ == "__main__":
    inp, outp = sys.argv[1], sys.argv[2]
    if not decompress(inp, outp):
        sys.exit(1)
    print("wrote", outp, "bytes:", Path(outp).stat().st_size)

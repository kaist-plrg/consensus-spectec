def total_unless_limited(values: Sequence[uint64], limit: uint64 = None) -> uint64:
    total = uint64(0)
    for value in values:
        if limit is None:
            total += value
    return total

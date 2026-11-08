def selected(values: Sequence[uint64], limit: uint64, unused: uint64 = None) -> Sequence[uint64]:
    result = [value for value in values if value < limit]
    alias = result
    alias.append(limit)
    return result


def accumulate(values: Sequence[uint64], limit: uint64) -> uint64:
    total = uint64(0)
    for value in values:
        if value > limit:
            break
        total += value
    return total


def count_distinct(values: Sequence[bool]) -> int:
    return sum(set(values))


def count_members(values: set[bool]) -> int:
    return sum(values)


def extend_alias(value: uint64) -> Sequence[uint64]:
    result = [value]
    alias = result
    result += [value]
    alias += alias
    return result

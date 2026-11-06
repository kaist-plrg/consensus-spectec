def scaled(value: uint64, double: bool = True) -> uint64:
    if double:
        return value * uint64(2)
    return value


def choose(value: uint64, fallback: uint64 = None) -> uint64:
    if fallback is not None and value == 0:
        return fallback
    assert value < UINT64_MAX
    return scaled(value=value + uint64(1))


def quotient(value: int, divisor: int) -> int:
    if value >= 0 and divisor > 0:
        return value // divisor
    return 0


def selected_operand(a: uint64, b: uint64, divisor: uint64) -> uint64:
    return a or b and uint64(8) // divisor

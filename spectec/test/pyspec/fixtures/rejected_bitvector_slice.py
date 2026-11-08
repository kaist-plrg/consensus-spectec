def bits_past_end(state: BeaconState) -> Sequence[bool]:
    return state.justification_bits[2:6]

def advance(state: BeaconState, amount: Slot) -> None:
    state.slot += amount


def update(state: BeaconState, index: ValidatorIndex, amount: Gwei) -> None:
    balances = state.balances
    previous = balances[index]
    balances[index] = previous + amount
    advance(state, Slot(1))
    if state.slot > 0:
        state.latest_block_header.slot = state.slot


def assign_values(state: BeaconState, index: ValidatorIndex, amount: int, balance: int) -> None:
    state.slot = amount
    state.balances[index] = balance

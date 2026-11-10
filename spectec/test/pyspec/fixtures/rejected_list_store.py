def unconverted_reward(values: Sequence[Gwei]) -> Sequence[Gwei]:
    rewards = [Gwei(0)] * len(values)
    rewards[0] = 5
    return rewards

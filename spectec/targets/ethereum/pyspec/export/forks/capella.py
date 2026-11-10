REVISION = "f96d3e7acf35125295d234da4b0c67591fdef49c"
FORK = "capella"
PRESET = "mainnet"


# The exporter translates the functions that this entry function reaches.
ENTRY = "state_transition"


# State fields that each listed pure helper may read during a set loop that
# writes the state. The exporter checks each entry against the pinned source.
# Translation rejects a call in a set loop that passes the state to an unlisted
# function.
REVIEWED_STATE_READS = {
    "get_current_epoch": ["slot"],
    "get_previous_epoch": ["slot"],
    "get_total_active_balance": ["slot", "validators"],
    "get_base_reward_per_increment": ["slot", "validators"],
    "get_base_reward": ["slot", "validators"],
}


# Record types a function body may construct by calling the type's name.
REVIEWED_RECORD_CONSTRUCTORS = (
    "Checkpoint",
    "Validator",
    "HistoricalSummary",
    "SyncCommittee",
    "BeaconBlockHeader",
    "ForkData",
    "SigningData",
    "ExecutionPayloadHeader",
    "IndexedAttestation",
    "DepositMessage",
    "Withdrawal",
)


# Functions whose tuple result the module document lists as newly built.
# Translation rejects a tuple-valued call to an unlisted function.
REVIEWED_FRESH_RESULTS = ("get_flag_index_deltas", "get_inactivity_penalty_deltas")


# prelude.spectec implements this source as `$translated_set_or_append_list`.
# The exporter rejects a module whose `set_or_append_list` has other source
# text.
REVIEWED_SET_OR_APPEND_LIST = """\
def set_or_append_list(list: List, index: ValidatorIndex, value: Any) -> None:
    if index == len(list):
        list.append(value)
    else:
        list[index] = value
"""


# The pinned pyspec wraps these functions in `cache_this`. Each entry is the
# source of the reviewed cache key, which `source_function` compares by bytecode
# before it returns the wrapped original.
REVIEWED_CACHE_KEYS = {
    "get_committee_count_per_slot": "lambda state, epoch: (state.validators.hash_tree_root(), epoch)",
    "get_active_validator_indices": "lambda state, epoch: (state.validators.hash_tree_root(), epoch)",
    "get_total_active_balance": "lambda state: (state.validators.hash_tree_root(), compute_epoch_at_slot(state.slot))",
    "get_base_reward": "lambda state, index: (state.validators.hash_tree_root(), state.slot, index)",
    "compute_shuffled_index": "lambda index, index_count, seed: (index, index_count, seed)",
    "get_beacon_committee": "lambda state, slot, index: (state.validators.hash_tree_root(), state.randao_mixes.hash_tree_root(), slot, index)",
    "get_attesting_indices": "lambda state, attestation: (state.randao_mixes.hash_tree_root(), state.validators.hash_tree_root(), attestation.hash_tree_root())",
}

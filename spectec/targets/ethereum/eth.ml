(** Ethereum Target - Main module exporting all components *)

module Target = Eth_common.Target
module StateTransition = State_transition.StateTransition

let set_default_validate_result = State_transition.set_default_validate_result
let test_dir = Eth_common.test_base_dir

module Operations = Operations
module Epoch = Epoch
module Slots = Slots.Slots
module JsonParse = Eth_common.JsonParse

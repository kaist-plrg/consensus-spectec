open Targets_eth.Eth

module State_transition_cli : Cli.Task_cli.S = struct
  module Task = StateTransition

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and block =
      flag "--block" (optional_with_default "" string) ~doc:"FILE block JSON"
    and no_validate =
      flag "--no-validate" no_arg ~doc:" skip state root validation"
    in
    Task.make ~validate_result:(not no_validate) ~pre_file:pre ~block_file:block
      ()
end

module Proposer_slashing_cli : Cli.Task_cli.S = struct
  module Task = Operations.ProposerSlashing

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and slashing =
      flag "--slashing"
        (optional_with_default "" string)
        ~doc:"FILE proposer slashing JSON"
    in
    Task.make ~pre_file:pre ~proposer_slashing_file:slashing ()
end

module Attester_slashing_cli : Cli.Task_cli.S = struct
  module Task = Operations.AttesterSlashing

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and slashing =
      flag "--slashing"
        (optional_with_default "" string)
        ~doc:"FILE attester slashing JSON"
    in
    Task.make ~pre_file:pre ~attester_slashing_file:slashing ()
end

module Attestation_cli : Cli.Task_cli.S = struct
  module Task = Operations.Attestation

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and attestation =
      flag "--attestation"
        (optional_with_default "" string)
        ~doc:"FILE attestation JSON"
    in
    Task.make ~pre_file:pre ~attestation_file:attestation ()
end

module Deposit_cli : Cli.Task_cli.S = struct
  module Task = Operations.Deposit

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and deposit =
      flag "--deposit"
        (optional_with_default "" string)
        ~doc:"FILE deposit JSON"
    in
    Task.make ~pre_file:pre ~deposit_file:deposit ()
end

module Voluntary_exit_cli : Cli.Task_cli.S = struct
  module Task = Operations.VoluntaryExit

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and exit =
      flag "--exit"
        (optional_with_default "" string)
        ~doc:"FILE voluntary exit JSON"
    in
    Task.make ~pre_file:pre ~voluntary_exit_file:exit ()
end

module Bls_to_execution_change_cli : Cli.Task_cli.S = struct
  module Task = Operations.BlsToExecutionChange

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and change =
      flag "--change"
        (optional_with_default "" string)
        ~doc:"FILE address change JSON"
    in
    Task.make ~pre_file:pre ~address_change_file:change ()
end

module Execution_payload_cli : Cli.Task_cli.S = struct
  module Task = Operations.ExecutionPayload

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and payload =
      flag "--payload"
        (optional_with_default "" string)
        ~doc:"FILE execution payload JSON"
    and execution =
      flag "--execution" (optional string) ~doc:"FILE execution data JSON"
    in
    Task.make ~pre_file:pre ~execution_payload_file:payload
      ?execution_data_file:execution ()
end

module Withdrawals_cli : Cli.Task_cli.S = struct
  module Task = Operations.Withdrawals

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and payload =
      flag "--payload"
        (optional_with_default "" string)
        ~doc:"FILE execution payload JSON"
    in
    Task.make ~pre_file:pre ~execution_payload_file:payload ()
end

module Block_header_cli : Cli.Task_cli.S = struct
  module Task = Operations.BlockHeader

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and block =
      flag "--block" (optional_with_default "" string) ~doc:"FILE block JSON"
    in
    Task.make ~pre_file:pre ~block_file:block ()
end

module Sync_aggregate_cli : Cli.Task_cli.S = struct
  module Task = Operations.SyncAggregate

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and aggregate =
      flag "--aggregate"
        (optional_with_default "" string)
        ~doc:"FILE sync aggregate JSON"
    in
    Task.make ~pre_file:pre ~sync_aggregate_file:aggregate ()
end

module type Epoch_task = sig
  include Spectec.Task.S

  val make :
    ?expect:Spectec.Task.expectation -> pre_file:string -> unit -> input
end

module Make_epoch_cli (Task : Epoch_task) : Cli.Task_cli.S = struct
  module Task = Task

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    in
    Task.make ~pre_file:pre ()
end

module Justification_cli = Make_epoch_cli (Epoch.JustificationAndFinalization)
module Inactivity_updates_cli = Make_epoch_cli (Epoch.InactivityUpdates)
module Rewards_cli = Make_epoch_cli (Epoch.RewardsAndPenalties)
module Registry_updates_cli = Make_epoch_cli (Epoch.RegistryUpdates)
module Slashings_cli = Make_epoch_cli (Epoch.Slashings)
module Eth1_data_reset_cli = Make_epoch_cli (Epoch.Eth1DataReset)

module Effective_balance_updates_cli =
  Make_epoch_cli (Epoch.EffectiveBalanceUpdates)

module Slashings_reset_cli = Make_epoch_cli (Epoch.SlashingsReset)
module Randao_mixes_reset_cli = Make_epoch_cli (Epoch.RandaoMixesReset)

module Historical_summaries_update_cli =
  Make_epoch_cli (Epoch.HistoricalSummariesUpdate)

module Participation_flag_updates_cli =
  Make_epoch_cli (Epoch.ParticipationFlagUpdates)

module Slots_cli : Cli.Task_cli.S = struct
  module Task = Slots

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and slots =
      flag "--slots" (optional_with_default "" string) ~doc:"FILE slots YAML"
    in
    Task.make ~pre_file:pre ~slots_file:slots ()
end

module Json_parse_cli : Cli.Task_cli.S = struct
  module Task = JsonParse

  let flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map json_file =
      flag "-p" (required string) ~doc:"FILE JSON file to parse"
    and input_type = flag "-t" (required string) ~doc:"TYPE IL type name" in
    Task.make ~json_file ~input_type ()
end

let target = (module Target : Spectec.Target.S)
let task ~name ~summary cli = Cli.Subcommand.make_task target ~name ~summary cli

let operations =
  Core.Command.group ~summary:"Operation and block processing tasks"
    [
      task ~name:"proposer-slashing" ~summary:"Process proposer slashing"
        (module Proposer_slashing_cli);
      task ~name:"attester-slashing" ~summary:"Process attester slashing"
        (module Attester_slashing_cli);
      task ~name:"attestation" ~summary:"Process attestation"
        (module Attestation_cli);
      task ~name:"deposit" ~summary:"Process deposit" (module Deposit_cli);
      task ~name:"voluntary-exit" ~summary:"Process voluntary exit"
        (module Voluntary_exit_cli);
      task ~name:"bls-to-execution-change"
        ~summary:"Process BLS to execution change"
        (module Bls_to_execution_change_cli);
      task ~name:"execution-payload" ~summary:"Process execution payload"
        (module Execution_payload_cli);
      task ~name:"withdrawals" ~summary:"Process withdrawals"
        (module Withdrawals_cli);
      task ~name:"block-header" ~summary:"Process block header"
        (module Block_header_cli);
      task ~name:"sync-aggregate" ~summary:"Process sync aggregate"
        (module Sync_aggregate_cli);
    ]

let epoch =
  Core.Command.group ~summary:"Epoch processing tasks"
    [
      task ~name:"justification"
        ~summary:"Process justification and finalization"
        (module Justification_cli);
      task ~name:"inactivity-updates" ~summary:"Process inactivity updates"
        (module Inactivity_updates_cli);
      task ~name:"rewards" ~summary:"Process rewards and penalties"
        (module Rewards_cli);
      task ~name:"registry-updates" ~summary:"Process registry updates"
        (module Registry_updates_cli);
      task ~name:"slashings" ~summary:"Process slashings" (module Slashings_cli);
      task ~name:"eth1-data-reset" ~summary:"Process eth1 data reset"
        (module Eth1_data_reset_cli);
      task ~name:"effective-balance-updates"
        ~summary:"Process effective balance updates"
        (module Effective_balance_updates_cli);
      task ~name:"slashings-reset" ~summary:"Process slashings reset"
        (module Slashings_reset_cli);
      task ~name:"randao-mixes-reset" ~summary:"Process randao mixes reset"
        (module Randao_mixes_reset_cli);
      task ~name:"historical-summaries-update"
        ~summary:"Process historical summaries update"
        (module Historical_summaries_update_cli);
      task ~name:"participation-flag-updates"
        ~summary:"Process participation flag updates"
        (module Participation_flag_updates_cli);
    ]

let task_clis : (module Cli.Task_cli.S) list =
  [
    (module Proposer_slashing_cli);
    (module Attester_slashing_cli);
    (module Attestation_cli);
    (module Deposit_cli);
    (module Voluntary_exit_cli);
    (module Bls_to_execution_change_cli);
    (module Execution_payload_cli);
    (module Withdrawals_cli);
    (module Block_header_cli);
    (module Sync_aggregate_cli);
    (module Justification_cli);
    (module Inactivity_updates_cli);
    (module Rewards_cli);
    (module Registry_updates_cli);
    (module Slashings_cli);
    (module Eth1_data_reset_cli);
    (module Effective_balance_updates_cli);
    (module Slashings_reset_cli);
    (module Randao_mixes_reset_cli);
    (module Historical_summaries_update_cli);
    (module Participation_flag_updates_cli);
    (module Slots_cli);
    (module State_transition_cli);
  ]

let run =
  Core.Command.group ~summary:"Run Ethereum test tasks"
    [
      ("epoch", epoch);
      ("operations", operations);
      task ~name:"slots" ~summary:"Process slots" (module Slots_cli);
      task ~name:"state-transition" ~summary:"Run Ethereum state transition"
        (module State_transition_cli);
    ]

let name = Target.name

let command =
  Core.Command.group ~summary:"Ethereum commands"
    [
      ("run", run);
      Cli.Subcommand.make_batch
        ~on_no_validate:(fun () -> set_default_validate_result false)
        ~slot_gap_filter:Runner.Testgen.slot_gap_within_limit_for_source target
        ~name:"coverage" task_clis;
      Cli.Subcommand.make_checkpoint target ~name:"checkpoint";
      ("testgen", Eth_testgen.command);
      Cli.Subcommand.make_parse target ~name:"parse"
        ~summary:"Parse an Ethereum JSON value"
        (module Json_parse_cli);
    ]

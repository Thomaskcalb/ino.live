defmodule BlockScoutWeb.API.V2.TransactionView do
  use BlockScoutWeb, :view

  alias BlockScoutWeb.API.V2.{ApiView, Helper, TokenView}
  alias BlockScoutWeb.{ABIEncodedValueView, TransactionView}
  alias BlockScoutWeb.Models.GetTransactionTags
  alias BlockScoutWeb.Tokens.Helper, as: TokensHelper
  alias BlockScoutWeb.TransactionStateView
  alias Ecto.Association.NotLoaded
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.{Address, Block, InternalTransaction, Log, Token, Transaction, Wei}
  alias Explorer.Chain.Block.Reward
  alias Explorer.Chain.Optimism.Withdrawal, as: OptimismWithdrawal
  alias Explorer.Chain.PolygonEdge.Reader
  alias Explorer.Chain.Transaction.StateChange
  alias Explorer.Counters.AverageBlockTime
  alias Timex.Duration

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]
  import Explorer.Chain.Transaction, only: [maybe_prepare_stability_fees: 1, bytes_to_address_hash: 1]

  @api_true [api?: true]

  def render("message.json", assigns) do
    ApiView.render("message.json", assigns)
  end

  def render("transactions_watchlist.json", %{
        transactions: transactions,
        next_page_params: next_page_params,
        conn: conn,
        watchlist_names: watchlist_names
      }) do
    block_height = Chain.block_height(@api_true)
    {decoded_transactions, _, _} = decode_transactions(transactions, true)

    %{
      "items" =>
        transactions
        |> maybe_prepare_stability_fees()
        |> Enum.zip(decoded_transactions)
        |> Enum.map(fn {tx, decoded_input} ->
          prepare_transaction(tx, conn, false, block_height, watchlist_names, decoded_input)
        end),
      "next_page_params" => next_page_params
    }
  end

  def render("transactions_watchlist.json", %{
        transactions: transactions,
        conn: conn,
        watchlist_names: watchlist_names
      }) do
    block_height = Chain.block_height(@api_true)
    {decoded_transactions, _, _} = decode_transactions(transactions, true)

    transactions
    |> maybe_prepare_stability_fees()
    |> Enum.zip(decoded_transactions)
    |> Enum.map(fn {tx, decoded_input} ->
      prepare_transaction(tx, conn, false, block_height, watchlist_names, decoded_input)
    end)
  end

  def render("transactions.json", %{transactions: transactions, next_page_params: next_page_params, conn: conn}) do
    block_height = Chain.block_height(@api_true)
    {decoded_transactions, _, _} = decode_transactions(transactions, true)

    %{
      "items" =>
        transactions
        |> maybe_prepare_stability_fees()
        |> Enum.zip(decoded_transactions)
        |> Enum.map(fn {tx, decoded_input} -> prepare_transaction(tx, conn, false, block_height, decoded_input) end),
      "next_page_params" => next_page_params
    }
  end

  def render("transactions.json", %{transactions: transactions, items: true, conn: conn}) do
    %{
      "items" => render("transactions.json", %{transactions: transactions, conn: conn})
    }
  end

  def render("transactions.json", %{transactions: transactions, conn: conn}) do
    block_height = Chain.block_height(@api_true)
    {decoded_transactions, _, _} = decode_transactions(transactions, true)

    transactions
    |> maybe_prepare_stability_fees()
    |> Enum.zip(decoded_transactions)
    |> Enum.map(fn {tx, decoded_input} -> prepare_transaction(tx, conn, false, block_height, decoded_input) end)
  end

  def render("transaction.json", %{transaction: transaction, conn: conn}) do
    block_height = Chain.block_height(@api_true)
    {[decoded_input], _, _} = decode_transactions([transaction], false)
    prepare_transaction(transaction |> maybe_prepare_stability_fees(), conn, true, block_height, decoded_input)
  end

  def render("raw_trace.json", %{internal_transactions: internal_transactions}) do
    InternalTransaction.internal_transactions_to_raw(internal_transactions)
  end

  def render("decoded_log_input.json", %{method_id: method_id, text: text, mapping: mapping}) do
    %{"method_id" => method_id, "method_call" => text, "parameters" => prepare_log_mapping(mapping)}
  end

  def render("decoded_input.json", %{method_id: method_id, text: text, mapping: mapping, error?: _error}) do
    %{"method_id" => method_id, "method_call" => text, "parameters" => prepare_method_mapping(mapping)}
  end

  def render("revert_reason.json", %{raw: raw}) do
    %{"raw" => raw}
  end

  def render("token_transfers.json", %{token_transfers: token_transfers, next_page_params: next_page_params, conn: conn}) do
    {decoded_transactions, _, _} = decode_transactions(Enum.map(token_transfers, fn tt -> tt.transaction end), true)

    %{
      "items" =>
        token_transfers
        |> Enum.zip(decoded_transactions)
        |> Enum.map(fn {tt, decoded_input} -> prepare_token_transfer(tt, conn, decoded_input) end),
      "next_page_params" => next_page_params
    }
  end

  def render("token_transfers.json", %{token_transfers: token_transfers, conn: conn}) do
    {decoded_transactions, _, _} = decode_transactions(Enum.map(token_transfers, fn tt -> tt.transaction end), true)

    token_transfers
    |> Enum.zip(decoded_transactions)
    |> Enum.map(fn {tt, decoded_input} -> prepare_token_transfer(tt, conn, decoded_input) end)
  end

  def render("token_transfer.json", %{token_transfer: token_transfer, conn: conn}) do
    {[decoded_transaction], _, _} = decode_transactions([token_transfer.transaction], true)
    prepare_token_transfer(token_transfer, conn, decoded_transaction)
  end

  def render("transaction_actions.json", %{actions: actions}) do
    Enum.map(actions, &prepare_transaction_action(&1))
  end

  def render("internal_transactions.json", %{
        internal_transactions: internal_transactions,
        next_page_params: next_page_params,
        conn: conn
      }) do
    %{
      "items" => Enum.map(internal_transactions, &prepare_internal_transaction(&1, conn)),
      "next_page_params" => next_page_params
    }
  end

  def render("logs.json", %{logs: logs, next_page_params: next_page_params, tx_hash: tx_hash}) do
    decoded_logs = decode_logs(logs, false)

    %{
      "items" =>
        logs |> Enum.zip(decoded_logs) |> Enum.map(fn {log, decoded_log} -> prepare_log(log, tx_hash, decoded_log) end),
      "next_page_params" => next_page_params
    }
  end

  def render("logs.json", %{logs: logs, next_page_params: next_page_params}) do
    decoded_logs = decode_logs(logs, false)

    %{
      "items" =>
        logs
        |> Enum.zip(decoded_logs)
        |> Enum.map(fn {log, decoded_log} -> prepare_log(log, log.transaction, decoded_log) end),
      "next_page_params" => next_page_params
    }
  end

  def render("state_changes.json", %{state_changes: state_changes, next_page_params: next_page_params}) do
    %{
      "items" => Enum.map(state_changes, &prepare_state_change(&1)),
      "next_page_params" => next_page_params
    }
  end

  @doc """
    Decodes list of logs
  """
  @spec decode_logs([Log.t()], boolean) :: [tuple]
  def decode_logs(logs, skip_sig_provider?) do
    {result, _, _} =
      Enum.reduce(logs, {[], %{}, %{}}, fn log, {results, contracts_acc, events_acc} ->
        {result, contracts_acc, events_acc} =
          Log.decode(
            log,
            %Transaction{hash: log.transaction_hash},
            @api_true,
            skip_sig_provider?,
            contracts_acc,
            events_acc
          )

        {[format_decoded_log_input(result) | results], contracts_acc, events_acc}
      end)

    Enum.reverse(result)
  end

  def decode_transactions(transactions, skip_sig_provider?) do
    {results, abi_acc, methods_acc} =
      Enum.reduce(transactions, {[], %{}, %{}}, fn transaction, {results, abi_acc, methods_acc} ->
        {result, abi_acc, methods_acc} =
          Transaction.decoded_input_data(transaction, skip_sig_provider?, @api_true, abi_acc, methods_acc)

        {[format_decoded_input(result) | results], abi_acc, methods_acc}
      end)

    {Enum.reverse(results), abi_acc, methods_acc}
  end

  def prepare_token_transfer(token_transfer, _conn, decoded_input) do
    %{
      "tx_hash" => token_transfer.transaction_hash,
      "from" => Helper.address_with_info(nil, token_transfer.from_address, token_transfer.from_address_hash, false),
      "to" => Helper.address_with_info(nil, token_transfer.to_address, token_transfer.to_address_hash, false),
      "total" => prepare_token_transfer_total(token_transfer),
      "token" => TokenView.render("token.json", %{token: token_transfer.token}),
      "type" => Chain.get_token_transfer_type(token_transfer),
      "timestamp" =>
        if(match?(%NotLoaded{}, token_transfer.block),
          do: block_timestamp(token_transfer.transaction),
          else: block_timestamp(token_transfer.block)
        ),
      "method" => method_name(token_transfer.transaction, decoded_input, true),
      "block_hash" => to_string(token_transfer.block_hash),
      "log_index" => to_string(token_transfer.log_index)
    }
  end

  def prepare_transaction_action(action) do
    %{
      "protocol" => action.protocol,
      "type" => action.type,
      "data" => action.data
    }
  end

  # credo:disable-for-next-line /Complexity/
  def prepare_token_transfer_total(token_transfer) do
    case TokensHelper.token_transfer_amount_for_api(token_transfer) do
      {:ok, :erc721_instance} ->
        %{"token_id" => token_transfer.token_ids && List.first(token_transfer.token_ids)}

      {:ok, :erc1155_instance, value, decimals} ->
        %{
          "token_id" => token_transfer.token_ids && List.first(token_transfer.token_ids),
          "value" => value,
          "decimals" => decimals
        }

      {:ok, :erc1155_instance, values, token_ids, decimals} ->
        %{
          "token_id" => token_ids && List.first(token_ids),
          "value" => values && List.first(values),
          "decimals" => decimals
        }

      {:ok, value, decimals} ->
        %{"value" => value, "decimals" => decimals}

      _ ->
        nil
    end
  end

  def prepare_internal_transaction(internal_transaction, _conn) do
    %{
      "error" => internal_transaction.error,
      "success" => is_nil(internal_transaction.error),
      "type" => internal_transaction.call_type || internal_transaction.type,
      "transaction_hash" => internal_transaction.transaction_hash,
      "from" =>
        Helper.address_with_info(nil, internal_transaction.from_address, internal_transaction.from_address_hash, false),
      "to" =>
        Helper.address_with_info(nil, internal_transaction.to_address, internal_transaction.to_address_hash, false),
      "created_contract" =>
        Helper.address_with_info(
          nil,
          internal_transaction.created_contract_address,
          internal_transaction.created_contract_address_hash,
          false
        ),
      "value" => internal_transaction.value,
      "block" => internal_transaction.block_number,
      "timestamp" => internal_transaction.block.timestamp,
      "index" => internal_transaction.index,
      "gas_limit" => internal_transaction.gas
    }
  end

  def prepare_log(log, transaction_or_hash, decoded_log, tags_for_address_needed? \\ false) do
    decoded = process_decoded_log(decoded_log)

    %{
      "tx_hash" => get_tx_hash(transaction_or_hash),
      "address" => Helper.address_with_info(nil, log.address, log.address_hash, tags_for_address_needed?),
      "topics" => [
        log.first_topic,
        log.second_topic,
        log.third_topic,
        log.fourth_topic
      ],
      "data" => log.data,
      "index" => log.index,
      "decoded" => decoded,
      "smart_contract" => smart_contract_info(transaction_or_hash),
      "block_number" => log.block_number,
      "block_hash" => log.block_hash
    }
  end

  defp get_tx_hash(%Transaction{} = tx), do: to_string(tx.hash)
  defp get_tx_hash(hash), do: to_string(hash)

  defp smart_contract_info(%Transaction{} = tx),
    do: Helper.address_with_info(nil, tx.to_address, tx.to_address_hash, false)

  defp smart_contract_info(_), do: nil

  defp process_decoded_log(decoded_log) do
    case decoded_log do
      {:ok, method_id, text, mapping} ->
        render(__MODULE__, "decoded_log_input.json", method_id: method_id, text: text, mapping: mapping)

      _ ->
        nil
    end
  end

  defp prepare_transaction(tx, conn, single_tx?, block_height, watchlist_names \\ nil, decoded_input)

  defp prepare_transaction(
         {%Reward{} = emission_reward, %Reward{} = validator_reward},
         conn,
         single_tx?,
         _block_height,
         _watchlist_names,
         _decoded_input
       ) do
    %{
      "emission_reward" => emission_reward.reward,
      "block_hash" => validator_reward.block_hash,
      "from" =>
        Helper.address_with_info(single_tx? && conn, emission_reward.address, emission_reward.address_hash, single_tx?),
      "to" =>
        Helper.address_with_info(
          single_tx? && conn,
          validator_reward.address,
          validator_reward.address_hash,
          single_tx?
        ),
      "types" => [:reward]
    }
  end

  defp prepare_transaction(%Transaction{} = transaction, conn, single_tx?, block_height, watchlist_names, decoded_input) do
    base_fee_per_gas = transaction.block && transaction.block.base_fee_per_gas
    max_priority_fee_per_gas = transaction.max_priority_fee_per_gas
    max_fee_per_gas = transaction.max_fee_per_gas

    priority_fee_per_gas = Transaction.priority_fee_per_gas(max_priority_fee_per_gas, base_fee_per_gas, max_fee_per_gas)

    burnt_fees = burnt_fees(transaction, max_fee_per_gas, base_fee_per_gas)

    status = transaction |> Chain.transaction_to_status() |> format_status()

    revert_reason = revert_reason(status, transaction)

    decoded_input_data = decoded_input(decoded_input)

    result = %{
      "hash" => transaction.hash,
      "result" => status,
      "status" => transaction.status,
      "block" => transaction.block_number,
      "timestamp" => block_timestamp(transaction),
      "from" =>
        Helper.address_with_info(
          single_tx? && conn,
          transaction.from_address,
          transaction.from_address_hash,
          single_tx?,
          watchlist_names
        ),
      "to" =>
        Helper.address_with_info(
          single_tx? && conn,
          transaction.to_address,
          transaction.to_address_hash,
          single_tx?,
          watchlist_names
        ),
      "created_contract" =>
        Helper.address_with_info(
          single_tx? && conn,
          transaction.created_contract_address,
          transaction.created_contract_address_hash,
          single_tx?,
          watchlist_names
        ),
      "confirmations" => transaction.block |> Chain.confirmations(block_height: block_height) |> format_confirmations(),
      "confirmation_duration" => processing_time_duration(transaction),
      "value" => transaction.value,
      "fee" => transaction |> Transaction.fee(:wei) |> format_fee(),
      "gas_price" => transaction.gas_price || Transaction.effective_gas_price(transaction),
      "type" => transaction.type,
      "gas_used" => transaction.gas_used,
      "gas_limit" => transaction.gas,
      "max_fee_per_gas" => transaction.max_fee_per_gas,
      "max_priority_fee_per_gas" => transaction.max_priority_fee_per_gas,
      "base_fee_per_gas" => base_fee_per_gas,
      "priority_fee" => priority_fee_per_gas && Wei.mult(priority_fee_per_gas, transaction.gas_used),
      "tx_burnt_fee" => burnt_fees,
      "nonce" => transaction.nonce,
      "position" => transaction.index,
      "revert_reason" => revert_reason,
      "raw_input" => transaction.input,
      "decoded_input" => decoded_input_data,
      "token_transfers" => token_transfers(transaction.token_transfers, conn, single_tx?),
      "token_transfers_overflow" => token_transfers_overflow(transaction.token_transfers, single_tx?),
      "actions" => transaction_actions(transaction.transaction_actions),
      "exchange_rate" => Market.get_coin_exchange_rate().usd_value,
      "method" => method_name(transaction, decoded_input),
      "tx_types" => tx_types(transaction),
      "tx_tag" => GetTransactionTags.get_transaction_tags(transaction.hash, current_user(single_tx? && conn)),
      "has_error_in_internal_txs" => transaction.has_error_in_internal_txs
    }

    result
    |> chain_type_fields(transaction, single_tx?, conn, watchlist_names)
    |> maybe_put_stability_fee(transaction)
  end

  defp add_optional_transaction_field(result, transaction, field) do
    case Map.get(transaction, field) do
      nil -> result
      value -> Map.put(result, Atom.to_string(field), value)
    end
  end

  # credo:disable-for-next-line
  defp chain_type_fields(result, transaction, single_tx?, conn, watchlist_names) do
    case {single_tx?, Application.get_env(:explorer, :chain_type)} do
      {true, "polygon_edge"} ->
        result
        |> Map.put("polygon_edge_deposit", polygon_edge_deposit(transaction.hash, conn))
        |> Map.put("polygon_edge_withdrawal", polygon_edge_withdrawal(transaction.hash, conn))

      {true, "polygon_zkevm"} ->
        extended_result =
          result
          |> add_optional_transaction_field(transaction, "zkevm_batch_number", :zkevm_batch, :number)
          |> add_optional_transaction_field(transaction, "zkevm_sequence_hash", :zkevm_sequence_transaction, :hash)
          |> add_optional_transaction_field(transaction, "zkevm_verify_hash", :zkevm_verify_transaction, :hash)

        Map.put(extended_result, "zkevm_status", zkevm_status(extended_result))

      {true, "optimism"} ->
        result
        |> add_optional_transaction_field(transaction, :l1_fee)
        |> add_optional_transaction_field(transaction, :l1_fee_scalar)
        |> add_optional_transaction_field(transaction, :l1_gas_price)
        |> add_optional_transaction_field(transaction, :l1_gas_used)
        |> add_optimism_fields(transaction.hash, single_tx?)

      {true, "suave"} ->
        suave_fields(transaction, result, single_tx?, conn, watchlist_names)

      {_, "ethereum"} ->
        case Map.get(transaction, :beacon_blob_transaction) do
          nil ->
            result

          %Ecto.Association.NotLoaded{} ->
            result

          item ->
            result
            |> Map.put("max_fee_per_blob_gas", item.max_fee_per_blob_gas)
            |> Map.put("blob_versioned_hashes", item.blob_versioned_hashes)
            |> Map.put("blob_gas_used", item.blob_gas_used)
            |> Map.put("blob_gas_price", item.blob_gas_price)
            |> Map.put("burnt_blob_fee", Decimal.mult(item.blob_gas_used, item.blob_gas_price))
        end

      _ ->
        result
    end
  end

  defp add_optional_transaction_field(result, transaction, field_name, assoc_name, assoc_field) do
    case Map.get(transaction, assoc_name) do
      nil -> result
      %Ecto.Association.NotLoaded{} -> result
      item -> Map.put(result, field_name, Map.get(item, assoc_field))
    end
  end

  defp zkevm_status(result_map) do
    if is_nil(Map.get(result_map, "zkevm_sequence_hash")) do
      "Confirmed by Sequencer"
    else
      "L1 Confirmed"
    end
  end

  if Application.compile_env(:explorer, :chain_type) != "suave" do
    defp suave_fields(_transaction, result, _single_tx?, _conn, _watchlist_names), do: result
  else
    defp suave_fields(transaction, result, single_tx?, conn, watchlist_names) do
      if is_nil(transaction.execution_node_hash) do
        result
      else
        {[wrapped_decoded_input], _, _} =
          decode_transactions(
            [
              %Transaction{
                to_address: transaction.wrapped_to_address,
                input: transaction.wrapped_input,
                hash: transaction.wrapped_hash
              }
            ],
            false
          )

        result
        |> Map.put("allowed_peekers", Transaction.suave_parse_allowed_peekers(transaction.logs))
        |> Map.put(
          "execution_node",
          Helper.address_with_info(
            conn,
            transaction.execution_node,
            transaction.execution_node_hash,
            single_tx?,
            watchlist_names
          )
        )
        |> Map.put("wrapped", %{
          "type" => transaction.wrapped_type,
          "nonce" => transaction.wrapped_nonce,
          "to" =>
            Helper.address_with_info(
              conn,
              transaction.wrapped_to_address,
              transaction.wrapped_to_address_hash,
              single_tx?,
              watchlist_names
            ),
          "gas_limit" => transaction.wrapped_gas,
          "gas_price" => transaction.wrapped_gas_price,
          "fee" =>
            format_fee(
              Transaction.fee(
                %Transaction{gas: transaction.wrapped_gas, gas_price: transaction.wrapped_gas_price, gas_used: nil},
                :wei
              )
            ),
          "max_priority_fee_per_gas" => transaction.wrapped_max_priority_fee_per_gas,
          "max_fee_per_gas" => transaction.wrapped_max_fee_per_gas,
          "value" => transaction.wrapped_value,
          "hash" => transaction.wrapped_hash,
          "method" =>
            method_name(
              %Transaction{to_address: transaction.wrapped_to_address, input: transaction.wrapped_input},
              wrapped_decoded_input
            ),
          "decoded_input" => decoded_input(wrapped_decoded_input),
          "raw_input" => transaction.wrapped_input
        })
      end
    end
  end

  defp add_optimism_fields(result, transaction_hash, single_tx?) do
    if Application.get_env(:explorer, :chain_type) == "optimism" && single_tx? do
      withdrawals =
        transaction_hash
        |> OptimismWithdrawal.transaction_statuses()
        |> Enum.map(fn {nonce, status, l1_transaction_hash} ->
          %{
            "nonce" => nonce,
            "status" => status,
            "l1_transaction_hash" => l1_transaction_hash
          }
        end)

      Map.put(result, "op_withdrawals", withdrawals)
    else
      result
    end
  end

  def token_transfers(_, _conn, false), do: nil
  def token_transfers(%NotLoaded{}, _conn, _), do: nil

  def token_transfers(token_transfers, conn, _) do
    render("token_transfers.json", %{
      token_transfers: Enum.take(token_transfers, Chain.get_token_transfers_per_transaction_preview_count()),
      conn: conn
    })
  end

  def token_transfers_overflow(_, false), do: nil
  def token_transfers_overflow(%NotLoaded{}, _), do: false

  def token_transfers_overflow(token_transfers, _),
    do: Enum.count(token_transfers) > Chain.get_token_transfers_per_transaction_preview_count()

  def transaction_actions(%NotLoaded{}), do: []

  @doc """
    Renders transaction actions
  """
  def transaction_actions(actions) do
    render("transaction_actions.json", %{actions: actions})
  end

  defp burnt_fees(transaction, max_fee_per_gas, base_fee_per_gas) do
    if !is_nil(max_fee_per_gas) and !is_nil(transaction.gas_used) and !is_nil(base_fee_per_gas) do
      if Decimal.compare(max_fee_per_gas.value, 0) == :eq do
        %Wei{value: Decimal.new(0)}
      else
        Wei.mult(base_fee_per_gas, transaction.gas_used)
      end
    else
      nil
    end
  end

  defp revert_reason(status, transaction) do
    if is_binary(status) && status |> String.downcase() |> String.contains?("reverted") do
      case TransactionView.transaction_revert_reason(transaction, @api_true) do
        {:error, _contract_not_verified, candidates} when candidates != [] ->
          {:ok, method_id, text, mapping} = Enum.at(candidates, 0)
          render(__MODULE__, "decoded_input.json", method_id: method_id, text: text, mapping: mapping, error?: true)

        {:ok, method_id, text, mapping} ->
          render(__MODULE__, "decoded_input.json", method_id: method_id, text: text, mapping: mapping, error?: true)

        _ ->
          hex = TransactionView.get_pure_transaction_revert_reason(transaction)
          render(__MODULE__, "revert_reason.json", raw: hex)
      end
    end
  end

  @doc """
    Prepares decoded tx info
  """
  @spec decoded_input(any()) :: map() | nil
  def decoded_input(decoded_input) do
    case decoded_input do
      {:ok, method_id, text, mapping} ->
        render(__MODULE__, "decoded_input.json", method_id: method_id, text: text, mapping: mapping, error?: false)

      _ ->
        nil
    end
  end

  def prepare_method_mapping(mapping) do
    Enum.map(mapping, fn {name, type, value} ->
      %{"name" => name, "type" => type, "value" => ABIEncodedValueView.value_json(type, value)}
    end)
  end

  def prepare_log_mapping(mapping) do
    Enum.map(mapping, fn {name, type, indexed?, value} ->
      %{"name" => name, "type" => type, "indexed" => indexed?, "value" => ABIEncodedValueView.value_json(type, value)}
    end)
  end

  defp format_status({:error, reason}), do: reason
  defp format_status(status), do: status

  @spec format_decoded_input(any()) :: nil | map() | tuple()
  def format_decoded_input({:error, _, []}), do: nil
  def format_decoded_input({:error, _, candidates}), do: Enum.at(candidates, 0)
  def format_decoded_input({:ok, _identifier, _text, _mapping} = decoded), do: decoded
  def format_decoded_input(_), do: nil

  defp format_decoded_log_input({:error, :could_not_decode}), do: nil
  defp format_decoded_log_input({:ok, _method_id, _text, _mapping} = decoded), do: decoded
  defp format_decoded_log_input({:error, _, candidates}), do: Enum.at(candidates, 0)

  def format_confirmations({:ok, confirmations}), do: confirmations
  def format_confirmations(_), do: 0

  def format_fee({type, value}), do: %{"type" => type, "value" => value}

  def processing_time_duration(%Transaction{block: nil}) do
    []
  end

  def processing_time_duration(%Transaction{earliest_processing_start: nil}) do
    avg_time = AverageBlockTime.average_block_time()

    if avg_time == {:error, :disabled} do
      []
    else
      [
        0,
        avg_time
        |> Duration.to_milliseconds()
      ]
    end
  end

  def processing_time_duration(%Transaction{
        block: %Block{timestamp: end_time},
        earliest_processing_start: earliest_processing_start,
        inserted_at: inserted_at
      }) do
    long_interval = abs(diff(earliest_processing_start, end_time))
    short_interval = abs(diff(inserted_at, end_time))
    merge_intervals(short_interval, long_interval)
  end

  def merge_intervals(short, long) when short == long, do: [short]

  def merge_intervals(short, long) do
    [short, long]
  end

  def diff(left, right) do
    left
    |> Timex.diff(right, :milliseconds)
  end

  @doc """
    Return method name used in tx
  """
  @spec method_name(Transaction.t(), any(), boolean()) :: binary() | nil
  def method_name(_, _, skip_sc_check? \\ false)

  def method_name(_, {:ok, _method_id, text, _mapping}, _) do
    Transaction.parse_method_name(text, false)
  end

  def method_name(
        %Transaction{to_address: to_address, input: %{bytes: <<method_id::binary-size(4), _::binary>>}},
        _,
        skip_sc_check?
      ) do
    if skip_sc_check? || Address.smart_contract?(to_address) do
      "0x" <> Base.encode16(method_id, case: :lower)
    else
      nil
    end
  end

  def method_name(_, _, _) do
    nil
  end

  @doc """
    Returns array of token types for tx.
  """
  @spec tx_types(
          Explorer.Chain.Transaction.t(),
          [tx_type],
          tx_type
        ) :: [tx_type]
        when tx_type:
               :coin_transfer
               | :contract_call
               | :contract_creation
               | :rootstock_bridge
               | :rootstock_remasc
               | :token_creation
               | :token_transfer
               | :blob_transaction
  def tx_types(tx, types \\ [], stage \\ :blob_transaction)

  def tx_types(%Transaction{type: type} = tx, types, :blob_transaction) do
    # EIP-2718 blob transaction type
    types =
      if type == 3 do
        [:blob_transaction | types]
      else
        types
      end

    tx_types(tx, types, :token_transfer)
  end

  def tx_types(%Transaction{token_transfers: token_transfers} = tx, types, :token_transfer) do
    types =
      if (!is_nil(token_transfers) && token_transfers != [] && !match?(%NotLoaded{}, token_transfers)) ||
           tx.has_token_transfers do
        [:token_transfer | types]
      else
        types
      end

    tx_types(tx, types, :token_creation)
  end

  def tx_types(%Transaction{created_contract_address: created_contract_address} = tx, types, :token_creation) do
    types =
      if match?(%Address{}, created_contract_address) && match?(%Token{}, created_contract_address.token) do
        [:token_creation | types]
      else
        types
      end

    tx_types(tx, types, :contract_creation)
  end

  def tx_types(
        %Transaction{to_address_hash: to_address_hash} = tx,
        types,
        :contract_creation
      ) do
    types =
      if is_nil(to_address_hash) do
        [:contract_creation | types]
      else
        types
      end

    tx_types(tx, types, :contract_call)
  end

  def tx_types(%Transaction{to_address: to_address} = tx, types, :contract_call) do
    types =
      if Address.smart_contract?(to_address) do
        [:contract_call | types]
      else
        types
      end

    tx_types(tx, types, :coin_transfer)
  end

  def tx_types(%Transaction{value: value} = tx, types, :coin_transfer) do
    types =
      if Decimal.compare(value.value, 0) == :gt do
        [:coin_transfer | types]
      else
        types
      end

    tx_types(tx, types, :rootstock_remasc)
  end

  def tx_types(tx, types, :rootstock_remasc) do
    types =
      if Transaction.rootstock_remasc_transaction?(tx) do
        [:rootstock_remasc | types]
      else
        types
      end

    tx_types(tx, types, :rootstock_bridge)
  end

  def tx_types(tx, types, :rootstock_bridge) do
    if Transaction.rootstock_bridge_transaction?(tx) do
      [:rootstock_bridge | types]
    else
      types
    end
  end

  defp block_timestamp(%Transaction{block_timestamp: block_ts}) when not is_nil(block_ts), do: block_ts
  defp block_timestamp(%Transaction{block: %Block{} = block}), do: block.timestamp
  defp block_timestamp(%Block{} = block), do: block.timestamp
  defp block_timestamp(_), do: nil

  defp prepare_state_change(%StateChange{} = state_change) do
    coin_or_transfer =
      if state_change.coin_or_token_transfers == :coin,
        do: :coin,
        else: elem(List.first(state_change.coin_or_token_transfers), 1)

    type = if coin_or_transfer == :coin, do: "coin", else: "token"

    %{
      "address" =>
        Helper.address_with_info(nil, state_change.address, state_change.address && state_change.address.hash, false),
      "is_miner" => state_change.miner?,
      "type" => type,
      "token" => if(type == "token", do: TokenView.render("token.json", %{token: coin_or_transfer.token})),
      "token_id" => state_change.token_id
    }
    |> append_balances(state_change.balance_before, state_change.balance_after)
    |> append_balance_change(state_change, coin_or_transfer)
  end

  defp append_balances(map, balance_before, balance_after) do
    balances =
      if TransactionStateView.not_negative?(balance_before) and TransactionStateView.not_negative?(balance_after) do
        %{
          "balance_before" => balance_before,
          "balance_after" => balance_after
        }
      else
        %{
          "balance_before" => nil,
          "balance_after" => nil
        }
      end

    Map.merge(map, balances)
  end

  defp append_balance_change(map, state_change, coin_or_transfer) do
    change =
      if is_list(state_change.coin_or_token_transfers) and coin_or_transfer.token.type == "ERC-721" do
        for {direction, token_transfer} <- state_change.coin_or_token_transfers do
          %{"total" => prepare_token_transfer_total(token_transfer), "direction" => direction}
        end
      else
        state_change.balance_diff
      end

    Map.merge(map, %{"change" => change})
  end

  defp polygon_edge_deposit(transaction_hash, conn) do
    transaction_hash
    |> Reader.deposit_by_transaction_hash()
    |> polygon_edge_deposit_or_withdrawal(conn)
  end

  defp polygon_edge_withdrawal(transaction_hash, conn) do
    transaction_hash
    |> Reader.withdrawal_by_transaction_hash()
    |> polygon_edge_deposit_or_withdrawal(conn)
  end

  defp polygon_edge_deposit_or_withdrawal(item, conn) do
    if not is_nil(item) do
      {from_address, from_address_hash} = hash_to_address_and_hash(item.from)
      {to_address, to_address_hash} = hash_to_address_and_hash(item.to)

      item
      |> Map.put(:from, Helper.address_with_info(conn, from_address, from_address_hash, item.from))
      |> Map.put(:to, Helper.address_with_info(conn, to_address, to_address_hash, item.to))
    end
  end

  defp hash_to_address_and_hash(hash) do
    with false <- is_nil(hash),
         {:ok, address} <-
           Chain.hash_to_address(
             hash,
             [necessity_by_association: %{:names => :optional, :smart_contract => :optional}, api?: true],
             false
           ) do
      {address, address.hash}
    else
      _ -> {nil, nil}
    end
  end

  defp maybe_put_stability_fee(body, transaction) do
    with "stability" <- Application.get_env(:explorer, :chain_type),
         [
           {"token", "address", false, token_address_hash},
           {"totalFee", "uint256", false, total_fee},
           {"validator", "address", false, validator_address_hash},
           {"validatorFee", "uint256", false, validator_fee},
           {"dapp", "address", false, dapp_address_hash},
           {"dappFee", "uint256", false, dapp_fee}
         ] <- transaction.transaction_fee_log do
      stability_fee = %{
        "token" =>
          TokenView.render("token.json", %{
            token: transaction.transaction_fee_token,
            contract_address_hash: bytes_to_address_hash(token_address_hash)
          }),
        "validator_address" => Helper.address_with_info(nil, nil, bytes_to_address_hash(validator_address_hash), false),
        "dapp_address" => Helper.address_with_info(nil, nil, bytes_to_address_hash(dapp_address_hash), false),
        "total_fee" => to_string(total_fee),
        "dapp_fee" => to_string(dapp_fee),
        "validator_fee" => to_string(validator_fee)
      }

      body
      |> Map.put("stability_fee", stability_fee)
    else
      _ ->
        body
    end
  end
end

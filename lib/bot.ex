defmodule Slack.Bot do
  require Logger

  @behaviour :websocket_client_handler

  def start_link(bot_handler, initial_state, token, client \\ :websocket_client) do
    case Slack.Rtm.start(token) do
      {:ok, rtm} ->
        state = %{
          bot_handler: bot_handler,
          rtm: rtm,
          client: client,
          token: token,
          initial_state: initial_state
        }
        url = String.to_char_list(rtm.url)
        client.start_link(url, __MODULE__, state)
      {:error, %HTTPoison.Error{reason: :connect_timeout}} ->
        {:error, "Timed out while connecting to the Slack RTM API"}
      {:error, %HTTPoison.Error{reason: :nxdomain}} ->
        {:error, "Could not connect to the Slack RTM API"}
      {:error, %JSX.DecodeError{string: "You are sending too many requests. Please relax."}} ->
        {:error, "Sent too many connection requests at once to the Slack RTM API."}
      {:error, error} ->
        {:error, error}
    end
  end

  # websocket_client API

  def init(%{bot_handler: bot_handler, rtm: rtm, client: client, token: token, initial_state: initial_state}) do
    slack = %Slack.State{
      process: self(),
      client: client,
      token: token,
      me: rtm.self,
      team: rtm.team,
      bots: rtm_list_to_map(rtm.bots),
      channels: rtm_list_to_map(rtm.channels),
      groups: rtm_list_to_map(rtm.groups),
      users: rtm_list_to_map(rtm.users),
      ims: rtm_list_to_map(rtm.ims)
    }

    {:reconnect, %{slack: slack, bot_handler: bot_handler, process_state: initial_state}}
  end

  def onconnect(_websocket_request, %{slack: slack, process_state: process_state, bot_handler: bot_handler} = state) do
    {:ok, new_process_state} = bot_handler.handle_connect(slack, process_state)
    {:ok, %{state | process_state: new_process_state}}
  end

  def ondisconnect(reason, %{slack: slack, process_state: process_state, bot_handler: bot_handler} = state) do
    try do
      case bot_handler.handle_close(reason, slack, process_state) do
        :reconnect ->
          {:reconnect, state}
        _ ->
          {:close, reason, state}
      end
    rescue
      e -> handle_exception(e)
      {:reconnect}
    end
  end

  def websocket_info(message, _connection, %{slack: slack, process_state: process_state, bot_handler: bot_handler} = state) do
    new_process_state = if Map.has_key?(message, :type) do
      try do
        {:ok, new_process_state} = bot_handler.handle_info(message, slack, process_state)
        new_process_state
      rescue
        e -> handle_exception(e)
      end
    else
      process_state
    end

    {:ok, state}
  end

  def websocket_terminate(reason, _conn, _state), do: :ok

  def websocket_handle({:text, message}, _conn, %{slack: slack, process_state: process_state, bot_handler: bot_handler} = state) do
    message = prepare_message message

    updated_slack = if Map.has_key?(message, :type) do
      Slack.State.update(message, slack)
    else
      slack
    end

    new_process_state = if Map.has_key?(message, :type) do
      try do
        {:ok, new_process_state} = bot_handler.handle_message(message, slack, process_state)
        new_process_state
      rescue
        e -> handle_exception(e)
      end
    else
      process_state
    end

    {:ok, %{state | slack: updated_slack, process_state: new_process_state}}
  end
  def websocket_handle(_, _conn, state), do: {:ok, state}

  defp rtm_list_to_map(list) do
    Enum.reduce(list, %{}, fn (item, map) ->
      Map.put(map, item.id, item)
    end)
  end

  defp prepare_message(binstring) do
    binstring
      |> :binary.split(<<0>>)
      |> List.first
      |> JSX.decode!([{:labels, :atom}])
  end

  defp handle_exception(e) do
    message = Exception.message(e)
    Logger.error(message)
    System.stacktrace |> Exception.format_stacktrace |> Logger.error
    raise message
  end
end

defmodule Slack.MessageServer do
  @moduledoc false
  use GenServer

  require Logger

  # Slack has a rate-limit of 1 message per second per channel.
  @send_message_rate_ms :timer.seconds(1)
  # Slack has a rate-limit of ? message deletions per second per channel.
  @delete_message_rate_ms :timer.seconds(1)

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({bot, channel}) do
    Logger.info("[Slack.MessageServer] starting for #{bot.module} in #{channel}...")
    GenServer.start_link(__MODULE__, {bot, channel}, name: via_tuple(bot, channel))
  end

  def start_supervised(bot, channel) do
    DynamicSupervisor.start_child(
      Slack.DynamicSupervisor,
      {Slack.MessageServer, {bot, channel}}
    )
  end

  def send(bot, channel, message) when is_binary(channel) do
    GenServer.cast(via_tuple(bot, channel), {:add, message})
  end

  def dm(bot, channel, user, message) when is_binary(channel) do
    GenServer.cast(via_tuple(bot, channel), {:dm, user, message})
  end

  def delete(bot, channel, ts) when is_binary(channel) do
    GenServer.cast(via_tuple(bot, channel), {:remove, ts})
  end

  def stop(bot, channel) do
    GenServer.stop(via_tuple(bot, channel))
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init({bot, channel}) do
    state = %{
      bot: bot,
      channel: channel,
      send_queue: :queue.new(),
      delete_queue: :queue.new(),
      send_timer_ref: schedule_next_send(),
      dm_timer_ref: schedule_next_send(),
      delete_timer_ref: schedule_next_delete()
    }

    {:ok, state}
  end

  @impl true
  # If we are paused, we will add it to the send_queue and start scheduling messages.
  def handle_cast({:add, message}, %{send_timer_ref: nil} = state) do
    Logger.debug("[Slack.MessageServer] Adding message #{inspect(message)}")
    state = send_and_schedule_next(%{state | send_queue: :queue.in(message, state.send_queue)})
    {:noreply, state}
  end

  # It is not paused, so that means we are still scheduling messages, so we will
  # just add the message to send_queue.
  def handle_cast({:add, message}, state) do
    Logger.debug("[Slack.MessageServer] Adding message #{inspect(message)}")
    state = %{state | send_queue: :queue.in(message, state.send_queue)}
    {:noreply, state}
  end

  # If we are paused, we will add it to the send_queue and start scheduling messages.
  def handle_cast({:dm, user, message}, %{send_timer_ref: nil} = state) do
    Logger.debug("[Slack.MessageServer] Adding DM to user #{user} #{inspect(message)}")

    state =
      send_and_schedule_next(%{state | send_queue: :queue.in({user, message}, state.send_queue)})

    {:noreply, state}
  end

  # It is not paused, so that means we are still scheduling messages, so we will
  # just add the message to send_queue.
  def handle_cast({:dm, user, message}, state) do
    Logger.debug("[Slack.MessageServer] Adding DM to user #{user} #{inspect(message)}")
    state = %{state | send_queue: :queue.in({user, message}, state.send_queue)}
    {:noreply, state}
  end

  @impl true
  # If we are paused, we will add it to the delete_queue and start scheduling messages.
  def handle_cast({:remove, ts}, %{delete_timer_ref: nil} = state) do
    Logger.info("[Slack.MessageServer] Removing message with timestamp #{inspect(ts)}")
    state = delete_and_schedule_next(%{state | delete_queue: :queue.in(ts, state.delete_queue)})
    {:noreply, state}
  end

  # It is not paused, so that means we are still scheduling messages, so we will
  # just add the message to delete_queue.
  def handle_cast({:remove, ts}, state) do
    Logger.info("[Slack.MessageServer] Removing message with timestamp #{inspect(ts)}")
    state = %{state | delete_queue: :queue.in(ts, state.delete_queue)}
    {:noreply, state}
  end

  @impl true
  def handle_info(:send, state) do
    {:noreply, send_and_schedule_next(state)}
  end

  @impl true
  def handle_info(:delete, state) do
    {:noreply, delete_and_schedule_next(state)}
  end

  # ----------------------------------------------------------------------------
  # Private API
  # ----------------------------------------------------------------------------

  defp send_and_schedule_next(state) do
    case :queue.out(state.send_queue) do
      {:empty, _} ->
        Logger.debug("[Slack.MessageServer] [#{state.channel}] no more messages to send: PAUSED")
        %{state | send_timer_ref: nil}

      {{:value, {user, message}}, rest} ->
        Logger.debug("[Slack.MessageServer] Sending next DM to user #{user}: #{inspect(message)}")
        send_message(state.bot.token, user, message)
        %{state | send_queue: rest, send_timer_ref: schedule_next_send()}

      {{:value, message}, rest} ->
        Logger.debug("[Slack.MessageServer] Sending next message: #{inspect(message)}")
        send_message(state.bot.token, state.channel, message)
        %{state | send_queue: rest, send_timer_ref: schedule_next_send()}
    end
  end

  defp delete_and_schedule_next(state) do
    case :queue.out(state.delete_queue) do
      {:empty, _} ->
        Logger.debug(
          "[Slack.MessageServer] [#{state.channel}] no more messages to delete: PAUSED"
        )

        %{state | delete_timer_ref: nil}

      {{:value, ts}, rest} ->
        Logger.debug("[Slack.MessageServer] Removing next message with timestamp: #{inspect(ts)}")
        admin_user_token = Application.fetch_env!(:slack_elixir, :admin_user_token)
        delete_message(admin_user_token, state.channel, ts)
        %{state | delete_queue: rest, delete_timer_ref: schedule_next_delete()}
    end
  end

  # Users can send a message either as string, or as a keyword/map of args.
  # When they send it as a string, we'll put it into a map, with the `:text`
  # key. The args are assumed to be any arg that is accepted by Slack's
  # `chat.postMessage` API endpoint.
  defp send_message(token, channel, message) when is_binary(message) do
    send_message(token, %{channel: channel, text: message})
  end

  defp send_message(token, channel, message) do
    send_message(token, Enum.into(message, %{channel: channel}))
  end

  defp send_message(token, %{} = args) do
    case Slack.API.post("chat.postMessage", token, args) do
      {:ok, _} ->
        Logger.debug("[Slack.MessageServer] SENT: #{inspect(args)}")

      {:error, error} ->
        Logger.error("[Slack.MessageServer] error sending message #{inspect(error)}")
    end
  end

  defp delete_message(token, channel, ts) do
    args = %{channel: channel, ts: ts}

    case Slack.API.post("chat.delete", token, args) do
      {:ok, _} ->
        Logger.debug("[Slack.MessageServer] DELETED: #{inspect(args)}")

      {:error, error} ->
        Logger.error("[Slack.MessageServer] error deleting message #{inspect(error)}")
    end
  end

  defp schedule_next_send(after_ms \\ @send_message_rate_ms) do
    Process.send_after(self(), :send, after_ms)
  end

  defp schedule_next_delete(after_ms \\ @delete_message_rate_ms) do
    Process.send_after(self(), :delete, after_ms)
  end

  defp via_tuple(%Slack.Bot{module: bot}, channel) do
    via_tuple(bot, channel)
  end

  defp via_tuple(bot, channel) do
    {:via, Registry, {Slack.MessageServerRegistry, {bot, channel}}}
  end
end

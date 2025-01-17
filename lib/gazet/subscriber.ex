schema =
  Gazet.Options.schema!(
    module: [
      type: :atom,
      required: true,
      doc: "A module implementing the `Gazet.Subscriber` behaviour."
    ],
    otp_app: [type: :atom, required: false, doc: "Defaults to the source's `otp_app`"],
    id: [
      type: {:or, [:atom, :string]},
      required: false,
      doc: "Unique ID for this subscriber, defaults to the using module"
    ],
    source: [type: {:or, [:atom, {:struct, Gazet}]}, required: true],
    start_opts: [
      type: :keyword_list,
      default: [],
      doc: "A keyword list consumed by the `source`'s Adapter when starting this Subscriber. Refer to the Adapter's docs for details on which options are supported/expected."
    ],
    subscriber_opts: [
      type: :any,
      required: false,
      doc: "Use this to pass whatever - the default `init/1` implementation returns this as `t:context`."
    ]
  )

defmodule Gazet.Subscriber do
  # TODO: Write docs
  @moduledoc """
  Stateless subscriber.

  ## Configuration
  #{Gazet.Options.docs(schema)}
  """
  use Gazet.Blueprint,
    schema: schema

  @type t :: implementation | blueprint

  @typedoc "A module implementing this behaviour."
  @type implementation :: module

  @type opts :: [unquote(Gazet.Options.typespec(schema))]

  @typedoc "Used-defined data structure as returned by `init/2`. Passed as last argument to all other callbacks."
  @type context :: term

  @type result :: :ok | {:error, reason :: any}

  @callback config() :: blueprint | opts

  @callback init(blueprint :: blueprint) :: {:ok, context} | {:error, reason :: any}

  @callback handle_batch(
              topic :: Gazet.topic(),
              batch ::
                nonempty_list({
                  Gazet.Message.data(),
                  Gazet.Message.metadata()
                }),
              context :: context
            ) :: result

  @spec blueprint(t | opts) :: Gazet.Blueprint.result(__MODULE__)
  def blueprint(module_or_opts), do: Gazet.Blueprint.build(__MODULE__, module_or_opts)
  @spec blueprint!(t | opts) :: blueprint | no_return
  def blueprint!(module_or_opts), do: Gazet.Blueprint.build!(__MODULE__, module_or_opts)

  @spec child_spec(t | opts) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{source: source} = subscriber) do
    Gazet.subscriber_child_spec(source, subscriber)
  end

  def child_spec(module_or_opts) do
    module_or_opts
    |> blueprint!()
    |> child_spec()
  end

  @spec child_spec(implementation, opts) :: Supervisor.child_spec()
  def child_spec(module, overrides) when is_atom(module) do
    base_opts =
      case module.config() do
        %__MODULE__{} = blueprint ->
          blueprint
          |> Map.from_struct()
          |> Map.to_list()

        opts when is_list(opts) ->
          opts
      end

    base_opts
    |> Keyword.merge(Keyword.take(overrides, [:id, :otp_app, :source, :start_opts, :subscriber_opts]))
    |> child_spec()
  end

  @impl Gazet.Blueprint
  def __blueprint__(module) when is_atom(module) do
    if function_exported?(module, :config, 0) do
      case module.config() do
        %__MODULE__{} = blueprint ->
          {:ok, %__MODULE__{blueprint | module: module}}

        opts when is_list(opts) ->
          opts
          |> Keyword.put(:module, module)
          |> __blueprint__()
      end
    else
      {:error, {:no_config_function, module}}
    end
  end

  def __blueprint__(opts) when is_list(opts) do
    # Ensure that the given opts always include the required options
    with {:ok, blueprint} <- super(opts) do
      otp_app = blueprint.otp_app || Gazet.config!(blueprint.source, :otp_app)

      [
        {:gazet, Gazet.Subscriber},
        {otp_app, Gazet.Subscriber}
      ]
      |> Gazet.Env.resolve([:start_opts])
      |> Keyword.merge(opts)
      |> Keyword.put(:otp_app, otp_app)
      |> super()
    end
  end

  defmacro __using__(config) do
    quote bind_quoted: [config: config] do
      @behaviour Gazet.Subscriber

      def child_spec(overrides) do
        Gazet.Subscriber.child_spec(__MODULE__, overrides)
      end

      @config Keyword.put(config, :module, __MODULE__)
      @otp_app Gazet.Subscriber.blueprint!(@config).otp_app
      @impl Gazet.Subscriber
      def config, do: Gazet.Subscriber.blueprint!(@config)

      @impl Gazet.Subscriber
      def init(%Gazet.Subscriber{subscriber_opts: context}), do: {:ok, context}

      @impl Gazet.Subscriber
      def handle_batch(topic, batch, context) do
        # TODO: Refactor this to rely on a `Subscriber.Simple` behaviour
        Enum.reduce_while(batch, :ok, fn {message, metadata}, _ ->
          with {:error, reason} <- handle_message(topic, message, metadata, context),
               {:error, reason} <- handle_error(reason, topic, message, metadata, context) do
            {:halt, {:error, reason}}
          else
            :ok -> {:cont, :ok}
          end
        end)
      end

      def handle_error(reason, _topic, _message, _metadata, _config) do
        {:error, reason}
      end

      defoverridable child_spec: 1, config: 0, init: 2, handle_batch: 3, handle_error: 5
    end
  end
end

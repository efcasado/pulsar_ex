defmodule PulsarEx.Worker do
  def compile_config(module, opts) do
    {otp_app, opts} = Keyword.pop!(opts, :otp_app)
    opts = Application.get_env(otp_app, module, []) |> Keyword.merge(opts)
    {cluster, opts} = Keyword.pop(opts, :cluster, :default)
    {subscription, opts} = Keyword.pop!(opts, :subscription)
    {jobs, opts} = Keyword.pop!(opts, :jobs)
    {use_executor, opts} = Keyword.pop(opts, :use_executor, false)
    {exec_timeout, opts} = Keyword.pop(opts, :exec_timeout, 5_000)
    {inline, opts} = Keyword.pop(opts, :inline, false)
    {middlewares, opts} = Keyword.pop(opts, :middlewares, [])
    {producer_opts, opts} = Keyword.pop(opts, :producer_opts, [])

    {otp_app, cluster, subscription, jobs, use_executor, exec_timeout, inline, middlewares,
     producer_opts, opts}
  end

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      {otp_app, cluster, subscription, jobs, use_executor, exec_timeout, inline, middlewares,
       producer_opts, opts} = PulsarEx.Worker.compile_config(__MODULE__, opts)

      require Logger

      if Keyword.get(opts, :batch_enabled) do
        Logger.warn(
          "Workers should not be configured with batch_enabled, ignoring batch settings. #{inspect(opts)}"
        )
      end

      opts =
        opts
        |> Keyword.merge(batch_size: 1, initial_position: :earliest)
        |> Keyword.merge(batch_enabled: false)
        |> Keyword.put_new(:dead_letter_topic, :self)
        |> Keyword.put_new(:receiving_queue_size, 10)

      use PulsarEx.Consumer, opts
      @behaviour PulsarEx.WorkerCallback

      alias PulsarEx.{JobState, ConsumerMessage}

      @otp_app otp_app
      @cluster cluster
      @topic Keyword.get(opts, :topic)
      @subscription subscription
      @jobs jobs
      @use_executor use_executor
      @exec_timeout exec_timeout
      @inline inline
      @default_middlewares [PulsarEx.Middlewares.Telemetry, PulsarEx.Middlewares.Logging]
      @middlewares @default_middlewares ++ middlewares
      @producer_opts producer_opts
      @opts opts

      def cluster() do
        @cluster
      end

      def subscription() do
        @subscription
      end

      if @topic do
        def topic(), do: @topic
      else
        def topic(), do: raise("Topic is not defined for #{__MODULE__}")
      end

      def producer_opts(), do: @producer_opts

      defp job_handler() do
        handler = fn %JobState{job: job} = job_state ->
          %JobState{job_state | state: handle_job(job, job_state)}
        end

        @middlewares
        |> Enum.reverse()
        |> Enum.reduce(handler, fn middleware, acc ->
          middleware.call(acc)
        end)
      end

      @impl true
      def handle_messages([%ConsumerMessage{properties: properties} = message], state) do
        {job, properties} = Map.pop!(properties, "job")
        payload = Jason.decode!(message.payload)

        handler = fn ->
          job_handler().(%JobState{
            cluster: @cluster,
            worker: __MODULE__,
            topic: state.topic_name,
            subscription: @subscription,
            job: String.to_atom(job),
            payload: payload,
            properties: properties,
            publish_time: message.publish_time,
            event_time: message.event_time,
            producer_name: message.producer_name,
            partition_key: message.partition_key,
            ordering_key: message.ordering_key,
            deliver_at_time: message.deliver_at_time,
            redelivery_count: message.redelivery_count,
            consumer_opts: state.consumer_opts,
            assigns: %{},
            state: nil
          })
        end

        job_state =
          if @use_executor do
            :poolboy.transaction(
              PulsarEx.Executor.name(@cluster),
              &PulsarEx.Executor.exec(&1, handler, @exec_timeout)
            )
          else
            handler.()
          end

        [job_state.state]
      end

      @impl true
      def handle_job(_, _) do
        :ok
      end

      defoverridable handle_job: 2

      defp assert_topic(nil), do: raise("topic undefined")
      defp assert_topic(topic), do: topic

      @impl true
      def topic(_, _, _), do: assert_topic(@topic)

      defoverridable topic: 3

      @impl true
      def partition_key(_, _, message_opts), do: Keyword.get(message_opts, :partition_key)

      defoverridable partition_key: 3

      def enqueue_job(job, params, message_opts \\ [])

      def enqueue_job(job, params, message_opts) do
        {topic, message_opts} =
          Keyword.pop_lazy(message_opts, :topic, fn -> topic(job, params, message_opts) end)

        enqueue_job(job, params, topic, message_opts)
      end

      def enqueue_job(job, params, topic, message_opts) when job in @jobs do
        if @inline do
          inline_process(job, params, topic, message_opts)
        else
          start = System.monotonic_time()

          properties =
            Keyword.get(message_opts, :properties, [])
            |> Enum.into(%{})
            |> Map.put("job", job)

          reply =
            PulsarEx.Clusters.produce(
              @cluster,
              topic,
              Jason.encode!(params),
              Keyword.merge(message_opts,
                properties: properties,
                partition_key: partition_key(job, params, message_opts)
              ),
              @producer_opts
            )

          case reply do
            {:ok, _} ->
              :telemetry.execute(
                [:pulsar_ex, :worker, :enqueue, :success],
                %{count: 1, duration: System.monotonic_time() - start},
                %{cluster: @cluster, topic: topic, job: job}
              )

            {:error, _} ->
              :telemetry.execute(
                [:pulsar_ex, :worker, :enqueue, :error],
                %{count: 1},
                %{cluster: @cluster, topic: topic, job: job}
              )
          end

          reply
        end
      end

      def inline_process(job, params, topic, message_opts) do
        params = Jason.decode!(Jason.encode!(params))

        properties =
          message_opts
          |> Keyword.get(:properties, [])
          |> Enum.map(fn {k, v} -> {"#{k}", "#{v}"} end)
          |> Enum.into(%{})

        job_state =
          job_handler().(%JobState{
            cluster: @cluster,
            worker: __MODULE__,
            topic: topic,
            subscription: @subscription,
            job: job,
            payload: params,
            properties: properties,
            publish_time: Timex.now(),
            event_time: nil,
            producer_name: "inline",
            partition_key: partition_key(job, params, message_opts),
            ordering_key: nil,
            deliver_at_time: nil,
            redelivery_count: 0,
            consumer_opts: nil,
            assigns: %{},
            state: nil
          })

        case job_state.state do
          :ok -> {:ok, nil}
          _ -> job_state.state
        end
      end

      def start(opts \\ []) do
        workers = Keyword.get(opts, :workers)

        opts =
          if workers do
            Keyword.merge(@opts, opts) |> Keyword.put(:num_consumers, workers)
          else
            Keyword.merge(@opts, opts)
          end

        {topic, opts} = Keyword.pop(opts, :topic)
        {regex, opts} = Keyword.pop(opts, :regex)

        case {topic, regex} do
          {nil, nil} ->
            raise "topic undefined"

          {nil, _} ->
            {tenant, opts} = Keyword.pop!(opts, :tenant)
            {namespace, opts} = Keyword.pop!(opts, :namespace)

            PulsarEx.Clusters.start_consumer(
              @cluster,
              tenant,
              namespace,
              regex,
              @subscription,
              __MODULE__,
              opts
            )

          {_, nil} ->
            PulsarEx.Clusters.start_consumer(@cluster, topic, @subscription, __MODULE__, opts)
        end
      end

      def stop(opts \\ []) do
        opts = Keyword.merge(@opts, opts)

        {topic, opts} = Keyword.pop(opts, :topic)
        {regex, opts} = Keyword.pop(opts, :regex)

        case {topic, regex} do
          {nil, nil} ->
            raise "topic undefined"

          {nil, _} ->
            {tenant, opts} = Keyword.pop!(opts, :tenant)
            {namespace, opts} = Keyword.pop!(opts, :namespace)

            PulsarEx.Clusters.stop_consumer(@cluster, tenant, namespace, regex, @subscription)

          {_, nil} ->
            PulsarEx.Clusters.stop_consumer(@cluster, topic, @subscription)
        end
      end
    end
  end
end

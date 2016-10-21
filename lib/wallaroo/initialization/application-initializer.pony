use "collections"
use "net"
use "sendence/guid"
use "sendence/messages"
use "wallaroo/messages"
use "wallaroo/metrics"
use "wallaroo/topology"

actor ApplicationInitializer
  let _guid_gen: GuidGenerator = GuidGenerator
  let _local_topology_initializer: LocalTopologyInitializer
  let _input_addrs: Array[Array[String]] val
  let _output_addr: Array[String] val

  var _application_starter: (ApplicationStarter val | None) = None
  var _application: (Application val | None) = None

  new create(local_topology_initializer: LocalTopologyInitializer,
    input_addrs: Array[Array[String]] val, 
    output_addr: Array[String] val) 
  =>
    _local_topology_initializer = local_topology_initializer
    _input_addrs = input_addrs
    _output_addr = output_addr

  be update_application(a: (ApplicationStarter val | Application val)) =>
    match a
    | let s: ApplicationStarter val =>
      _application_starter = s
    | let app: Application val =>
      _application = app
    end

  be initialize(worker_initializer: WorkerInitializer, worker_count: USize, 
    worker_names: Array[String] val)
  =>
    @printf[I32]("Initializing application\n".cstring())
    match _application
    | let a: Application val =>
      @printf[I32]("Automating...\n".cstring())
      _automate_initialization(a, worker_initializer, worker_count, 
        worker_names)
    else
      match _application_starter
      | let a: ApplicationStarter val =>
        @printf[I32]("Using user-defined ApplicationStarter...\n".cstring())
        try
          a(worker_initializer, worker_names, _input_addrs, worker_count)
        else
          @printf[I32]("Error running ApplicationStarter.\n".cstring())
        end
      else
        @printf[I32]("No application or application starter!\n".cstring())
      end
    end

  fun ref _automate_initialization(application: Application val,
    worker_initializer: WorkerInitializer, worker_count: USize,
    worker_names: Array[String] val) 
  =>
    @printf[I32]("---------------------------------------------------------\n".cstring())
    @printf[I32]("^^^^^^Initializing Topologies for Workers^^^^^^^\n\n".cstring())
    try
      // Keep track of shared state so that it's only created once 
      let state_partition_map: Map[String, PartitionAddresses val] trn = 
        recover Map[String, PartitionAddresses val] end

      // The worker-specific summaries
      var worker_topology_data = Array[WorkerTopologyData val]

      var pipeline_id: USize = 0

      // Map from step_id to worker name
      let steps: Map[U128, String] = steps.create()
      // Map from worker name to array of local pipelines
      let local_pipelines: Map[String, Array[LocalPipeline val]] =
        local_pipelines.create()

      // Initialize values for local pipelines
      local_pipelines("initializer") = Array[LocalPipeline val]
      for name in worker_names.values() do
        local_pipelines(name) = Array[LocalPipeline val]
      end

      @printf[I32](("Found " + application.pipelines.size().string()  + " pipelines in application\n").cstring())


      // The first set of runners goes on the Source for this pipeline if
      // they're not partitioned, so we don't create a StepInitializer until // that's been handled
      var source_runner_builders: Array[RunnerBuilder val] trn = 
        recover Array[RunnerBuilder val] end

      // Break each pipeline into LocalPipelines to distribute to workers
      for pipeline in application.pipelines.values() do
        // Have we handled the initial source runners?
        var handled_first_runners = false

        let source_addr_trn: Array[String] trn = recover Array[String] end
        try
          source_addr_trn.push(_input_addrs(pipeline_id)(0))
          source_addr_trn.push(_input_addrs(pipeline_id)(1))
        else
          @printf[I32]("No input address!\n".cstring())
          error
        end
        let source_addr: Array[String] val = consume source_addr_trn

        let sink_addr: Array[String] trn = recover Array[String] end
        try
          sink_addr.push(_output_addr(0))
          sink_addr.push(_output_addr(1))
        else
          @printf[I32]("No output address!\n".cstring())
          error
        end

        // Determine which steps go on which workers using boundary indices
        // Each worker gets a near-equal share of the total computations
        // in this naive algorithm
        let per_worker: USize = 
          if pipeline.size() <= worker_count then
            1
          else
            pipeline.size() / worker_count
          end

        let boundaries: Array[USize] = boundaries.create()
        var count: USize = 0
        for i in Range(0, worker_count) do
          count = count + per_worker
          if (i == (worker_count - 1)) and (count < pipeline.size()) then
            // Make sure we cover all steps by forcing the rest on the
            // last worker if need be
            boundaries.push(pipeline.size())
          else
            boundaries.push(count)
          end
        end

        @printf[I32](("The " + pipeline.name() + " pipeline has " + pipeline.size().string() + " runner builders\n").cstring())

        // Keep track of which runner_builder we're on in this pipeline
        var pipeline_idx: USize = 0
        // Keep track of which worker's boundary we're using
        var boundaries_idx: USize = 0

        // For each worker, use its boundary value to determine which
        // runner_builders to use to create StepInitializers that will be
        // added to its LocalTopology
        while boundaries_idx < boundaries.size() do
          let boundary = boundaries(boundaries_idx)

          let worker = 
            if boundaries_idx == 0 then
              "initializer"
            else
              try
                worker_names(boundaries_idx - 1)
              else
                @printf[I32]("No worker found for idx!\n".cstring())
                error
              end              
            end
          // Keep track of which worker follows this one in order
          let next_worker: (String | None) = 
            try
              worker_names(boundaries_idx)
            else
              None
            end

          // We'll use this to create the LocalTopology for this worker
          let step_initializers: Array[StepInitializer val] trn = 
            recover Array[StepInitializer val] end

          // Make sure there are still runner_builders left in the pipeline.
          if pipeline_idx < pipeline.size() then
            // Running array of recent runner_builders to be coalesced
            // into a single StepInitializer
            var runner_builders: Array[RunnerBuilder val] trn = 
              recover Array[RunnerBuilder val] end

            var cur_step_id = _guid_gen.u128()

            // Until we hit the boundary for this worker, keep adding
            // runner builders from the pipeline
            while pipeline_idx < boundary do
              var next_runner_builder: RunnerBuilder val = pipeline(pipeline_idx)

              // If this is the last runner builder for this worker,
              // then add it to the last StepInitializer along with
              // anything we need to coalesce from runner_builders
              if (pipeline_idx == (boundary - 1)) and 
                (not next_runner_builder.is_stateful()) then
                try
                  if handled_first_runners then
                    runner_builders.push(pipeline(pipeline_idx))
                  
                    let seq_builder = RunnerSequenceBuilder(
                      runner_builders = recover Array[RunnerBuilder val] end)

                    @printf[I32](("Preparing to spin up " + 
                      seq_builder.name() + " on " + worker + "\n").cstring())

                    let step_builder = StepBuilder(seq_builder, 
                      cur_step_id)
                    step_initializers.push(step_builder)
                    steps(cur_step_id) = worker

                    cur_step_id = _guid_gen.u128()
                  else
                    source_runner_builders.push(pipeline(pipeline_idx))
                  end
                else
                  @printf[I32]("No runner builder found!\n".cstring())
                  error
                end  

              // If this runner builder was given a unique id via the API,
              // then it needs to be on its own Step since it can be used
              // by multiple pipelines
              elseif (next_runner_builder.id() != 0) then
                if runner_builders.size() > 0 then
                  let seq_builder = RunnerSequenceBuilder(
                    runner_builders = recover Array[RunnerBuilder val] end)
                  let step_builder = StepBuilder(seq_builder, 
                    cur_step_id)
                  step_initializers.push(step_builder)
                  steps(cur_step_id) = worker
                end

                let next_seq_builder = RunnerSequenceBuilder(
                  recover [pipeline(pipeline_idx)] end)

                @printf[I32](("Preparing to spin up " + next_seq_builder.name() + " on " + worker + "\n").cstring())

                let next_step_builder = StepBuilder(next_seq_builder, 
                  next_runner_builder.id(), next_runner_builder.is_stateful())
                step_initializers.push(next_step_builder)
                steps(next_runner_builder.id()) = worker

                handled_first_runners = true
                cur_step_id = _guid_gen.u128()   

              // Stateful steps have to be handled differently since pre state 
              // steps must be on the same workers as their corresponding 
              // state steps           
              elseif next_runner_builder.is_stateful() then
                if runner_builders.size() > 0 then
                  if handled_first_runners then
                    let seq_builder = RunnerSequenceBuilder(
                      runner_builders = recover Array[RunnerBuilder val] end)
                    
                    @printf[I32](("Preparing to spin up " + seq_builder.name() + " on " + worker + "\n").cstring())

                    let step_builder = StepBuilder(seq_builder, 
                      cur_step_id)
                    step_initializers.push(step_builder)
                    steps(cur_step_id) = worker
                  else
                    source_runner_builders.push(pipeline(pipeline_idx))
                  end
                end

                let next_seq_builder = RunnerSequenceBuilder(
                  recover [pipeline(pipeline_idx)] end)

                // If this is partitioned state and we haven't handled this 
                // shared state before, handle it.  Otherwise, just handle the 
                // prestate.          
                var state_name = ""
                match next_runner_builder
                | let pb: PartitionBuilder val =>
                  state_name = pb.state_name()
                  if not state_partition_map.contains(state_name) then
                    state_partition_map(state_name) = pb.partition_addresses(worker)
                  end
                end

                // Create the prestate initializer, and if this is not 
                // partitioned state, then the state initializer as well
                let next_initializer: StepInitializer val = 
                  match next_runner_builder
                  | let pb: PartitionBuilder val =>
                    @printf[I32](("Preparing to spin up partitioned state on " + worker + "\n").cstring())                                      
                    PartitionedPreStateStepBuilder(
                      pb.pre_state_subpartition(worker), next_runner_builder, 
                      state_name)
                  else
                    @printf[I32](("Preparing to spin up non-partitioned state computation for " + next_runner_builder.name() + " on " + worker + "\n").cstring())                                          
                    step_initializers.push(StepBuilder(next_seq_builder, 
                      next_runner_builder.id(),
                      next_runner_builder.is_stateful()))
                    steps(next_runner_builder.id()) = worker

                    pipeline_idx = pipeline_idx + 1

                    next_runner_builder = pipeline(pipeline_idx)
                    runner_builders.push(next_runner_builder)

                    @printf[I32](("Preparing to spin up non-partitioned state for " + next_runner_builder.name() + " on " + worker + "\n").cstring())

                    let seq_builder = RunnerSequenceBuilder(
                      runner_builders = recover Array[RunnerBuilder val] end)
                    StepBuilder(seq_builder, next_runner_builder.id(), 
                      next_runner_builder.is_stateful())
                  end

                step_initializers.push(next_initializer)
                steps(next_runner_builder.id()) = worker

                handled_first_runners = true
                cur_step_id = _guid_gen.u128()

              // If coalescing is off, then each runner_builder gets assigned
              // to its own StepBuilder
              elseif not pipeline.is_coalesced() then
                if handled_first_runners then
                  let seq_builder = RunnerSequenceBuilder(
                    runner_builders = recover Array[RunnerBuilder val] end)

                  @printf[I32](("Preparing to spin up " + seq_builder.name() + "\n").cstring())

                  let step_builder = StepBuilder(seq_builder, 
                    cur_step_id)
                  step_initializers.push(step_builder)
                  steps(cur_step_id) = worker
                else
                  source_runner_builders.push(pipeline(pipeline_idx))
                end

                handled_first_runners = true
                cur_step_id = _guid_gen.u128()                
              else
                try
                  if handled_first_runners then
                    runner_builders.push(pipeline(pipeline_idx))
                  else
                    source_runner_builders.push(pipeline(pipeline_idx))
                  end

                  handled_first_runners = true
                else
                  @printf[I32]("No runner builder found!\n".cstring())
                  error
                end             
              end

              pipeline_idx = pipeline_idx + 1 
            end
          end

          // Having prepared all the step initializers for this worker,
          // summarize this data in a WorkerTopologyData object
          try
            // This id is for the Step that will receive data via a 
            // Proxy
            let boundary_step_id = step_initializers(0).id() 

            let topology_data = WorkerTopologyData(worker, boundary_step_id,
              consume step_initializers)
            worker_topology_data.push(topology_data)
          end

          boundaries_idx = boundaries_idx + 1
        end

        // Set up the EgressBuilders and LocalPipelines for reach worker
        // for our current pipeline
        for i in Range(0, worker_topology_data.size()) do
          let cur = 
            try
              worker_topology_data(i)
            else
              @printf[I32]("No worker topology data found!\n".cstring())
              error
            end 
          let next_worker_data: (WorkerTopologyData val | None) =
            try worker_topology_data(i + 1) else None end

          let source_seq_builder = RunnerSequenceBuilder(
            source_runner_builders = recover Array[RunnerBuilder val] end)

          let source_data = 
            if i == 0 then
              SourceData(pipeline.source_builder(),
                source_seq_builder, source_addr)
            else
              None
            end

          // If this worker has no steps (is_empty), then create a
          // placeholder sink
          if cur.is_empty then
            let egress_builder = EgressBuilder(_output_addr, pipeline_id
              pipeline.sink_builder())
            let local_pipeline = LocalPipeline(pipeline.name(), 
              cur.step_initializers, egress_builder, source_data,
              pipeline.state_builders())
            try
              local_pipelines(cur.worker_name).push(local_pipeline)
            else
              @printf[I32]("No pipeline list found!\n".cstring())
              error
            end 
          // If this worker has steps, then we need either a Proxy or a sink
          else
            match next_worker_data
            | let next_w: WorkerTopologyData val =>
              // If the next worker in order has no steps, then we need a 
              // sink on this worker
              if next_w.is_empty then
                let egress_builder = EgressBuilder(_output_addr, pipeline_id
                  pipeline.sink_builder())
                let local_pipeline = LocalPipeline(pipeline.name(), 
                  cur.step_initializers, egress_builder, source_data,
                  pipeline.state_builders())
                try
                  local_pipelines(cur.worker_name).push(local_pipeline)
                else
                  @printf[I32]("No pipeline list found!\n".cstring())
                  error
                end              
              // If the next worker has steps (continues the pipeline), then
              // we need a Proxy to it on this worker
              else
                let proxy_address = ProxyAddress(next_w.worker_name, 
                  next_w.boundary_step_id)
                let egress_builder = EgressBuilder(proxy_address)
                let local_pipeline = LocalPipeline(pipeline.name(), 
                  cur.step_initializers, egress_builder, source_data,
                  pipeline.state_builders())
                try
                  local_pipelines(cur.worker_name).push(local_pipeline)
                else
                  @printf[I32]("No pipeline list found!\n".cstring())
                  error
                end 
              end
            // If the match fails, then this is the last worker in order and
            // we need a sink on it
            else
              let egress_builder = EgressBuilder(_output_addr, pipeline_id
                pipeline.sink_builder())
              let local_pipeline = LocalPipeline(pipeline.name(), 
                cur.step_initializers, egress_builder, source_data,
                pipeline.state_builders())
              try
                local_pipelines(cur.worker_name).push(local_pipeline)
              else
                @printf[I32]("No pipeline list found!\n".cstring())
                error
              end            
            end 
          end
        end

        // Reset the WorkerTopologyData array for the next pipeline since
        // we've used it for this one already
        worker_topology_data = Array[WorkerTopologyData val]

        // Prepare to initialize the next pipeline
        pipeline_id = pipeline_id + 1
      end

      // Keep track of LocalTopologies that we need to send to other 
      // (non-initializer) workers
      let other_local_topologies: Array[LocalTopology val] trn =
        recover Array[LocalTopology val] end

      // For each worker, generate a LocalTopology
      // from all of its LocalPipelines
      for (w, ps) in local_pipelines.pairs() do
        let pvals: Array[LocalPipeline val] trn = 
          recover Array[LocalPipeline val] end
        for p in ps.values() do
          pvals.push(p)
        end
        let local_topology = LocalTopology(application.name(), consume pvals)

        // If this is the initializer's (i.e. our) turn, then 
        // immediately (asynchronously) begin initializing it. If not, add it
        // to the list we'll use to distribute to the other workers
        if w == "initializer" then
          _local_topology_initializer.update_topology(local_topology)
          _local_topology_initializer.initialize() 
        else
          other_local_topologies.push(local_topology)
        end
      end

      // Distribute the LocalTopologies to the other (non-initializer) workers
      match worker_initializer
      | let wi: WorkerInitializer =>
        wi.distribute_local_topologies(consume other_local_topologies)
      else
        @printf[I32]("Error distributing local topologies!\n".cstring())
      end

      @printf[I32]("\n^^^^^^Finished Initializing Topologies for Workers^^^^^^^\n".cstring())
      @printf[I32]("---------------------------------------------------------\n".cstring())
    else
      @printf[I32]("Error initializating application!\n".cstring())
    end

class WorkerTopologyData
  let worker_name: String
  let boundary_step_id: U128
  let step_initializers: Array[StepInitializer val] val
  let is_empty: Bool

  new val create(n: String, id: U128, si: Array[StepInitializer val] val) =>
    worker_name = n
    boundary_step_id = id
    step_initializers = si
    is_empty = (step_initializers.size() == 0)

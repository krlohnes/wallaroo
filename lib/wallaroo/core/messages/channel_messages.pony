/*

Copyright 2017 The Wallaroo Authors.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 implied. See the License for the specific language governing
 permissions and limitations under the License.

*/

use "buffered"
use "serialise"
use "net"
use "collections"
use "time"
use "wallaroo/core/barrier"
use "wallaroo/core/boundary"
use "wallaroo/core/checkpoint"
use "wallaroo/core/common"
use "wallaroo/core/data_receiver"
use "wallaroo/core/initialization"
use "wallaroo/core/recovery"
use "wallaroo/core/registries"
use "wallaroo/core/routing"
use "wallaroo/core/source/connector_source"
use "wallaroo/core/step"
use "wallaroo/core/topology"
use "wallaroo_labs/mort"


primitive ChannelMsgEncoder
  fun _encode(msg: ChannelMsg, auth: AmbientAuth,
    wb: Writer = Writer): Array[ByteSeq] val ?
  =>
    let serialised: Array[U8] val =
      Serialised(SerialiseAuth(auth), msg)?.output(OutputSerialisedAuth(auth))
    let size = serialised.size()
    if size > 0 then
      wb.u32_be(size.u32())
      wb.write(serialised)
    end
    wb.done()

  fun data_channel(delivery_msg: DeliveryMsg,
    producer_id: RoutingId, pipeline_time_spent: U64, seq_id: SeqId,
    wb: Writer, auth: AmbientAuth, latest_ts: U64, metrics_id: U16,
    metric_name: String, connection_round: ConnectionRound):
    Array[ByteSeq] val ?
  =>
    _encode(DataMsg(delivery_msg, producer_id, pipeline_time_spent, seq_id,
      latest_ts, metrics_id, metric_name, connection_round), auth, wb)?

  fun migrate_key(step_group: RoutingId, key: Key, checkpoint_id: CheckpointId,
    state: ByteSeq val, worker: WorkerName, connection_round: ConnectionRound,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(KeyMigrationMsg(step_group, key, checkpoint_id, state,
      worker, connection_round), auth)?

  fun migration_batch_complete(sender: WorkerName,
    connection_round: ConnectionRound, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Sent to signal to joining worker that a batch of steps has finished
    emigrating from this step.
    """
    _encode(MigrationBatchCompleteMsg(sender, connection_round), auth)?

  fun worker_completed_migration_batch(worker: WorkerName,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Sent to ack that a batch of steps has finished immigrating to this step
    """
    _encode(WorkerCompletedMigrationBatch(worker), auth)?

  fun key_migration_complete(key: Key,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Sent when the migration of key is complete
    """
    _encode(KeyMigrationCompleteMsg(key), auth)?

  fun begin_leaving_migration(remaining_workers: Array[String] val,
    leaving_workers: Array[String] val, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    This message is sent by the current worker coordinating autoscale shrink to
    all leaving workers once all in-flight messages have finished processing
    after stopping the world. At that point, it's safe for leaving workers to
    migrate steps to the remaining workers.
    """
    _encode(BeginLeavingMigrationMsg(remaining_workers, leaving_workers),
      auth)?

  fun initiate_shrink(remaining_workers: Array[String] val,
    leaving_workers: Array[String] val, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(InitiateShrinkMsg(remaining_workers, leaving_workers), auth)?

  fun prepare_shrink(remaining_workers: Array[String] val,
    leaving_workers: Array[String] val, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    The worker initially contacted for autoscale shrink sends this message to
    all other remaining workers so they can prepare for the shrink event.
    """
    _encode(PrepareShrinkMsg(remaining_workers, leaving_workers), auth)?

  fun leaving_migration_ack_request(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    When a leaving worker migrates all its steps, it requests acks from all
    remaining workers.
    """
    _encode(LeavingMigrationAckRequestMsg(sender), auth)?

  fun leaving_migration_ack(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    A remaining worker sends this to ack that a leaving workers has finished
    migrating.
    """
    _encode(LeavingMigrationAckMsg(sender), auth)?

  fun mute_request(originating_worker: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(MuteRequestMsg(originating_worker), auth)?

  fun unmute_request(originating_worker: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(UnmuteRequestMsg(originating_worker), auth)?

  fun identify_control_port(worker_name: WorkerName, service: String,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(IdentifyControlPortMsg(worker_name, service), auth)?

  fun identify_data_port(worker_name: WorkerName, service: String,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(IdentifyDataPortMsg(worker_name, service), auth)?

  fun reconnect_data_port(worker_name: WorkerName, service: String,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ReconnectDataPortMsg(worker_name, service), auth)?

  fun spin_up_local_topology(local_topology: LocalTopology,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(SpinUpLocalTopologyMsg(local_topology), auth)?

  fun spin_up_step(step_id: U64, step_builder: StepBuilder,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(SpinUpStepMsg(step_id, step_builder), auth)?

  fun topology_ready(worker_name: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(TopologyReadyMsg(worker_name), auth)?

  fun create_connections(
    c_addrs: Map[String, (String, String)] val,
    d_addrs: Map[String, (String, String)] val,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(CreateConnectionsMsg(c_addrs, d_addrs), auth)?

  fun connections_ready(worker_name: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(ConnectionsReadyMsg(worker_name), auth)?

  fun report_worker_ready_to_work(worker_name: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(ReportWorkerReadyToWorkMsg(worker_name), auth)?

  fun all_workers_ready_to_work(auth: AmbientAuth): Array[ByteSeq] val ? =>
    _encode(AllWorkersReadyToWorkMsg, auth)?

  fun create_data_channel_listener(workers: Array[String] val,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(CreateDataChannelListener(workers), auth)?

  fun data_connect(sender_name: String, sender_step_id: RoutingId,
    highest_seq_id: SeqId, connection_round: ConnectionRound,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(DataConnectMsg(sender_name, sender_step_id, highest_seq_id,
      connection_round), auth)?

  fun data_disconnect(auth: AmbientAuth): Array[ByteSeq] val ? =>
    _encode(DataDisconnectMsg, auth)?

  fun start_normal_data_sending(last_id_seen: SeqId,
    connection_round: ConnectionRound, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(StartNormalDataSendingMsg(last_id_seen, connection_round), auth)?

  fun ack_data_received(sender_name: String, sender_step_id: RoutingId,
    seq_id: SeqId, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(AckDataReceivedMsg(sender_name, sender_step_id, seq_id), auth)?

  fun request_boundary_punctuation_ack(auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    A punctuation ack is used to guarantee that all pending messages after
    a certain received message at DataReceiver were sent by the boundary before
    we proceed.
    """
    _encode(RequestBoundaryPunctuationAckMsg, auth)?

  fun receive_boundary_punctuation_ack(connection_round: ConnectionRound,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ReceiveBoundaryPunctuationAckMsg(connection_round), auth)?

  fun data_receiver_ack_immediately(connection_round: ConnectionRound,
    boundary_routing_id: RoutingId, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(DataReceiverAckImmediatelyMsg(connection_round,
      boundary_routing_id), auth)?

  fun immediate_ack(auth: AmbientAuth): Array[ByteSeq] val ? =>
    _encode(ImmediateAckMsg, auth)?

  fun request_recovery_info(worker_name: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    This message is sent to the cluster when beginning recovery.
    """
    _encode(RequestRecoveryInfoMsg(worker_name), auth)?

  fun inform_recovering_worker(worker_name: WorkerName,
    checkpoint_id: CheckpointId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    This message is sent as a response to a RequestRecoveryInfo message.
    """
    _encode(InformRecoveringWorkerMsg(worker_name, checkpoint_id), auth)?

  fun join_cluster(worker_name: WorkerName, worker_count: USize,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    This message is sent from a worker requesting to join a running cluster to
    any existing worker in the cluster.
    """
    _encode(JoinClusterMsg(worker_name, worker_count), auth)?

  // TODO: Update this once new workers become first class citizens
  fun inform_joining_worker(worker_name: WorkerName, metric_app_name: String,
    l_topology: LocalTopology, checkpoint_id: CheckpointId,
    rollback_id: RollbackId, metric_host: String, metric_service: String,
    control_addrs: Map[String, (String, String)] val,
    data_addrs: Map[String, (String, String)] val,
    worker_names: Array[String] val, primary_checkpoint_worker: WorkerName,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    This message is sent as a response to a JoinCluster message.
    """
    _encode(InformJoiningWorkerMsg(worker_name, metric_app_name, l_topology,
      checkpoint_id, rollback_id, metric_host, metric_service, control_addrs,
      data_addrs, worker_names, primary_checkpoint_worker), auth)?

  fun inform_join_error(msg: String, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    This message is sent as a response to a JoinCluster message when there is
    a join error and the joiner should shut down.
    """
    _encode(InformJoinErrorMsg(msg), auth)?

  fun joining_worker_initialized(worker_name: WorkerName,
    c_addr: (String, String), d_addr: (String, String),
    step_group_routing_ids: Map[RoutingId, RoutingId] val,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    This message is sent after a joining worker initializes its topology. It
    indicates that it is ready to receive migrated steps.
    """
    _encode(JoiningWorkerInitializedMsg(worker_name, c_addr, d_addr,
      step_group_routing_ids), auth)?

  fun initiate_stop_the_world_for_grow_migration(sender: WorkerName,
    new_workers: Array[String] val, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(InitiateStopTheWorldForGrowMigrationMsg(sender, new_workers),
      auth)?

  fun initiate_grow_migration(new_workers: Array[WorkerName] val,
    checkpoint_id: CheckpointId, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    One worker is contacted by all joining workers and initially coordinates
    state migration to those workers. When it is ready to migrate steps, it
    sends this message to every other current worker informing them to begin
    migration as well. We include the next checkpoint id so that local key
    changes can be logged correctly.
    """
    _encode(InitiateGrowMigrationMsg(new_workers, checkpoint_id), auth)?

  fun pre_register_joining_workers(new_workers: Array[WorkerName] val,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Joining workers need to know the names of the other joining workers
    in order to correctly keep track of when to advance autoscale
    phases. This message tells a joining worker of the other joining
    workers names, but no other information about them.
    """
    _encode(PreRegisterJoiningWorkersMsg(new_workers), auth)?

  fun autoscale_complete(auth: AmbientAuth): Array[ByteSeq] val ? =>
    """
    The autoscale coordinator sends this message to indicate that autoscale is
    complete.
    """
    _encode(AutoscaleCompleteMsg, auth)?

  fun initiate_stop_the_world_for_shrink_migration(sender: WorkerName,
    remaining_workers: Array[String] val,
    leaving_workers: Array[String] val, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(InitiateStopTheWorldForShrinkMigrationMsg(sender,
      remaining_workers, leaving_workers), auth)?

  fun leaving_worker_done_migrating(worker_name: WorkerName,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    A leaving worker sends this to indicate it has migrated all steps back to
    remaining workers.
    """
    _encode(LeavingWorkerDoneMigratingMsg(worker_name), auth)?

  fun request_boundary_count(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(RequestBoundaryCountMsg(sender), auth)?

  fun inform_of_boundary_count(sender: WorkerName, count: USize,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(InformOfBoundaryCountMsg(sender, count), auth)?

  fun announce_connections_to_joining_workers(
    control_addrs: Map[String, (String, String)] val,
    data_addrs: Map[String, (String, String)] val,
    new_step_group_routing_ids:
      Map[WorkerName, Map[RoutingId, RoutingId] val] val,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(AnnounceConnectionsToJoiningWorkersMsg(control_addrs, data_addrs,
      new_step_group_routing_ids), auth)?

  fun announce_joining_workers(sender: WorkerName,
    control_addrs: Map[String, (String, String)] val,
    data_addrs: Map[String, (String, String)] val,
    new_step_group_routing_ids:
      Map[WorkerName, Map[RoutingId, RoutingId] val] val,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(AnnounceJoiningWorkersMsg(sender, control_addrs, data_addrs,
      new_step_group_routing_ids), auth)?

  fun announce_hash_partitions_grow(sender: WorkerName,
    joining_workers: Array[WorkerName] val,
    hash_partitions: Map[RoutingId, HashPartitions] val, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    Once migration is complete, the coordinator of a grow autoscale event
    informs all joining workers of all hash partitions. We include the joining
    workers list to make it more straightforward for the recipients to update
    the HashProxyRouters in their StatePartitionRouters.
    """
    _encode(AnnounceHashPartitionsGrowMsg(sender, joining_workers,
      hash_partitions), auth)?

  fun connected_to_joining_workers(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    Once a non-coordinator in the autoscale protocol connects boundaries to
    all joining workers, it informs the coordinator.
    """
    _encode(ConnectedToJoiningWorkersMsg(sender), auth)?

  fun announce_new_source(worker_name: WorkerName, id: RoutingId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    This message is sent to notify another worker that a new source
    has been created on this worker and that routers should be
    updated.
    """
    _encode(AnnounceNewSourceMsg(worker_name, id), auth)?

  fun rotate_log_files(auth: AmbientAuth): Array[ByteSeq] val ? =>
    _encode(RotateLogFilesMsg, auth)?

  fun clean_shutdown(auth: AmbientAuth, msg: String = ""): Array[ByteSeq] val ?
  =>
    _encode(CleanShutdownMsg(msg), auth)?

  fun report_status(code: ReportStatusCode, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(ReportStatusMsg(code), auth)?

  fun forward_inject_barrier(token: BarrierToken, sender: WorkerName,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
  _encode(ForwardInjectBarrierMsg(token, sender), auth)?

  fun forward_inject_blocking_barrier(token: BarrierToken,
    wait_for_token: BarrierToken, sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
  _encode(ForwardInjectBlockingBarrierMsg(token, wait_for_token, sender),
    auth)?

  fun forwarded_inject_barrier_fully_acked(token: BarrierToken,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
  _encode(ForwardedInjectBarrierFullyAckedMsg(token), auth)?

  fun forwarded_inject_barrier_aborted(token: BarrierToken,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
  _encode(ForwardedInjectBarrierAbortedMsg(token), auth)?

  fun remote_initiate_barrier(sender: WorkerName, token: BarrierToken,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(RemoteInitiateBarrierMsg(sender, token), auth)?

  fun remote_abort_barrier(sender: WorkerName, token: BarrierToken,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(RemoteAbortBarrierMsg(sender, token), auth)?

  fun worker_ack_barrier(sender: WorkerName, token: BarrierToken,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(WorkerAckBarrierMsg(sender, token), auth)?

  fun worker_abort_barrier(sender: WorkerName, token: BarrierToken,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(WorkerAbortBarrierMsg(sender, token), auth)?

  fun forward_barrier(target_step_id: RoutingId,
    origin_step_id: RoutingId, token: BarrierToken, seq_id: SeqId,
    connection_round: ConnectionRound, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ForwardBarrierMsg(target_step_id, origin_step_id, token,
      seq_id, connection_round), auth)?

  fun abort_checkpoint(checkpoint_id: CheckpointId, sender: WorkerName,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(AbortCheckpointMsg(checkpoint_id, sender), auth)?

  fun event_log_initiate_checkpoint(checkpoint_id: CheckpointId,
    sender: WorkerName, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(EventLogInitiateCheckpointMsg(checkpoint_id, sender), auth)?

  fun event_log_write_checkpoint_id(checkpoint_id: CheckpointId,
    sender: WorkerName, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(EventLogWriteCheckpointIdMsg(checkpoint_id, sender), auth)?

  fun event_log_ack_checkpoint(checkpoint_id: CheckpointId, sender: WorkerName,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(EventLogAckCheckpointMsg(checkpoint_id, sender), auth)?

  fun event_log_ack_checkpoint_id_written(checkpoint_id: CheckpointId,
    sender: WorkerName, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(EventLogAckCheckpointIdWrittenMsg(checkpoint_id, sender), auth)?

  fun commit_checkpoint_id(checkpoint_id: CheckpointId,
    rollback_id: RollbackId, sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(CommitCheckpointIdMsg(checkpoint_id, rollback_id, sender), auth)?

  fun request_rollback_id(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    Recovering worker requesting a rollback id.
    """
    _encode(RequestRollbackIdMsg(sender), auth)?

  fun announce_rollback_id(rollback_id: RollbackId, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    Tell a recovering worker its rollback id.
    """
    _encode(AnnounceRollbackIdMsg(rollback_id), auth)?

  fun recovery_initiated(rollback_id: RollbackId,
    sender: WorkerName, reason: RecoveryReason, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    Sent to all workers in cluster when a recovering worker has connected so
    that currently recovering workers can cede control.
    """
    _encode(RecoveryInitiatedMsg(rollback_id, sender, reason), auth)?

  fun ack_recovery_initiated(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    Worker acking that they received a RecoveryInitiatedMsg.
    """
    _encode(AckRecoveryInitiatedMsg(sender), auth)?

  fun initiate_rollback_barrier(sender: WorkerName, rollback_id: RollbackId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Sent to the primary checkpoint worker from a recovering worker to initiate
    rollback during rollback recovery phase.
    """
    _encode(InitiateRollbackBarrierMsg(sender, rollback_id), auth)?

  fun prepare_for_rollback(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    """
    Sent to all workers in cluster by recovering worker.
    """
    _encode(PrepareForRollbackMsg(sender), auth)?

  fun rollback_local_keys(sender: WorkerName, checkpoint_id: CheckpointId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Sent to all workers in cluster by recovering worker.
    """
    _encode(RollbackLocalKeysMsg(sender, checkpoint_id), auth)?

  fun ack_rollback_local_keys(sender: WorkerName, checkpoint_id: CheckpointId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Sent to ack rolling back topology graph.
    """
    _encode(AckRollbackLocalKeysMsg(sender, checkpoint_id), auth)?

  fun rollback_barrier_fully_acked(token: CheckpointRollbackBarrierToken,
    sender: WorkerName, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    """
    Sent from the primary checkpoint worker to the recovering worker to
    indicate that rollback barrier is fully acked.
    """
    _encode(RollbackBarrierFullyAckedMsg(token, sender), auth)?

  fun event_log_initiate_rollback(token: CheckpointRollbackBarrierToken,
    sender: WorkerName, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(EventLogInitiateRollbackMsg(token, sender), auth)?

  fun event_log_ack_rollback(token: CheckpointRollbackBarrierToken,
    sender: WorkerName, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(EventLogAckRollbackMsg(token, sender), auth)?

  fun resume_checkpoint(sender: WorkerName, rollback_id: RollbackId,
    checkpoint_id: CheckpointId, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ResumeCheckpointMsg(sender, rollback_id, checkpoint_id), auth)?

  fun resume_processing(sender: WorkerName, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(ResumeProcessingMsg(sender), auth)?

  fun register_producer(sender: WorkerName, source_id: RoutingId,
    target_id: RoutingId, connection_round: ConnectionRound,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(RegisterProducerMsg(sender, source_id, target_id,
      connection_round), auth)?

  fun unregister_producer(sender: WorkerName, source_id: RoutingId,
    target_id: RoutingId, connection_round: ConnectionRound,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(UnregisterProducerMsg(sender, source_id, target_id,
      connection_round), auth)?

  fun connector_stream_notify(worker_name: WorkerName, source_name: String,
    stream: StreamTuple, request_id: ConnectorStreamNotifyId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ConnectorStreamNotifyMsg(worker_name, source_name, stream, request_id), auth)?

  fun connector_stream_notify_response(source_name: String,
    success: Bool, stream: StreamTuple, request_id: ConnectorStreamNotifyId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ConnectorStreamNotifyResponseMsg(source_name, success, stream, request_id), auth)?

  fun connector_streams_relinquish(worker_name: WorkerName, source_name: String,
    streams: Array[StreamTuple] val,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ConnectorStreamsRelinquishMsg(worker_name, source_name, streams),
      auth)?

  fun connector_streams_shrink(worker_name: WorkerName, source_name: String,
    streams: Array[StreamTuple] val, source_id: RoutingId,
    auth: AmbientAuth) : Array[ByteSeq] val ?
  =>
    _encode(ConnectorStreamsShrinkMsg(worker_name, source_name, streams,
      source_id), auth)?

  fun connector_streams_shrink_response(source_name: String,
    streams: Array[StreamTuple] val, host: String, service: String,
    source_id: RoutingId, auth: AmbientAuth) : Array[ByteSeq] val ?
  =>
    _encode(ConnectorStreamsShrinkResponseMsg(source_name, streams, host,
      service, source_id), auth)?

  fun connector_worker_shrink_complete(source_name: String,
    worker_name: WorkerName, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ConnectorWorkerShrinkCompleteMsg(source_name, worker_name), auth)?

  fun connector_add_source_addr(worker_name: WorkerName,
    source_name: String, host: String, service: String,
    auth: AmbientAuth) : Array[ByteSeq] val ?
  =>
    _encode(ConnectorAddSourceAddrMsg(worker_name, source_name,
      host, service), auth)?

  fun connector_leader_state_received_ack(leader_name: WorkerName,
    source_name: String, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ConnectorLeaderStateReceivedAckMsg(leader_name,
      source_name), auth)?

  fun connector_new_leader(leader_name: WorkerName,
    source_name: String, auth: AmbientAuth) : Array[ByteSeq] val ?
  =>
    _encode(ConnectorNewLeaderMsg(leader_name, source_name), auth)?

  fun connector_leadership_relinquish_state(
    relinquishing_leader_name: WorkerName, source_name: String,
    active_stream_map: Map[StreamId, WorkerName] val,
    inactive_stream_map: Map[StreamId, StreamTuple] val,
    source_addr_map: Map[WorkerName, (String, String)] val,
    auth: AmbientAuth) : Array[ByteSeq] val ?
  =>
    _encode(ConnectorLeadershipRelinquishMsg(
      relinquishing_leader_name, source_name, active_stream_map,
      inactive_stream_map, source_addr_map), auth)?

  fun connector_leader_name_request(requesting_worker_name: WorkerName,
    source_name: String, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ConnectorLeaderNameRequestMsg(requesting_worker_name,
      source_name), auth)?

  fun connector_leader_name_response(leader_name: WorkerName,
    source_name: String, auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(ConnectorLeaderNameResponseMsg(leader_name, source_name),
      auth)?

  fun worker_state_entity_count_request(worker_name: WorkerName,
    requester: WorkerName, request_id: RequestId,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(WorkerStateEntityCountRequestMsg(requester, request_id),
      auth)?

  fun worker_state_entity_count_response(worker_name: WorkerName,
    request_id: RequestId, worker_state_entity_count_json: String,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(WorkerStateEntityCountResponseMsg(worker_name, request_id,
      worker_state_entity_count_json), auth)?

  fun try_shrink_request(target_workers: Array[WorkerName] val,
    shrink_count: U64, worker_name: WorkerName, conn_id: U128,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(TryShrinkRequestMsg(target_workers, shrink_count, worker_name,
      conn_id), auth)?

  fun try_shrink_response(msg: Array[ByteSeq] val, conn_id: U128,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(TryShrinkResponseMsg(msg, conn_id), auth)?

  fun try_join_request(joining_worker_name: WorkerName, worker_count: USize,
    proxy_worker_name: WorkerName, conn_id: U128, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(TryJoinRequestMsg(joining_worker_name, worker_count,
      proxy_worker_name, conn_id), auth)?

  fun try_join_response(msg: Array[ByteSeq] val, conn_id: U128,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(TryJoinResponseMsg(msg, conn_id), auth)?

  fun initiate_pausing_checkpoint(sender: WorkerName, id: U128,
    auth: AmbientAuth): Array[ByteSeq] val ?
  =>
    _encode(InitiatePausingCheckpointMsg(sender, id), auth)?

  fun pausing_checkpoint_initiated(id: U128, auth: AmbientAuth):
    Array[ByteSeq] val ?
  =>
    _encode(PausingCheckpointInitiatedMsg(id), auth)?

  fun restart_repeating_checkpoints(auth: AmbientAuth): Array[ByteSeq] val ? =>
    _encode(RestartRepeatingCheckpointsMsg, auth)?

primitive ChannelMsgDecoder
  fun apply(data: Array[U8] val, auth: AmbientAuth): ChannelMsg =>
    try
      match Serialised.input(InputSerialisedAuth(auth), data)(
        DeserialiseAuth(auth))?
      | let m: ChannelMsg =>
        m
      else
        UnknownChannelMsg(data)
      end
    else
      UnknownChannelMsg(data)
    end

trait val ChannelMsg
  fun val string(): String

trait val SourceCoordinatorMsg is ChannelMsg
  fun source_name(): String

class val UnknownChannelMsg is ChannelMsg
  let data: Array[U8] val

  fun val string(): String => __loc.type_name()
  new val create(d: Array[U8] val) =>
    data = d

class val IdentifyControlPortMsg is ChannelMsg
  let worker_name: WorkerName
  let service: String

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName, s: String) =>
    worker_name = name
    service = s

class val IdentifyDataPortMsg is ChannelMsg
  let worker_name: WorkerName
  let service: String

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName, s: String) =>
    worker_name = name
    service = s

class val ReconnectDataPortMsg is ChannelMsg
  let worker_name: WorkerName
  let service: String

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName, s: String) =>
    worker_name = name
    service = s

class val SpinUpLocalTopologyMsg is ChannelMsg
  let local_topology: LocalTopology

  fun val string(): String => __loc.type_name()
  new val create(lt: LocalTopology) =>
    local_topology = lt

class val SpinUpStepMsg is ChannelMsg
  let step_id: U64
  let step_builder: StepBuilder

  fun val string(): String => __loc.type_name()
  new val create(s_id: U64, s_builder: StepBuilder) =>
    step_id = s_id
    step_builder = s_builder

class val TopologyReadyMsg is ChannelMsg
  let worker_name: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName) =>
    worker_name = name

class val CreateConnectionsMsg is ChannelMsg
  let control_addrs: Map[String, (String, String)] val
  let data_addrs: Map[String, (String, String)] val

  fun val string(): String => __loc.type_name()
  new val create(c_addrs: Map[String, (String, String)] val,
    d_addrs: Map[String, (String, String)] val)
  =>
    control_addrs = c_addrs
    data_addrs = d_addrs

class val ConnectionsReadyMsg is ChannelMsg
  let worker_name: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName) =>
    worker_name = name

class val ConnectorNewLeaderMsg is SourceCoordinatorMsg
  let leader_name: WorkerName
  let _source_name: String

  fun val string(): String => __loc.type_name()
  new val create(leader_name': WorkerName, source_name': String) =>
    leader_name = leader_name'
    _source_name = source_name'

  fun source_name(): String =>
    _source_name

class val ConnectorLeaderStateReceivedAckMsg is SourceCoordinatorMsg
  let leader_name: WorkerName
  let _source_name: String

  fun val string(): String => __loc.type_name()
  new val create(leader_name': WorkerName, source_name': String) =>
    leader_name = leader_name'
    _source_name = source_name'

  fun source_name(): String =>
    _source_name

class val ConnectorAddSourceAddrMsg is SourceCoordinatorMsg
  let worker_name: String
  let _source_name: String
  let host: String
  let service: String

  fun val string(): String => __loc.type_name()
  new val create(worker_name': WorkerName, source_name': String,
    host': String, service': String)
  =>
    worker_name = worker_name'
    _source_name = source_name'
    host = host'
    service = service'

  fun source_name(): String =>
    _source_name

class val ConnectorLeadershipRelinquishMsg is SourceCoordinatorMsg
  let worker_name: String
  let _source_name: String
  let active_streams: Map[StreamId, WorkerName] val
  let inactive_streams: Map[StreamId, StreamTuple] val
  let source_addrs: Map[WorkerName, (String, String)] val

  fun val string(): String => __loc.type_name()
  new val create(worker_name': WorkerName, source_name': String,
    active_streams': Map[StreamId, WorkerName] val,
    inactive_streams': Map[StreamId, StreamTuple] val,
    source_addrs': Map[WorkerName, (String, String)] val)
  =>
    worker_name = worker_name'
    _source_name = source_name'
    active_streams = active_streams'
    inactive_streams = inactive_streams'
    source_addrs = source_addrs'

  fun source_name(): String =>
    _source_name

class val ConnectorStreamsRelinquishMsg is SourceCoordinatorMsg
  let worker_name: WorkerName
  let _source_name: String
  let streams: Array[StreamTuple] val

  fun val string(): String => __loc.type_name()
  new val create(worker_name': WorkerName, source_name': String,
    streams': Array[StreamTuple] val)
  =>
    worker_name = worker_name'
    _source_name = source_name'
    streams = streams'

  fun source_name(): String =>
    _source_name

class val ConnectorWorkerShrinkCompleteMsg is SourceCoordinatorMsg
  let worker_name: WorkerName
  let _source_name: String

  fun val string(): String => __loc.type_name()
  new val create(source_name': String, worker_name': WorkerName) =>
    worker_name = worker_name'
    _source_name = source_name'

  fun source_name(): String =>
    _source_name


class val ConnectorStreamsShrinkMsg is SourceCoordinatorMsg
  let worker_name: WorkerName
  let _source_name: String
  let streams: Array[StreamTuple] val
  let source_id: RoutingId

  fun val string(): String => __loc.type_name()
  new val create(worker_name': WorkerName, source_name': String,
    streams': Array[StreamTuple] val, source_id': RoutingId)
  =>
    worker_name = worker_name'
    _source_name = source_name'
    streams = streams'
    source_id = source_id'

  fun source_name(): String =>
    _source_name

class val ConnectorStreamsShrinkResponseMsg is SourceCoordinatorMsg
  let _source_name: String
  let streams: Array[StreamTuple] val
  let host: String
  let service: String
  let source_id: RoutingId

  fun val string(): String => __loc.type_name()
  new val create(source_name': String, streams': Array[StreamTuple] val,
    host': String, service': String, source_id': RoutingId)
  =>
    _source_name = source_name'
    streams = streams'
    host = host'
    service = service'
    source_id = source_id'

  fun source_name(): String =>
    _source_name

class val ConnectorStreamNotifyMsg is SourceCoordinatorMsg
  let worker_name: WorkerName
  let _source_name: String
  let stream: StreamTuple
  let request_id: ConnectorStreamNotifyId

  fun val string(): String => __loc.type_name()
  new val create(worker_name': WorkerName, source_name': String,
    stream': StreamTuple,
    request_id': ConnectorStreamNotifyId)
  =>
    worker_name = worker_name'
    _source_name = source_name'
    stream = stream'
    request_id = request_id'

  fun source_name(): String =>
    _source_name

class val ConnectorStreamNotifyResponseMsg is SourceCoordinatorMsg
  let _source_name: String
  let stream: StreamTuple
  let request_id: ConnectorStreamNotifyId
  let success: Bool

  fun val string(): String => __loc.type_name()
  new val create(source_name': String, success': Bool, stream': StreamTuple,
    request_id': ConnectorStreamNotifyId)
  =>
    _source_name = source_name'
    stream = stream'
    success = success'
    request_id = request_id'

  fun source_name(): String =>
    _source_name

class val ConnectorLeaderNameRequestMsg is SourceCoordinatorMsg
  let _source_name: String
  let worker_name: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(worker_name': WorkerName, source_name': String) =>
    _source_name = source_name'
    worker_name = worker_name'

  fun source_name(): String =>
    _source_name

class val ConnectorLeaderNameResponseMsg is SourceCoordinatorMsg
  let _source_name: String
  let leader_name: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(leader_name': WorkerName, source_name': String) =>
    _source_name = source_name'
    leader_name = leader_name'

  fun source_name(): String =>
    _source_name

class val ReportWorkerReadyToWorkMsg is ChannelMsg
  let worker_name: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName) =>
    worker_name = name

primitive AllWorkersReadyToWorkMsg is ChannelMsg
  fun val string(): String => __loc.type_name()

class val CreateDataChannelListener is ChannelMsg
  let workers: Array[String] val

  fun val string(): String => __loc.type_name()
  new val create(ws: Array[String] val) =>
    workers = ws

class val DataConnectMsg is ChannelMsg
  let sender_name: String
  let sender_boundary_id: U128
  let highest_seq_id: SeqId
  let connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(sender_name': String, sender_boundary_id': U128,
    highest_seq_id': SeqId, connection_round': ConnectionRound)
  =>
    sender_name = sender_name'
    sender_boundary_id = sender_boundary_id'
    highest_seq_id = highest_seq_id'
    connection_round = connection_round'

primitive DataDisconnectMsg is ChannelMsg
  fun val string(): String => __loc.type_name()

class val StartNormalDataSendingMsg is ChannelMsg
  let last_id_seen: SeqId
  let connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(last_id_seen': SeqId, connection_round': ConnectionRound) =>
    last_id_seen = last_id_seen'
    connection_round = connection_round'

class val DataReceiverAckImmediatelyMsg is ChannelMsg
  let connection_round: ConnectionRound
  let boundary_routing_id: RoutingId

  new val create(connection_round': ConnectionRound,
    boundary_routing_id': RoutingId)
  =>
    connection_round = connection_round'
    boundary_routing_id = boundary_routing_id'

  fun val string(): String => __loc.type_name()

primitive ImmediateAckMsg is ChannelMsg
  fun val string(): String => __loc.type_name()

class val RequestBoundaryCountMsg is ChannelMsg
  let sender_name: String

  fun val string(): String => __loc.type_name()
  new val create(from: String) =>
    sender_name = from

class val InformOfBoundaryCountMsg is ChannelMsg
  let sender_name: String
  let boundary_count: USize

  fun val string(): String => __loc.type_name()
  new val create(from: String, count: USize) =>
    sender_name = from
    boundary_count = count

class val ReplayCompleteMsg is ChannelMsg
  let sender_name: String
  let boundary_id: U128

  fun val string(): String => __loc.type_name()
  new val create(from: String, b_id: U128) =>
    sender_name = from
    boundary_id = b_id

class val KeyMigrationMsg is ChannelMsg
  let _step_group: RoutingId
  let _key: Key
  // The next checkpoint that this migrated step will be a part of
  let _checkpoint_id: CheckpointId
  let _state: ByteSeq val
  let _worker: WorkerName
  let _connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(step_group': RoutingId, key': Key,
    checkpoint_id': CheckpointId, state': ByteSeq val, worker': WorkerName,
    connection_round': ConnectionRound)
  =>
    _step_group = step_group'
    _key = key'
    _checkpoint_id = checkpoint_id'
    _state = state'
    _worker = worker'
    _connection_round = connection_round'

  fun step_group(): RoutingId => _step_group
  fun checkpoint_id(): CheckpointId => _checkpoint_id
  fun state(): ByteSeq val => _state
  fun key(): Key => _key
  fun worker(): String => _worker
  fun connection_round(): ConnectionRound => _connection_round

class val MigrationBatchCompleteMsg is ChannelMsg
  let sender_name: WorkerName
  let connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(sender: WorkerName, connection_round': ConnectionRound) =>
    sender_name = sender
    connection_round = connection_round'

class val WorkerCompletedMigrationBatch is ChannelMsg
  let sender_name: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender: WorkerName) =>
    sender_name = sender

class val MuteRequestMsg is ChannelMsg
  let originating_worker: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(worker: WorkerName) =>
    originating_worker = worker

class val UnmuteRequestMsg is ChannelMsg
  let originating_worker: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(worker: WorkerName) =>
    originating_worker = worker

class val KeyMigrationCompleteMsg is ChannelMsg
  let key: Key

  fun val string(): String => __loc.type_name()
  new val create(k: Key)
  =>
    key = k

class val BeginLeavingMigrationMsg is ChannelMsg
  let remaining_workers: Array[String] val
  let leaving_workers: Array[String] val

  fun val string(): String => __loc.type_name()
  new val create(remaining_workers': Array[String] val,
    leaving_workers': Array[String] val)
  =>
    remaining_workers = remaining_workers'
    leaving_workers = leaving_workers'

class val InitiateShrinkMsg is ChannelMsg
  let remaining_workers: Array[String] val
  let leaving_workers: Array[String] val

  fun val string(): String => __loc.type_name()
  new val create(remaining_workers': Array[String] val,
    leaving_workers': Array[String] val)
  =>
    remaining_workers = remaining_workers'
    leaving_workers = leaving_workers'

class val PrepareShrinkMsg is ChannelMsg
  let remaining_workers: Array[String] val
  let leaving_workers: Array[String] val

  fun val string(): String => __loc.type_name()
  new val create(remaining_workers': Array[String] val,
    leaving_workers': Array[String] val)
  =>
    remaining_workers = remaining_workers'
    leaving_workers = leaving_workers'

class val LeavingMigrationAckRequestMsg is ChannelMsg
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val LeavingMigrationAckMsg is ChannelMsg
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val AckDataReceivedMsg is ChannelMsg
  let sender_name: WorkerName
  let sender_step_id: RoutingId
  let seq_id: SeqId

  fun val string(): String => __loc.type_name()
  new val create(sender_name': WorkerName, sender_step_id': U128,
    seq_id': SeqId)
  =>
    sender_name = sender_name'
    sender_step_id = sender_step_id'
    seq_id = seq_id'

primitive RequestBoundaryPunctuationAckMsg is ChannelMsg
  fun val string(): String => __loc.type_name()

class val ReceiveBoundaryPunctuationAckMsg is ChannelMsg
  let connection_round: ConnectionRound

  new val create(connection_round': ConnectionRound) =>
    connection_round = connection_round'
  fun val string(): String => __loc.type_name()

class val DataMsg is ChannelMsg
  let pipeline_time_spent: U64
  let producer_id: RoutingId
  let seq_id: SeqId
  let delivery_msg: DeliveryMsg
  let latest_ts: U64
  let metrics_id: U16
  let metric_name: String
  let connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(msg: DeliveryMsg, producer_id': RoutingId,
    pipeline_time_spent': U64, seq_id': SeqId, latest_ts': U64,
    metrics_id': U16, metric_name': String, connection_round': ConnectionRound)
  =>
    producer_id = producer_id'
    seq_id = seq_id'
    pipeline_time_spent = pipeline_time_spent'
    delivery_msg = msg
    latest_ts = latest_ts'
    metrics_id = metrics_id'
    metric_name = metric_name'
    connection_round = connection_round'

trait val DeliveryMsg is ChannelMsg
  fun sender_name(): String
  fun val deliver(pipeline_time_spent: U64,
    producer_id: RoutingId, producer: Producer ref, seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64,
    data_routes: Map[RoutingId, Consumer] val,
    step_group_steps: Map[RoutingId, Array[Step] val] val,
    consumer_ids: MapIs[Consumer, RoutingId] val) ?
  fun metric_name(): String
  fun msg_uid(): U128
  fun event_ts(): U64

class val ForwardMsg[D: Any val] is DeliveryMsg
  let _target_id: RoutingId
  let _sender_name: String
  let _data: D
  let _key: Key
  let _event_ts: U64
  let _watermark_ts: U64
  let _metric_name: String
  let _proxy_address: ProxyAddress
  let _msg_uid: MsgId
  let _frac_ids: FractionalMessageId

  fun input(): Any val => _data
  fun metric_name(): String => _metric_name
  fun msg_uid(): U128 => _msg_uid
  fun frac_ids(): FractionalMessageId => _frac_ids
  fun event_ts(): U64 => _event_ts

  fun val string(): String => __loc.type_name()
  new val create(t_id: RoutingId, from: String,
    m_data: D, k: Key, e_ts: U64, w_ts: U64, m_name: String,
    proxy_address: ProxyAddress, msg_uid': MsgId,
    frac_ids': FractionalMessageId)
  =>
    _target_id = t_id
    _sender_name = from
    _data = m_data
    _key = k
    _event_ts = e_ts
    _watermark_ts = w_ts
    _metric_name = m_name
    _proxy_address = proxy_address
    _msg_uid = msg_uid'
    _frac_ids = frac_ids'

  fun sender_name(): String => _sender_name

  fun val deliver(pipeline_time_spent: U64,
    producer_id: RoutingId, producer: Producer ref, seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64,
    data_routes: Map[RoutingId, Consumer] val,
    step_group_steps: Map[RoutingId, Array[Step] val] val,
    consumer_ids: MapIs[Consumer, RoutingId] val) ?
  =>
    let target_step = data_routes(_target_id)?
    ifdef "trace" then
      @printf[I32]("DataRouter found Step\n".cstring())
    end

    target_step.run[D](_metric_name, pipeline_time_spent, _data, _key,
      _event_ts, _watermark_ts, producer_id, producer, _msg_uid, _frac_ids,
      seq_id, latest_ts, metrics_id, worker_ingress_ts)

class val ForwardStatePartitionMsg[D: Any val] is DeliveryMsg
  let _target_step_group: RoutingId
  let _target_key: Key
  let _sender_name: String
  let _data: D
  let _event_ts: U64
  let _watermark_ts: U64
  let _metric_name: String
  let _msg_uid: MsgId
  let _frac_ids: FractionalMessageId

  fun input(): Any val => _data
  fun metric_name(): String => _metric_name
  fun msg_uid(): U128 => _msg_uid
  fun frac_ids(): FractionalMessageId => _frac_ids
  fun event_ts(): U64 => _event_ts

  fun val string(): String => __loc.type_name()
  new val create(step_group: RoutingId, from: String, m_data: D, k: Key,
    e_ts: U64, w_ts: U64, m_name: String, msg_uid': MsgId,
    frac_ids': FractionalMessageId)
  =>
    _target_step_group = step_group
    _target_key = k
    _sender_name = from
    _data = m_data
    _event_ts = e_ts
    _watermark_ts = w_ts
    _metric_name = m_name
    _msg_uid = msg_uid'
    _frac_ids = frac_ids'

  fun sender_name(): String => _sender_name

  fun val deliver(pipeline_time_spent: U64,
    producer_id: RoutingId, producer: Producer ref, seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64,
    data_routes: Map[RoutingId, Consumer] val,
    step_group_steps: Map[RoutingId, Array[Step] val] val,
    consumer_ids: MapIs[Consumer, RoutingId] val) ?
  =>
    ifdef "trace" then
      @printf[I32]("DataRouter found Step\n".cstring())
    end

    let local_state_steps = step_group_steps(_target_step_group)?
    let idx = (HashKey(_target_key) % local_state_steps.size().u128()).usize()
    let target_step = local_state_steps(idx)?

    let target_id = consumer_ids(target_step)?

    target_step.run[D](_metric_name, pipeline_time_spent, _data, _target_key,
      _event_ts, _watermark_ts, producer_id, producer, _msg_uid, _frac_ids,
      seq_id, latest_ts, metrics_id, worker_ingress_ts)

class val ForwardStatelessPartitionMsg[D: Any val] is DeliveryMsg
  let _target_partition_id: RoutingId
  let _key: Key
  let _sender_name: String
  let _data: D
  let _event_ts: U64
  let _watermark_ts: U64
  let _metric_name: String
  let _msg_uid: MsgId
  let _frac_ids: FractionalMessageId

  fun input(): Any val => _data
  fun metric_name(): String => _metric_name
  fun msg_uid(): U128 => _msg_uid
  fun frac_ids(): FractionalMessageId => _frac_ids
  fun event_ts(): U64 => _event_ts

  fun val string(): String => __loc.type_name()
  new val create(target_p_id: RoutingId, from: String, m_data: D, k: Key,
    e_ts: U64, w_ts: U64, m_name: String, msg_uid': MsgId,
    frac_ids': FractionalMessageId)
  =>
    _target_partition_id = target_p_id
    _key = k
    _sender_name = from
    _data = m_data
    _event_ts = e_ts
    _watermark_ts = w_ts
    _metric_name = m_name
    _msg_uid = msg_uid'
    _frac_ids = frac_ids'

  fun sender_name(): String => _sender_name

  fun val deliver(pipeline_time_spent: U64,
    producer_id: RoutingId, producer: Producer ref, seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64,
    data_routes: Map[RoutingId, Consumer] val,
    step_group_steps: Map[RoutingId, Array[Step] val] val,
    consumer_ids: MapIs[Consumer, RoutingId] val) ?
  =>
    ifdef "trace" then
      @printf[I32]("DataRouter found Step\n".cstring())
    end

    let partitions = step_group_steps(_target_partition_id)?
    let idx = (HashKey(_key) % partitions.size().u128()).usize()
    let target_step = partitions(idx)?

    let target_id = consumer_ids(target_step)?

    target_step.run[D](_metric_name, pipeline_time_spent, _data, _key,
      _event_ts, _watermark_ts, producer_id, producer, _msg_uid, _frac_ids,
      seq_id, latest_ts, metrics_id, worker_ingress_ts)

class val RequestRecoveryInfoMsg is ChannelMsg
  """
  This message is sent to the cluster when beginning recovery.
  """
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val InformRecoveringWorkerMsg is ChannelMsg
  """
  This message is sent as a response to a RequestRecoveryInfo message.
  """
  let sender: WorkerName
  let checkpoint_id: CheckpointId

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, s_id: CheckpointId) =>
    sender = sender'
    checkpoint_id = s_id

class val JoinClusterMsg is ChannelMsg
  """
  This message is sent from a worker requesting to join a running cluster to
  any existing worker in the cluster.
  """
  let worker_name: WorkerName
  let worker_count: USize

  fun val string(): String => __loc.type_name()
  new val create(w: WorkerName, wc: USize) =>
    worker_name = w
    worker_count = wc

class val InformJoiningWorkerMsg is ChannelMsg
  """
  This message is sent as a response to a JoinCluster message.
  """
  let sender_name: WorkerName
  let local_topology: LocalTopology
  let checkpoint_id: CheckpointId
  let rollback_id: CheckpointId
  let metrics_app_name: String
  let metrics_host: String
  let metrics_service: String
  let control_addrs: Map[WorkerName, (String, String)] val
  let data_addrs: Map[WorkerName, (String, String)] val
  let worker_names: Array[WorkerName] val
  // The worker currently in control of checkpoints
  let primary_checkpoint_worker: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender: WorkerName, app: String, l_topology: LocalTopology,
    checkpoint_id': CheckpointId, rollback_id': RollbackId,
    m_host: String, m_service: String,
    c_addrs: Map[WorkerName, (String, String)] val,
    d_addrs: Map[WorkerName, (String, String)] val,
    w_names: Array[String] val,
    p_checkpoint_worker: WorkerName)
  =>
    sender_name = sender
    local_topology = l_topology
    checkpoint_id = checkpoint_id'
    rollback_id = rollback_id'
    metrics_app_name = app
    metrics_host = m_host
    metrics_service = m_service
    control_addrs = c_addrs
    data_addrs = d_addrs
    worker_names = w_names
    primary_checkpoint_worker = p_checkpoint_worker

class val InformJoinErrorMsg is ChannelMsg
  let message: String

  fun val string(): String => __loc.type_name()
  new val create(m: String) =>
    message = m

// TODO: Don't send host over since we need to determine that on receipt
class val JoiningWorkerInitializedMsg is ChannelMsg
  let worker_name: WorkerName
  let control_addr: (String, String)
  let data_addr: (String, String)
  let step_group_routing_ids: Map[RoutingId, RoutingId] val

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName, c_addr: (String, String),
    d_addr: (String, String), s_routing_ids: Map[RoutingId, RoutingId] val)
  =>
    worker_name = name
    control_addr = c_addr
    data_addr = d_addr
    step_group_routing_ids = s_routing_ids

class val InitiateStopTheWorldForGrowMigrationMsg is ChannelMsg
  let sender: WorkerName
  let new_workers: Array[String] val

  fun val string(): String => __loc.type_name()
  new val create(s: WorkerName, ws: Array[String] val) =>
    sender = s
    new_workers = ws

class val InitiateGrowMigrationMsg is ChannelMsg
  let new_workers: Array[String] val
  let checkpoint_id: CheckpointId

  fun val string(): String => __loc.type_name()
  new val create(ws: Array[String] val, s_id: CheckpointId) =>
    new_workers = ws
    checkpoint_id = s_id

class val PreRegisterJoiningWorkersMsg is ChannelMsg
  let joining_workers: Array[String] val

  fun val string(): String => __loc.type_name()
  new val create(ws: Array[String] val) =>
    joining_workers = ws

primitive AutoscaleCompleteMsg is ChannelMsg
  fun val string(): String => __loc.type_name()

class val InitiateStopTheWorldForShrinkMigrationMsg is ChannelMsg
  let sender: WorkerName
  let remaining_workers: Array[String] val
  let leaving_workers: Array[String] val

  fun val string(): String => __loc.type_name()
  new val create(s: WorkerName, r_ws: Array[String] val,
    l_ws: Array[String] val)
  =>
    sender = s
    remaining_workers = r_ws
    leaving_workers = l_ws

class val LeavingWorkerDoneMigratingMsg is ChannelMsg
  let worker_name: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(name: WorkerName)
  =>
    worker_name = name

class val AnnounceConnectionsToJoiningWorkersMsg is ChannelMsg
  let control_addrs: Map[String, (String, String)] val
  let data_addrs: Map[String, (String, String)] val
  let new_step_group_routing_ids:
    Map[WorkerName, Map[RoutingId, RoutingId] val] val

  fun val string(): String => __loc.type_name()
  new val create(c_addrs: Map[String, (String, String)] val,
    d_addrs: Map[String, (String, String)] val,
    sri: Map[WorkerName, Map[RoutingId, RoutingId] val] val)
  =>
    control_addrs = c_addrs
    data_addrs = d_addrs
    new_step_group_routing_ids = sri

class val AnnounceJoiningWorkersMsg is ChannelMsg
  let sender: WorkerName
  let control_addrs: Map[String, (String, String)] val
  let data_addrs: Map[String, (String, String)] val
  let new_step_group_routing_ids:
    Map[WorkerName, Map[RoutingId, RoutingId] val] val

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName,
    c_addrs: Map[String, (String, String)] val,
    d_addrs: Map[String, (String, String)] val,
    sri: Map[WorkerName, Map[RoutingId, RoutingId] val] val)
  =>
    sender = sender'
    control_addrs = c_addrs
    data_addrs = d_addrs
    new_step_group_routing_ids = sri

class val AnnounceHashPartitionsGrowMsg is ChannelMsg
  let sender: WorkerName
  let joining_workers: Array[String] val
  let hash_partitions: Map[RoutingId, HashPartitions] val

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, joining_workers': Array[String] val,
    hash_partitions': Map[RoutingId, HashPartitions] val)
  =>
    sender = sender'
    joining_workers = joining_workers'
    hash_partitions = hash_partitions'

class val ConnectedToJoiningWorkersMsg is ChannelMsg
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val AnnounceNewSourceMsg is ChannelMsg
  """
  This message is sent to notify another worker that a new source has
  been created on this worker and that routers should be updated.
  """
  let sender: WorkerName
  let source_id: RoutingId

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, id: RoutingId) =>
    sender = sender'
    source_id = id

primitive RotateLogFilesMsg is ChannelMsg
  """
  This message is sent to a worker instructing it to rotate its log files.
  """
  fun val string(): String => __loc.type_name()

class val CleanShutdownMsg is ChannelMsg
  let msg: String

  fun val string(): String => __loc.type_name()
  new val create(m: String) =>
    msg = m

class val ForwardInjectBarrierMsg is ChannelMsg
  let token: BarrierToken
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(token': BarrierToken, sender': WorkerName) =>
    token = token'
    sender = sender'

class val ForwardInjectBlockingBarrierMsg is ChannelMsg
  let token: BarrierToken
  let wait_for_token: BarrierToken
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(token': BarrierToken, wait_for_token': BarrierToken,
    sender': WorkerName)
  =>
    token = token'
    wait_for_token = wait_for_token'
    sender = sender'

class val ForwardedInjectBarrierFullyAckedMsg is ChannelMsg
  let token: BarrierToken

  fun val string(): String => __loc.type_name()
  new val create(token': BarrierToken) =>
    token = token'

class val ForwardedInjectBarrierAbortedMsg is ChannelMsg
  let token: BarrierToken

  fun val string(): String => __loc.type_name()
  new val create(token': BarrierToken) =>
    token = token'

class val RemoteInitiateBarrierMsg is ChannelMsg
  let sender: WorkerName
  let token: BarrierToken

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, token': BarrierToken) =>
    sender = sender'
    token = token'

class val RemoteAbortBarrierMsg is ChannelMsg
  let sender: WorkerName
  let token: BarrierToken

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, token': BarrierToken) =>
    sender = sender'
    token = token'

class val WorkerAckBarrierMsg is ChannelMsg
  let sender: WorkerName
  let token: BarrierToken

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, token': BarrierToken) =>
    sender = sender'
    token = token'

class val WorkerAbortBarrierMsg is ChannelMsg
  let sender: WorkerName
  let token: BarrierToken

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, token': BarrierToken) =>
    sender = sender'
    token = token'

class val ForwardBarrierMsg is ChannelMsg
  let target_id: RoutingId
  let origin_id: RoutingId
  let token: BarrierToken
  // Seq id assigned by boundary
  let seq_id: SeqId
  let connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(target_id': RoutingId, origin_id': RoutingId,
    token': BarrierToken, seq_id': SeqId, connection_round': ConnectionRound)
  =>
    target_id = target_id'
    origin_id = origin_id'
    token = token'
    seq_id = seq_id'
    connection_round = connection_round'

class val AbortCheckpointMsg is ChannelMsg
  let checkpoint_id: CheckpointId
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(checkpoint_id': CheckpointId, sender': WorkerName) =>
    checkpoint_id = checkpoint_id'
    sender = sender'

class val EventLogInitiateCheckpointMsg is ChannelMsg
  let checkpoint_id: CheckpointId
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(checkpoint_id': CheckpointId, sender': WorkerName) =>
    checkpoint_id = checkpoint_id'
    sender = sender'

class val EventLogWriteCheckpointIdMsg is ChannelMsg
  let checkpoint_id: CheckpointId
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(checkpoint_id': CheckpointId, sender': WorkerName) =>
    checkpoint_id = checkpoint_id'
    sender = sender'

class val EventLogAckCheckpointMsg is ChannelMsg
  let checkpoint_id: CheckpointId
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(checkpoint_id': CheckpointId, sender': WorkerName) =>
    checkpoint_id = checkpoint_id'
    sender = sender'

class val EventLogAckCheckpointIdWrittenMsg is ChannelMsg
  let checkpoint_id: CheckpointId
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(checkpoint_id': CheckpointId, sender': WorkerName) =>
    checkpoint_id = checkpoint_id'
    sender = sender'

class val CommitCheckpointIdMsg is ChannelMsg
  let checkpoint_id: CheckpointId
  let rollback_id: RollbackId
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(checkpoint_id': CheckpointId, rollback_id': RollbackId,
    sender': WorkerName)
  =>
    checkpoint_id = checkpoint_id'
    rollback_id = rollback_id'
    sender = sender'

class val RequestRollbackIdMsg is ChannelMsg
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val AnnounceRollbackIdMsg is ChannelMsg
  let rollback_id: RollbackId

  fun val string(): String => __loc.type_name()
  new val create(rollback_id': RollbackId) =>
    rollback_id = rollback_id'

class val RecoveryInitiatedMsg is ChannelMsg
  let rollback_id: RollbackId
  let sender: WorkerName
  let reason: RecoveryReason

  fun val string(): String => __loc.type_name()
  new val create(rollback_id': RollbackId, sender': WorkerName,
    reason': RecoveryReason)
  =>
    rollback_id = rollback_id'
    sender = sender'
    reason = reason'

class val AckRecoveryInitiatedMsg is ChannelMsg
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val EventLogInitiateRollbackMsg is ChannelMsg
  let token: CheckpointRollbackBarrierToken
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(token': CheckpointRollbackBarrierToken, sender': WorkerName) =>
    token = token'
    sender = sender'

class val EventLogAckRollbackMsg is ChannelMsg
  let token: CheckpointRollbackBarrierToken
  let sender: WorkerName
  let nanos: U64 = Time.nanos()

  fun val string(): String => __loc.type_name() + "." + nanos.string()
  new val create(token': CheckpointRollbackBarrierToken, sender': WorkerName) =>
    token = token'
    sender = sender'

class val InitiateRollbackBarrierMsg is ChannelMsg
  let recovering_worker: WorkerName
  let rollback_id: RollbackId

  fun val string(): String => __loc.type_name()
  new val create(recovering_worker': WorkerName, rollback_id': RollbackId) =>
    recovering_worker = recovering_worker'
    rollback_id = rollback_id'

class val PrepareForRollbackMsg is ChannelMsg
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val RollbackLocalKeysMsg is ChannelMsg
  let sender: WorkerName
  let checkpoint_id: CheckpointId

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, s_id: CheckpointId) =>
    sender = sender'
    checkpoint_id = s_id

class val AckRollbackLocalKeysMsg is ChannelMsg
  let sender: WorkerName
  let checkpoint_id: CheckpointId

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, s_id: CheckpointId) =>
    sender = sender'
    checkpoint_id = s_id

class val RollbackBarrierFullyAckedMsg is ChannelMsg
  let token: CheckpointRollbackBarrierToken
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(token': CheckpointRollbackBarrierToken, sender': WorkerName) =>
    token = token'
    sender = sender'

class val ResumeCheckpointMsg is ChannelMsg
  let sender: WorkerName
  let rollback_id: RollbackId
  let checkpoint_id: CheckpointId

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, r_id: RollbackId, c_id: CheckpointId) =>
    sender = sender'
    rollback_id = r_id
    checkpoint_id = c_id

class val ResumeProcessingMsg is ChannelMsg
  let sender: WorkerName

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName) =>
    sender = sender'

class val RegisterProducerMsg is ChannelMsg
  let sender: WorkerName
  let source_id: RoutingId
  let target_id: RoutingId
  let connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, source_id': RoutingId,
    target_id': RoutingId, connection_round': ConnectionRound)
  =>
    sender = sender'
    source_id = source_id'
    target_id = target_id'
    connection_round = connection_round'

class val UnregisterProducerMsg is ChannelMsg
  let sender: WorkerName
  let source_id: RoutingId
  let target_id: RoutingId
  let connection_round: ConnectionRound

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, source_id': RoutingId,
    target_id': RoutingId, connection_round': ConnectionRound)
  =>
    sender = sender'
    source_id = source_id'
    target_id = target_id'
    connection_round = connection_round'

class val ReportStatusMsg is ChannelMsg
  let code: ReportStatusCode

  fun val string(): String => __loc.type_name()
  new val create(c: ReportStatusCode) =>
    code = c

class val WorkerStateEntityCountRequestMsg is ChannelMsg
  let requester: WorkerName
  let request_id: RequestId

  fun val string(): String => __loc.type_name()
  new val create(requester': WorkerName, request_id': RequestId) =>
    requester = requester'
    request_id = request_id'

class val WorkerStateEntityCountResponseMsg is ChannelMsg
  let worker_name: WorkerName
  let request_id: RequestId
  let state_entity_count_json: String

  fun val string(): String => __loc.type_name()
  new val create(worker_name': WorkerName, request_id': RequestId,
    state_entity_count_json': String)
  =>
    worker_name = worker_name'
    request_id = request_id'
    state_entity_count_json = state_entity_count_json'

class val TryShrinkRequestMsg is ChannelMsg
  let target_workers: Array[WorkerName] val
  let shrink_count: U64
  let worker_name: WorkerName
  let conn_id: U128

  fun val string(): String => __loc.type_name()
  new val create(target_workers': Array[WorkerName] val, shrink_count': U64,
    worker_name': WorkerName, conn_id': U128)
  =>
    target_workers = target_workers'
    shrink_count = shrink_count'
    worker_name = worker_name'
    conn_id = conn_id'

class val TryShrinkResponseMsg is ChannelMsg
  let msg: Array[ByteSeq] val
  let conn_id: U128

  fun val string(): String => __loc.type_name()
  new val create(msg': Array[ByteSeq] val, conn_id': U128) =>
    msg = msg'
    conn_id = conn_id'

class val TryJoinRequestMsg is ChannelMsg
  let joining_worker_name: WorkerName
  let worker_count: USize
  let proxy_worker_name: WorkerName
  let conn_id: U128

  fun val string(): String => __loc.type_name()
  new val create(joining_worker_name': WorkerName, worker_count': USize,
    proxy_worker_name': WorkerName, conn_id': U128)
  =>
    joining_worker_name = joining_worker_name'
    worker_count = worker_count'
    proxy_worker_name = proxy_worker_name'
    conn_id = conn_id'

class val TryJoinResponseMsg is ChannelMsg
  let msg: Array[ByteSeq] val
  let conn_id: U128

  fun val string(): String => __loc.type_name()
  new val create(msg': Array[ByteSeq] val, conn_id': U128) =>
    msg = msg'
    conn_id = conn_id'

class val InitiatePausingCheckpointMsg is ChannelMsg
  let sender: WorkerName
  let id: U128

  fun val string(): String => __loc.type_name()
  new val create(sender': WorkerName, id': U128) =>
    sender = sender'
    id = id'

class val PausingCheckpointInitiatedMsg is ChannelMsg
  let id: U128

  fun val string(): String => __loc.type_name()
  new val create(id': U128) =>
    id = id'

primitive RestartRepeatingCheckpointsMsg is ChannelMsg
  fun val string(): String => __loc.type_name()

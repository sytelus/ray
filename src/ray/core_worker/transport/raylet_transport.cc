
#include "ray/core_worker/transport/raylet_transport.h"
#include "ray/common/common_protocol.h"
#include "ray/common/task/task.h"

namespace ray {

CoreWorkerRayletTaskReceiver::CoreWorkerRayletTaskReceiver(
    WorkerContext &worker_context, std::unique_ptr<RayletClient> &raylet_client,
    boost::asio::io_service &io_service, rpc::GrpcServer &server,
    const TaskHandler &task_handler)
    : worker_context_(worker_context),
      raylet_client_(raylet_client),
      task_service_(io_service, *this),
      task_handler_(task_handler) {
  server.RegisterService(task_service_);
}

void CoreWorkerRayletTaskReceiver::HandleAssignTask(
    const rpc::AssignTaskRequest &request, rpc::AssignTaskReply *reply,
    rpc::SendReplyCallback send_reply_callback) {
  const Task task(request.task());
  const auto &task_spec = task.GetTaskSpecification();
  RAY_LOG(DEBUG) << "Received task " << task_spec.TaskId();
  if (task_spec.IsActorTask() && worker_context_.CurrentActorUseDirectCall()) {
    send_reply_callback(Status::Invalid("This actor only accepts direct calls."), nullptr,
                        nullptr);
    return;
  }

  // Set the resource IDs for this task.
  // TODO: convert the resource map to protobuf and change this.
  ResourceMappingType resource_ids;
  auto resource_infos =
      flatbuffers::GetRoot<protocol::ResourceIdSetInfos>(request.resource_ids().data())
          ->resource_infos();
  for (size_t i = 0; i < resource_infos->size(); ++i) {
    auto const &fractional_resource_ids = resource_infos->Get(i);
    auto &acquired_resources =
        resource_ids[string_from_flatbuf(*fractional_resource_ids->resource_name())];

    size_t num_resource_ids = fractional_resource_ids->resource_ids()->size();
    size_t num_resource_fractions = fractional_resource_ids->resource_fractions()->size();
    RAY_CHECK(num_resource_ids == num_resource_fractions);
    RAY_CHECK(num_resource_ids > 0);
    for (size_t j = 0; j < num_resource_ids; ++j) {
      int64_t resource_id = fractional_resource_ids->resource_ids()->Get(j);
      double resource_fraction = fractional_resource_ids->resource_fractions()->Get(j);
      if (num_resource_ids > 1) {
        int64_t whole_fraction = resource_fraction;
        RAY_CHECK(whole_fraction == resource_fraction);
      }
      acquired_resources.push_back(std::make_pair(resource_id, resource_fraction));
    }
  }

  std::vector<std::shared_ptr<RayObject>> results;
  auto status = task_handler_(task_spec, resource_ids, &results);

  auto num_returns = task_spec.NumReturns();
  if (task_spec.IsActorCreationTask() || task_spec.IsActorTask()) {
    RAY_CHECK(num_returns > 0);
    // Decrease to account for the dummy object id.
    num_returns--;
  }

  RAY_LOG(DEBUG) << "Assigned task " << task_spec.TaskId()
                 << " finished execution. num_returns: " << num_returns;

  // Notify raylet that current task is done via a `TaskDone` message. This is to
  // ensure that the task is marked as finished by raylet only after previous
  // raylet client calls are completed. For example, if the worker sends a
  // NotifyUnblocked message that it is no longer blocked in a `ray.get`
  // on the normal raylet socket, then completes an assigned task, we
  // need to guarantee that raylet gets the former message first before
  // marking the task as completed. This is why a `TaskDone` message
  // is required - without it, it's possible that raylet receives
  // rpc reply first before the NotifyUnblocked message arrives,
  // as they use different connections, the `TaskDone` message is sent
  // to raylet via the same connection so the order is guaranteed.
  RAY_UNUSED(raylet_client_->TaskDone());
  // Send rpc reply.
  send_reply_callback(status, nullptr, nullptr);
}

}  // namespace ray

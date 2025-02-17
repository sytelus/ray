# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cpython.exc cimport PyErr_CheckSignals

import numpy
import time
import logging
import os
import sys

from libc.stdint cimport (
    int32_t,
    int64_t,
    INT64_MAX,
    uint64_t,
    uint8_t,
)
from libcpp cimport bool as c_bool
from libcpp.memory cimport (
    dynamic_pointer_cast,
    make_shared,
    shared_ptr,
    unique_ptr,
)
from libcpp.string cimport string as c_string
from libcpp.utility cimport pair
from libcpp.unordered_map cimport unordered_map
from libcpp.vector cimport vector as c_vector

from cython.operator import dereference, postincrement

from ray.includes.common cimport (
    CLanguage,
    CRayObject,
    CRayStatus,
    CGcsClientOptions,
    CTaskArg,
    CTaskType,
    CRayFunction,
    LocalMemoryBuffer,
    move,
    LANGUAGE_CPP,
    LANGUAGE_JAVA,
    LANGUAGE_PYTHON,
    LocalMemoryBuffer,
    TASK_TYPE_NORMAL_TASK,
    TASK_TYPE_ACTOR_CREATION_TASK,
    TASK_TYPE_ACTOR_TASK,
    WORKER_TYPE_WORKER,
    WORKER_TYPE_DRIVER,
)
from ray.includes.libraylet cimport (
    CRayletClient,
    GCSProfileEvent,
    GCSProfileTableData,
    WaitResultPair,
)
from ray.includes.unique_ids cimport (
    CActorID,
    CActorCheckpointID,
    CObjectID,
    CClientID,
)
from ray.includes.libcoreworker cimport (
    CActorCreationOptions,
    CCoreWorker,
    CTaskOptions,
    ResourceMappingType,
)
from ray.includes.task cimport CTaskSpec
from ray.includes.ray_config cimport RayConfig

import ray
import ray.experimental.signal as ray_signal
import ray.memory_monitor as memory_monitor
import ray.ray_constants as ray_constants
from ray import profiling
from ray.exceptions import (
    RayError,
    RayletError,
    RayTaskError,
    ObjectStoreFullError
)
from ray.function_manager import FunctionDescriptor
from ray.utils import decode
from ray.ray_constants import (
    DEFAULT_PUT_OBJECT_DELAY,
    DEFAULT_PUT_OBJECT_RETRIES,
    RAW_BUFFER_METADATA,
    PICKLE5_BUFFER_METADATA,
)

# pyarrow cannot be imported until after _raylet finishes initializing
# (see ray/__init__.py for details).
# Unfortunately, Cython won't compile if 'pyarrow' is undefined, so we
# "forward declare" it here and then replace it with a reference to the
# imported package from ray/__init__.py.
# TODO(edoakes): Fix this.
pyarrow = None

cimport cpython

include "includes/unique_ids.pxi"
include "includes/ray_config.pxi"
include "includes/task.pxi"
include "includes/buffer.pxi"
include "includes/common.pxi"
include "includes/serialization.pxi"
include "includes/libcoreworker.pxi"


logger = logging.getLogger(__name__)


if cpython.PY_MAJOR_VERSION >= 3:
    import pickle
else:
    import cPickle as pickle


cdef int check_status(const CRayStatus& status) nogil except -1:
    if status.ok():
        return 0

    with gil:
        message = status.message().decode()

    if status.IsObjectStoreFull():
        raise ObjectStoreFullError(message)
    elif status.IsInterrupted():
        raise KeyboardInterrupt()
    else:
        raise RayletError(message)

cdef RayObjectsToDataMetadataPairs(
        const c_vector[shared_ptr[CRayObject]] objects):
    data_metadata_pairs = []
    for i in range(objects.size()):
        # core_worker will return a nullptr for objects that couldn't be
        # retrieved from the store or if an object was an exception.
        if not objects[i].get():
            data_metadata_pairs.append((None, None))
        else:
            data = None
            metadata = None
            if objects[i].get().HasData():
                data = Buffer.make(objects[i].get().GetData())
            if objects[i].get().HasMetadata():
                metadata = Buffer.make(
                    objects[i].get().GetMetadata()).to_pybytes()
            data_metadata_pairs.append((data, metadata))
    return data_metadata_pairs


cdef VectorToObjectIDs(const c_vector[CObjectID] &object_ids):
    result = []
    for i in range(object_ids.size()):
        result.append(ObjectID(object_ids[i].Binary()))
    return result


cdef c_vector[CObjectID] ObjectIDsToVector(object_ids):
    """A helper function that converts a Python list of object IDs to a vector.

    Args:
        object_ids (list): The Python list of object IDs.

    Returns:
        The output vector.
    """
    cdef:
        ObjectID object_id
        c_vector[CObjectID] result
    for object_id in object_ids:
        result.push_back(object_id.native())
    return result


def compute_task_id(ObjectID object_id):
    return TaskID(object_id.native().TaskId().Binary())


cdef c_bool is_simple_value(value, int64_t *num_elements_contained):
    num_elements_contained[0] += 1

    if num_elements_contained[0] >= RayConfig.instance().num_elements_limit():
        return False

    if (cpython.PyInt_Check(value) or cpython.PyLong_Check(value) or
            value is False or value is True or cpython.PyFloat_Check(value) or
            value is None):
        return True

    if cpython.PyBytes_CheckExact(value):
        num_elements_contained[0] += cpython.PyBytes_Size(value)
        return (num_elements_contained[0] <
                RayConfig.instance().num_elements_limit())

    if cpython.PyUnicode_CheckExact(value):
        num_elements_contained[0] += cpython.PyUnicode_GET_SIZE(value)
        return (num_elements_contained[0] <
                RayConfig.instance().num_elements_limit())

    if (cpython.PyList_CheckExact(value) and
            cpython.PyList_Size(value) < RayConfig.instance().size_limit()):
        for item in value:
            if not is_simple_value(item, num_elements_contained):
                return False
        return (num_elements_contained[0] <
                RayConfig.instance().num_elements_limit())

    if (cpython.PyDict_CheckExact(value) and
            cpython.PyDict_Size(value) < RayConfig.instance().size_limit()):
        # TODO(suquark): Using "items" in Python2 is not very efficient.
        for k, v in value.items():
            if not (is_simple_value(k, num_elements_contained) and
                    is_simple_value(v, num_elements_contained)):
                return False
        return (num_elements_contained[0] <
                RayConfig.instance().num_elements_limit())

    if (cpython.PyTuple_CheckExact(value) and
            cpython.PyTuple_Size(value) < RayConfig.instance().size_limit()):
        for item in value:
            if not is_simple_value(item, num_elements_contained):
                return False
        return (num_elements_contained[0] <
                RayConfig.instance().num_elements_limit())

    if isinstance(value, numpy.ndarray):
        if value.dtype == "O":
            return False
        num_elements_contained[0] += value.nbytes
        return (num_elements_contained[0] <
                RayConfig.instance().num_elements_limit())

    return False


def check_simple_value(value):
    """Check if value is simple enough to be send by value.

    This method checks if a Python object is sufficiently simple that it can
    be serialized and passed by value as an argument to a task (without being
    put in the object store). The details of which objects are sufficiently
    simple are defined by this method and are not particularly important.
    But for performance reasons, it is better to place "small" objects in
    the task itself and "large" objects in the object store.

    Args:
        value: Python object that should be checked.

    Returns:
        True if the value should be send by value, False otherwise.
    """

    cdef int64_t num_elements_contained = 0
    return is_simple_value(value, &num_elements_contained)


cdef class Language:
    cdef CLanguage lang

    def __cinit__(self, int32_t lang):
        self.lang = <CLanguage>lang

    @staticmethod
    cdef from_native(const CLanguage& lang):
        return Language(<int32_t>lang)

    def __eq__(self, other):
        return (isinstance(other, Language) and
                (<int32_t>self.lang) == (<int32_t>other.lang))

    def __repr__(self):
        if <int32_t>self.lang == <int32_t>LANGUAGE_PYTHON:
            return "PYTHON"
        elif <int32_t>self.lang == <int32_t>LANGUAGE_CPP:
            return "CPP"
        elif <int32_t>self.lang == <int32_t>LANGUAGE_JAVA:
            return "JAVA"
        else:
            raise Exception("Unexpected error")


# Programming language enum values.
cdef Language LANG_PYTHON = Language.from_native(LANGUAGE_PYTHON)
cdef Language LANG_CPP = Language.from_native(LANGUAGE_CPP)
cdef Language LANG_JAVA = Language.from_native(LANGUAGE_JAVA)


cdef int prepare_resources(
        dict resource_dict,
        unordered_map[c_string, double] *resource_map) except -1:
    cdef:
        unordered_map[c_string, double] out
        c_string resource_name

    if resource_dict is None:
        raise ValueError("Must provide resource map.")

    for key, value in resource_dict.items():
        if not (isinstance(value, int) or isinstance(value, float)):
            raise ValueError("Resource quantities may only be ints or floats.")
        if value < 0:
            raise ValueError("Resource quantities may not be negative.")
        if value > 0:
            if (value >= 1 and isinstance(value, float)
                    and not value.is_integer()):
                raise ValueError(
                    "Resource quantities >1 must be whole numbers.")
            resource_map[0][key.encode("ascii")] = float(value)
    return 0


cdef c_vector[c_string] string_vector_from_list(list string_list):
    cdef:
        c_vector[c_string] out
    for s in string_list:
        if not isinstance(s, bytes):
            raise TypeError("string_list elements must be bytes")
        out.push_back(s)
    return out


cdef void prepare_args(list args, c_vector[CTaskArg] *args_vector):
    cdef:
        c_string pickled_str
        shared_ptr[CBuffer] arg_data
        shared_ptr[CBuffer] arg_metadata

    for arg in args:
        if isinstance(arg, ObjectID):
            args_vector.push_back(
                CTaskArg.PassByReference((<ObjectID>arg).native()))
        elif not ray._raylet.check_simple_value(arg):
            args_vector.push_back(
                CTaskArg.PassByReference((<ObjectID>ray.put(arg)).native()))
        else:
            pickled_str = pickle.dumps(
                arg, protocol=pickle.HIGHEST_PROTOCOL)
            # TODO(edoakes): This makes a copy that could be avoided.
            arg_data = dynamic_pointer_cast[CBuffer, LocalMemoryBuffer](
                    make_shared[LocalMemoryBuffer](
                        <uint8_t*>(pickled_str.data()),
                        pickled_str.size(),
                        True))
            args_vector.push_back(
                CTaskArg.PassByValue(
                    make_shared[CRayObject](arg_data, arg_metadata)))


cdef class RayletClient:
    cdef CRayletClient* client

    def __cinit__(self, CoreWorker core_worker):
        # The core worker and raylet client need to share an underlying
        # raylet client, so we take a reference to the core worker's client
        # here. The client is a raw pointer because it is only a temporary
        # workaround and will be removed once the core worker transition is
        # complete, so we don't want to change the unique_ptr in core worker
        # to a shared_ptr. This means the core worker *must* be
        # initialized before the raylet client.
        self.client = &core_worker.core_worker.get().GetRayletClient()

    def fetch_or_reconstruct(self, object_ids,
                             c_bool fetch_only,
                             TaskID current_task_id=TaskID.nil()):
        cdef c_vector[CObjectID] fetch_ids = ObjectIDsToVector(object_ids)
        check_status(self.client.FetchOrReconstruct(
            fetch_ids, fetch_only, current_task_id.native()))

    def push_error(self, JobID job_id, error_type, error_message,
                   double timestamp):
        check_status(self.client.PushError(job_id.native(),
                                           error_type.encode("ascii"),
                                           error_message.encode("ascii"),
                                           timestamp))

    def prepare_actor_checkpoint(self, ActorID actor_id):
        cdef:
            CActorCheckpointID checkpoint_id
            CActorID c_actor_id = actor_id.native()

        # PrepareActorCheckpoint will wait for raylet's reply, release
        # the GIL so other Python threads can run.
        with nogil:
            check_status(self.client.PrepareActorCheckpoint(
                c_actor_id, checkpoint_id))
        return ActorCheckpointID(checkpoint_id.Binary())

    def notify_actor_resumed_from_checkpoint(self, ActorID actor_id,
                                             ActorCheckpointID checkpoint_id):
        check_status(self.client.NotifyActorResumedFromCheckpoint(
            actor_id.native(), checkpoint_id.native()))

    def set_resource(self, basestring resource_name,
                     double capacity, ClientID client_id):
        self.client.SetResource(resource_name.encode("ascii"), capacity,
                                CClientID.FromBinary(client_id.binary()))

    @property
    def job_id(self):
        return JobID(self.client.GetJobID().Binary())

    @property
    def is_worker(self):
        return self.client.IsWorker()

cdef deserialize_args(
        const c_vector[shared_ptr[CRayObject]] &c_args,
        const c_vector[CObjectID] &arg_reference_ids):
    cdef:
        c_vector[shared_ptr[CRayObject]] by_reference_objects

    if c_args.size() == 0:
        return [], {}

    args = []
    by_reference_ids = []
    by_reference_indices = []
    for i in range(c_args.size()):
        # Passed by value.
        if arg_reference_ids[i].IsNil():
            data = Buffer.make(c_args[i].get().GetData())
            if (c_args[i].get().HasMetadata()
                and Buffer.make(
                    c_args[i].get().GetMetadata()).to_pybytes()
                    == RAW_BUFFER_METADATA):
                args.append(data)
            else:
                args.append(pickle.loads(data.to_pybytes()))
        # Passed by reference.
        else:
            by_reference_ids.append(
                ObjectID(arg_reference_ids[i].Binary()))
            by_reference_indices.append(i)
            by_reference_objects.push_back(c_args[i])
            args.append(None)

    data_metadata_pairs = RayObjectsToDataMetadataPairs(
        by_reference_objects)
    for i, arg in enumerate(
        ray.worker.global_worker.deserialize_objects(
            data_metadata_pairs, by_reference_ids)):
        args[by_reference_indices[i]] = arg

    for arg in args:
        if isinstance(arg, RayError):
            raise arg

    return ray.signature.recover_args(args)


cdef _store_task_outputs(
        worker, return_ids, outputs,
        c_bool return_outputs_directly,
        c_vector[shared_ptr[CRayObject]] *returns):

    # Direct actor call returns are not placed in the object store directly,
    # but returned to the core worker.
    if return_outputs_directly:
        return_buffer = []
    else:
        return_buffer = None

    for i in range(len(return_ids)):
        return_id, output = return_ids[i], outputs[i]
        if isinstance(output, ray.actor.ActorHandle):
            raise Exception("Returning an actor handle from a remote "
                            "function is not allowed).")
        if output is ray.experimental.no_return.NoReturn:
            if not worker.core_worker.object_exists(return_id):
                raise RuntimeError(
                    "Attempting to return 'ray.experimental.NoReturn' "
                    "from a remote function, but the corresponding "
                    "ObjectID does not exist in the local object store.")
        else:
            worker.put_object(
                output, object_id=return_id, return_buffer=return_buffer)

    if return_outputs_directly:
        assert len(return_ids) == len(return_buffer), \
            (return_ids, return_buffer)
        push_objects_into_return_vector(return_buffer, returns)


cdef execute_task(
        CTaskType task_type,
        const CRayFunction &ray_function,
        const unordered_map[c_string, double] &c_resources,
        const c_vector[shared_ptr[CRayObject]] &c_args,
        const c_vector[CObjectID] &c_arg_reference_ids,
        const c_vector[CObjectID] &c_return_ids,
        c_bool return_outputs_directly,
        c_vector[shared_ptr[CRayObject]] *returns):

    worker = ray.worker.global_worker
    manager = worker.function_actor_manager

    cdef:
        dict execution_infos = manager.execution_infos
        CoreWorker core_worker = worker.core_worker
        JobID job_id = core_worker.get_current_job_id()
        CTaskID task_id = core_worker.core_worker.get().GetCurrentTaskId()

    # Automatically restrict the GPUs available to this task.
    ray.utils.set_cuda_visible_devices(ray.get_gpu_ids())

    descriptor = tuple(ray_function.GetFunctionDescriptor())

    if <int>task_type == <int>TASK_TYPE_ACTOR_CREATION_TASK:
        function_descriptor = FunctionDescriptor.from_bytes_list(
            ray_function.GetFunctionDescriptor())
        actor_class = manager.load_actor_class(job_id, function_descriptor)
        actor_id = core_worker.get_actor_id()
        worker.actors[actor_id] = actor_class.__new__(actor_class)
        worker.actor_checkpoint_info[actor_id] = (
            ray.worker.ActorCheckpointInfo(
                num_tasks_since_last_checkpoint=0,
                last_checkpoint_timestamp=int(1000 * time.time()),
                checkpoint_ids=[]))

    execution_info = execution_infos.get(descriptor)
    if not execution_info:
        function_descriptor = FunctionDescriptor.from_bytes_list(
            ray_function.GetFunctionDescriptor())
        execution_info = manager.get_execution_info(
            job_id, function_descriptor)
        execution_infos[descriptor] = execution_info

    function_name = execution_info.function_name
    extra_data = (b'{"name": ' + function_name.encode("ascii") +
                  b' "task_id": ' + task_id.Hex() + b'}')

    if <int>task_type == <int>TASK_TYPE_NORMAL_TASK:
        title = "ray_worker:{}()".format(function_name)
        next_title = "ray_worker"
        function_executor = execution_info.function
    else:
        actor = worker.actors[core_worker.get_actor_id()]
        class_name = actor.__class__.__name__
        title = "ray_{}:{}()".format(class_name, function_name)
        next_title = "ray_{}".format(class_name)
        worker_name = "ray_{}_{}".format(class_name, os.getpid())
        if c_resources.find(b"memory") != c_resources.end():
            worker.memory_monitor.set_heap_limit(
                worker_name,
                ray_constants.from_memory_units(
                    dereference(c_resources.find(b"memory")).second))
        if c_resources.find(b"object_store_memory") != c_resources.end():
            worker.core_worker.set_object_store_client_options(
                worker_name,
                int(ray_constants.from_memory_units(
                        dereference(
                            c_resources.find(b"object_store_memory")).second)))

        def function_executor(*arguments, **kwarguments):
            return execution_info.function(actor, *arguments, **kwarguments)

    return_ids = VectorToObjectIDs(c_return_ids)
    with core_worker.profile_event(b"task", extra_data=extra_data):
        try:
            task_exception = False
            if not (<int>task_type == <int>TASK_TYPE_ACTOR_TASK
                    and function_name == "__ray_terminate__"):
                worker.reraise_actor_init_error()
                worker.memory_monitor.raise_if_low_memory()

            with core_worker.profile_event(b"task:deserialize_arguments"):
                args, kwargs = deserialize_args(c_args, c_arg_reference_ids)

            # Execute the task.
            with ray.worker._changeproctitle(title, next_title):
                with core_worker.profile_event(b"task:execute"):
                    task_exception = True
                    outputs = function_executor(*args, **kwargs)
                    task_exception = False
                    if len(return_ids) == 1:
                        outputs = (outputs,)

            # Store the outputs in the object store.
            with core_worker.profile_event(b"task:store_outputs"):
                _store_task_outputs(
                    worker, return_ids, outputs, return_outputs_directly,
                    returns)
        except Exception as error:
            if (<int>task_type == <int>TASK_TYPE_ACTOR_CREATION_TASK):
                worker.mark_actor_init_failed(error)

            backtrace = ray.utils.format_error_message(
                traceback.format_exc(), task_exception=task_exception)
            if isinstance(error, RayTaskError):
                # Avoid recursive nesting of RayTaskError.
                failure_object = RayTaskError(function_name, backtrace,
                                              error.cause_cls)
            else:
                failure_object = RayTaskError(function_name, backtrace,
                                              error.__class__)
            _store_task_outputs(
                worker, return_ids, [failure_object] * len(return_ids),
                return_outputs_directly, returns)
            ray.utils.push_error_to_driver(
                worker,
                ray_constants.TASK_PUSH_ERROR,
                str(failure_object),
                job_id=worker.current_job_id)

            # Send signal with the error.
            ray_signal.send(ray_signal.ErrorSignal(str(failure_object)))

    # Don't need to reset `current_job_id` if the worker is an
    # actor. Because the following tasks should all have the
    # same driver id.
    if <int>task_type == <int>TASK_TYPE_NORMAL_TASK:
        # Reset signal counters so that the next task can get
        # all past signals.
        ray_signal.reset()

    if execution_info.max_calls != 0:
        function_descriptor = FunctionDescriptor.from_bytes_list(
            ray_function.GetFunctionDescriptor())

        # Reset the state of the worker for the next task to execute.
        # Increase the task execution counter.
        manager.increase_task_counter(job_id, function_descriptor)

        # If we've reached the max number of executions for this worker, exit.
        task_counter = manager.get_task_counter(job_id, function_descriptor)
        if task_counter == execution_info.max_calls:
            worker.core_worker.disconnect()
            sys.exit(0)


cdef CRayStatus task_execution_handler(
        CTaskType task_type,
        const CRayFunction &ray_function,
        const unordered_map[c_string, double] &c_resources,
        const c_vector[shared_ptr[CRayObject]] &c_args,
        const c_vector[CObjectID] &c_arg_reference_ids,
        const c_vector[CObjectID] &c_return_ids,
        c_bool return_results_directly,
        c_vector[shared_ptr[CRayObject]] *returns) nogil:

    with gil:
        try:
            # The call to execute_task should never raise an exception. If it
            # does, that indicates that there was an unexpected internal error.
            execute_task(task_type, ray_function, c_resources, c_args,
                         c_arg_reference_ids, c_return_ids,
                         return_results_directly, returns)
        except Exception:
            traceback_str = traceback.format_exc() + (
                "An unexpected internal error occurred while the worker was"
                "executing a task.")
            ray.utils.push_error_to_driver(
                ray.worker.global_worker,
                "worker_crash",
                traceback_str,
                job_id=None)
            # TODO(rkn): Note that if the worker was in the middle of executing
            # a task, then any worker or driver that is blocking in a get call
            # and waiting for the output of that task will hang. We need to
            # address this.
            sys.exit(1)

    return CRayStatus.OK()

cdef CRayStatus check_signals() nogil:
    with gil:
        try:
            PyErr_CheckSignals()
        except KeyboardInterrupt:
            return CRayStatus.Interrupted(b"")
    return CRayStatus.OK()


cdef void push_objects_into_return_vector(
        py_objects,
        c_vector[shared_ptr[CRayObject]] *returns):

    cdef:
        c_string metadata_str = RAW_BUFFER_METADATA
        c_string raw_data_str
        shared_ptr[CBuffer] data
        shared_ptr[CBuffer] metadata
        shared_ptr[CRayObject] ray_object
        int64_t data_size

    for serialized_object in py_objects:
        if isinstance(serialized_object, bytes):
            data_size = len(serialized_object)
            raw_data_str = serialized_object
            data = dynamic_pointer_cast[
                CBuffer, LocalMemoryBuffer](
                    make_shared[LocalMemoryBuffer](
                        <uint8_t*>(raw_data_str.data()), raw_data_str.size()))
            metadata = dynamic_pointer_cast[
                CBuffer, LocalMemoryBuffer](
                    make_shared[LocalMemoryBuffer](
                        <uint8_t*>(metadata_str.data()), metadata_str.size()))
            ray_object = make_shared[CRayObject](data, metadata, True)
            returns.push_back(ray_object)
        else:
            data_size = serialized_object.total_bytes
            data = dynamic_pointer_cast[
                CBuffer, LocalMemoryBuffer](
                    make_shared[LocalMemoryBuffer](data_size))
            metadata.reset()
            stream = pyarrow.FixedSizeBufferWriter(
                pyarrow.py_buffer(Buffer.make(data)))
            serialized_object.write_to(stream)
            ray_object = make_shared[CRayObject](data, metadata)
            returns.push_back(ray_object)


cdef class CoreWorker:
    cdef unique_ptr[CCoreWorker] core_worker

    def __cinit__(self, is_driver, store_socket, raylet_socket,
                  JobID job_id, GcsClientOptions gcs_options, log_dir,
                  node_ip_address):
        assert pyarrow is not None, ("Expected pyarrow to be imported from "
                                     "outside _raylet. See __init__.py for "
                                     "details.")

        self.core_worker.reset(new CCoreWorker(
            WORKER_TYPE_DRIVER if is_driver else WORKER_TYPE_WORKER,
            LANGUAGE_PYTHON, store_socket.encode("ascii"),
            raylet_socket.encode("ascii"), job_id.native(),
            gcs_options.native()[0], log_dir.encode("utf-8"),
            node_ip_address.encode("utf-8"), task_execution_handler,
            check_signals))

    def disconnect(self):
        with nogil:
            self.core_worker.get().Disconnect()

    def run_task_loop(self):
        with nogil:
            self.core_worker.get().StartExecutingTasks()

    def get_current_task_id(self):
        return TaskID(self.core_worker.get().GetCurrentTaskId().Binary())

    def get_current_job_id(self):
        return JobID(self.core_worker.get().GetCurrentJobId().Binary())

    def get_actor_id(self):
        return ActorID(self.core_worker.get().GetActorId().Binary())

    def get_objects(self, object_ids, TaskID current_task_id,
                    int64_t timeout_ms=-1):
        cdef:
            c_vector[shared_ptr[CRayObject]] results
            CTaskID c_task_id = current_task_id.native()
            c_vector[CObjectID] c_object_ids = ObjectIDsToVector(object_ids)

        with nogil:
            check_status(self.core_worker.get().Get(
                c_object_ids, timeout_ms, &results))

        return RayObjectsToDataMetadataPairs(results)

    def object_exists(self, ObjectID object_id):
        cdef:
            c_bool has_object
            CObjectID c_object_id = object_id.native()

        with nogil:
            check_status(self.core_worker.get().Contains(
                c_object_id, &has_object))

        return has_object

    cdef _create_put_buffer(self, shared_ptr[CBuffer] &metadata,
                            size_t data_size, ObjectID object_id,
                            CObjectID *c_object_id, shared_ptr[CBuffer] *data):
        delay = ray_constants.DEFAULT_PUT_OBJECT_DELAY
        for attempt in reversed(
                range(ray_constants.DEFAULT_PUT_OBJECT_RETRIES)):
            try:
                if object_id is None:
                    with nogil:
                        check_status(self.core_worker.get().Create(
                                    metadata, data_size, c_object_id, data))
                else:
                    c_object_id[0] = object_id.native()
                    with nogil:
                        check_status(self.core_worker.get().Create(
                                    metadata, data_size, c_object_id[0], data))
                break
            except ObjectStoreFullError as e:
                if attempt:
                    logger.warning("Waiting {} seconds for space to free up "
                                   "in the object store.".format(delay))
                    time.sleep(delay)
                    delay *= 2
                else:
                    self.dump_object_store_memory_usage()
                    raise e

        # If data is nullptr, that means the ObjectID already existed,
        # which we ignore.
        # TODO(edoakes): this is hacky, we should return the error instead
        # and deal with it here.
        return data.get() == NULL

    def put_serialized_object(self, serialized_object, ObjectID object_id=None,
                              int memcopy_threads=6):
        cdef:
            CObjectID c_object_id
            shared_ptr[CBuffer] data
            shared_ptr[CBuffer] metadata

        object_already_exists = self._create_put_buffer(
            metadata, serialized_object.total_bytes,
            object_id, &c_object_id, &data)
        if not object_already_exists:
            stream = pyarrow.FixedSizeBufferWriter(
                pyarrow.py_buffer(Buffer.make(data)))
            stream.set_memcopy_threads(memcopy_threads)
            serialized_object.write_to(stream)

            with nogil:
                check_status(
                    self.core_worker.get().Seal(c_object_id))

        return ObjectID(c_object_id.Binary())

    def put_raw_buffer(self, c_string value, ObjectID object_id=None,
                       int memcopy_threads=6):
        cdef:
            c_string metadata_str = RAW_BUFFER_METADATA
            CObjectID c_object_id
            shared_ptr[CBuffer] data
            shared_ptr[CBuffer] metadata = dynamic_pointer_cast[
                CBuffer, LocalMemoryBuffer](
                    make_shared[LocalMemoryBuffer](
                        <uint8_t*>(metadata_str.data()), metadata_str.size()))

        object_already_exists = self._create_put_buffer(
            metadata, value.size(), object_id, &c_object_id, &data)
        if not object_already_exists:
            stream = pyarrow.FixedSizeBufferWriter(
                pyarrow.py_buffer(Buffer.make(data)))
            stream.set_memcopy_threads(memcopy_threads)
            stream.write(pyarrow.py_buffer(value))

            with nogil:
                check_status(
                    self.core_worker.get().Seal(c_object_id))

        return ObjectID(c_object_id.Binary())

    def put_pickle5_buffers(self, c_string inband,
                            Pickle5Writer writer, ObjectID object_id=None,
                            int memcopy_threads=6):
        cdef:
            CObjectID c_object_id
            c_string metadata_str = PICKLE5_BUFFER_METADATA
            shared_ptr[CBuffer] data
            shared_ptr[CBuffer] metadata = dynamic_pointer_cast[
                CBuffer, LocalMemoryBuffer](
                    make_shared[LocalMemoryBuffer](
                        <uint8_t*>(metadata_str.data()), metadata_str.size()))

        object_already_exists = self._create_put_buffer(
            metadata, writer.get_total_bytes(inband),
            object_id, &c_object_id, &data)
        if not object_already_exists:
            writer.write_to(inband, data, memcopy_threads)
            with nogil:
                check_status(
                    self.core_worker.get().Seal(c_object_id))

        return ObjectID(c_object_id.Binary())

    def wait(self, object_ids, int num_returns, int64_t timeout_ms,
             TaskID current_task_id):
        cdef:
            WaitResultPair result
            c_vector[CObjectID] wait_ids
            c_vector[c_bool] results
            CTaskID c_task_id = current_task_id.native()

        wait_ids = ObjectIDsToVector(object_ids)
        with nogil:
            check_status(self.core_worker.get().Wait(
                wait_ids, num_returns, timeout_ms, &results))

        assert len(results) == len(object_ids)

        ready, not_ready = [], []
        for i, object_id in enumerate(object_ids):
            if results[i]:
                ready.append(object_id)
            else:
                not_ready.append(object_id)

        return ready, not_ready

    def free_objects(self, object_ids, c_bool local_only,
                     c_bool delete_creating_tasks):
        cdef:
            c_vector[CObjectID] free_ids = ObjectIDsToVector(object_ids)

        with nogil:
            check_status(self.core_worker.get().Delete(
                free_ids, local_only, delete_creating_tasks))

    def set_object_store_client_options(self, client_name,
                                        int64_t limit_bytes):
        try:
            logger.debug("Setting plasma memory limit to {} for {}".format(
                limit_bytes, client_name))
            check_status(self.core_worker.get().SetClientOptions(
                client_name.encode("ascii"), limit_bytes))
        except RayError as e:
            self.dump_object_store_memory_usage()
            raise memory_monitor.RayOutOfMemoryError(
                "Failed to set object_store_memory={} for {}. The "
                "plasma store may have insufficient memory remaining "
                "to satisfy this limit (30% of object store memory is "
                "permanently reserved for shared usage). The current "
                "object store memory status is:\n\n{}".format(
                    limit_bytes, client_name, e))

    def dump_object_store_memory_usage(self):
        message = self.core_worker.get().MemoryUsageString()
        logger.warning("Local object store memory usage:\n{}\n".format(
            message.decode("utf-8")))

    def submit_task(self,
                    function_descriptor,
                    args,
                    int num_return_vals,
                    resources):
        cdef:
            unordered_map[c_string, double] c_resources
            CTaskOptions task_options
            CRayFunction ray_function
            c_vector[CTaskArg] args_vector
            c_vector[CObjectID] return_ids

        with self.profile_event(b"submit_task"):
            prepare_resources(resources, &c_resources)
            task_options = CTaskOptions(num_return_vals, c_resources)
            ray_function = CRayFunction(
                LANGUAGE_PYTHON, string_vector_from_list(function_descriptor))
            prepare_args(args, &args_vector)

            with nogil:
                check_status(self.core_worker.get().SubmitTask(
                    ray_function, args_vector, task_options, &return_ids))

            return VectorToObjectIDs(return_ids)

    def create_actor(self,
                     function_descriptor,
                     args,
                     uint64_t max_reconstructions,
                     resources,
                     placement_resources,
                     c_bool is_direct_call,
                     c_bool is_detached):
        cdef:
            CRayFunction ray_function
            c_vector[CTaskArg] args_vector
            c_vector[c_string] dynamic_worker_options
            unordered_map[c_string, double] c_resources
            unordered_map[c_string, double] c_placement_resources
            CActorID c_actor_id

        with self.profile_event(b"submit_task"):
            prepare_resources(resources, &c_resources)
            prepare_resources(placement_resources, &c_placement_resources)
            ray_function = CRayFunction(
                LANGUAGE_PYTHON, string_vector_from_list(function_descriptor))
            prepare_args(args, &args_vector)

            with nogil:
                check_status(self.core_worker.get().CreateActor(
                    ray_function, args_vector,
                    CActorCreationOptions(
                        max_reconstructions, is_direct_call, c_resources,
                        c_placement_resources, dynamic_worker_options,
                        is_detached),
                    &c_actor_id))

            return ActorID(c_actor_id.Binary())

    def submit_actor_task(self,
                          ActorID actor_id,
                          function_descriptor,
                          args,
                          int num_return_vals,
                          double num_method_cpus):

        cdef:
            CActorID c_actor_id = actor_id.native()
            unordered_map[c_string, double] c_resources
            CTaskOptions task_options
            CRayFunction ray_function
            c_vector[CTaskArg] args_vector
            c_vector[CObjectID] return_ids

        with self.profile_event(b"submit_task"):
            if num_method_cpus > 0:
                c_resources[b"CPU"] = num_method_cpus
            task_options = CTaskOptions(num_return_vals, c_resources)
            ray_function = CRayFunction(
                LANGUAGE_PYTHON, string_vector_from_list(function_descriptor))
            prepare_args(args, &args_vector)

            with nogil:
                check_status(self.core_worker.get().SubmitActorTask(
                      c_actor_id,
                      ray_function,
                      args_vector, task_options, &return_ids))

            return VectorToObjectIDs(return_ids)

    def resource_ids(self):
        cdef:
            ResourceMappingType resource_mapping = (
                self.core_worker.get().GetResourceIDs())
            unordered_map[
                c_string, c_vector[pair[int64_t, double]]
            ].iterator iterator = resource_mapping.begin()
            c_vector[pair[int64_t, double]] c_value

        resources_dict = {}
        while iterator != resource_mapping.end():
            key = decode(dereference(iterator).first)
            c_value = dereference(iterator).second
            ids_and_fractions = []
            for i in range(c_value.size()):
                ids_and_fractions.append(
                    (c_value[i].first, c_value[i].second))
            resources_dict[key] = ids_and_fractions
            postincrement(iterator)

        return resources_dict

    def profile_event(self, c_string event_type, object extra_data=None):
        return ProfileEvent.make(
            self.core_worker.get().CreateProfileEvent(event_type),
            extra_data)

    def deserialize_and_register_actor_handle(self, const c_string &bytes):
        c_actor_id = self.core_worker.get().DeserializeAndRegisterActorHandle(
            bytes)
        actor_id = ActorID(c_actor_id.Binary())
        return actor_id

    def serialize_actor_handle(self, ActorID actor_id):
        cdef:
            CActorID c_actor_id = actor_id.native()
            c_string output
        check_status(self.core_worker.get().SerializeActorHandle(
            c_actor_id, &output))
        return output

    def add_active_object_id(self, ObjectID object_id):
        cdef:
            CObjectID c_object_id = object_id.native()
        # Note: faster to not release GIL for short-running op.
        self.core_worker.get().AddActiveObjectID(c_object_id)

    def remove_active_object_id(self, ObjectID object_id):
        cdef:
            CObjectID c_object_id = object_id.native()
        # Note: faster to not release GIL for short-running op.
        self.core_worker.get().RemoveActiveObjectID(c_object_id)

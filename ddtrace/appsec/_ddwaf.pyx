from collections import deque
import sys
from typing import Tuple

import six


if sys.version_info >= (3, 5):
    from typing import Mapping
    from typing import Sequence
else:
    from collections import Mapping, Sequence

from _libddwaf cimport DDWAF_LOG_LEVEL
from _libddwaf cimport DDWAF_OBJ_TYPE
from _libddwaf cimport DDWAF_RET_CODE
from _libddwaf cimport ddwaf_context
from _libddwaf cimport ddwaf_context_destroy
from _libddwaf cimport ddwaf_context_init
from _libddwaf cimport ddwaf_destroy
from _libddwaf cimport ddwaf_get_version
from _libddwaf cimport ddwaf_handle
from _libddwaf cimport ddwaf_init
from _libddwaf cimport ddwaf_object
from _libddwaf cimport ddwaf_required_addresses
from _libddwaf cimport ddwaf_result
from _libddwaf cimport ddwaf_result_free
from _libddwaf cimport ddwaf_run
from _libddwaf cimport ddwaf_set_log_cb
from _libddwaf cimport ddwaf_version
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_Size
from cpython.mem cimport PyMem_Free
from cpython.mem cimport PyMem_Realloc
from cpython.unicode cimport PyUnicode_AsEncodedString
from libc.stdint cimport uint32_t
from libc.stdint cimport uint64_t
from libc.stdint cimport uintptr_t
from libc.string cimport memset


DEFAULT_DDWAF_TIMEOUT_MS=20


cdef extern from "Python.h":
    const char* PyUnicode_AsUTF8AndSize(object o, Py_ssize_t *size)


def version():
    # type: () -> Tuple[int, int, int]
    """Get the version of libddwaf."""
    cdef ddwaf_version version
    ddwaf_get_version(&version)
    return (version.major, version.minor, version.patch)


cdef class _Wrapper(object):
    """
    Wrapper to convert Python objects to ddwaf objects.

    libddwaf represents scalar and composite values using ddwaf objects. This
    wrapper converts Python objects to ddwaf objects by traversing all values
    and their children. By default, the number of objects is limited to avoid
    infinite loops. This limitation can be lifted on trusted data by setting
    `max_objects` to `None`.

    Under the hood, the wrapper uses an array of `ddwaf_object` allocated as a
    single buffer. Objects such as maps or arrays refer to other objects that
    are only part of this buffer. Strings are not copied, they live in the
    Python heap and are referenced by the wrapper to avoid garbage collection.
    """

    cdef ddwaf_object *_ptr
    cdef readonly object _string_refs
    cdef readonly ssize_t _size
    cdef readonly ssize_t _next_idx

    def __init__(self, value, max_objects=5000):
        self._string_refs = []
        self._convert(value, max_objects)

    cdef ssize_t _reserve_obj(self, ssize_t n=1) except -1:
        cdef ssize_t idx, i
        cdef ddwaf_object *ptr
        cdef ddwaf_object *obj

        idx = self._next_idx
        if idx + n > self._size:
            self._size += ((1000 - (n % 1000)) % 1000)
            ptr = <ddwaf_object *> PyMem_Realloc(self._ptr, self._size * sizeof(ddwaf_object))
            if ptr == NULL:
                raise MemoryError
            memset(ptr + idx, 0, (self._size - idx) * sizeof(ddwaf_object))
            if self._ptr != NULL and ptr != self._ptr:
                # we need to patch all array objects because they use pointers to other objects
                for i in range(idx):
                    obj = ptr + i
                    if (obj.type == DDWAF_OBJ_TYPE.DDWAF_OBJ_MAP or obj.type == DDWAF_OBJ_TYPE.DDWAF_OBJ_ARRAY) and obj.array != NULL:
                        obj.array = obj.array - self._ptr + ptr
            self._ptr = ptr
        self._next_idx += n
        return idx

    cdef int _make_string(self, ssize_t idx, object string) except -1:
        cdef const char * ptr
        cdef ssize_t length
        cdef ddwaf_object *obj

        if isinstance(string, six.binary_type):
            ptr = PyBytes_AsString(string)
            length = PyBytes_Size(string)
        elif isinstance(string, six.text_type):
            IF PY_MAJOR_VERSION >= 3:
                ptr = PyUnicode_AsUTF8AndSize(string, &length)
            if ptr == NULL:
                string = PyUnicode_AsEncodedString(string, "utf-8", "surrogatepass")
                ptr = PyBytes_AsString(string)
                length = PyBytes_Size(string)
        self._string_refs.append(string)

        obj = self._ptr + idx
        obj.type = DDWAF_OBJ_TYPE.DDWAF_OBJ_STRING
        obj.stringValue = ptr
        obj.nbEntries = length
        return 0

    cdef void _make_array(self, ssize_t idx, ssize_t array_idx, ssize_t nb_entries):
        cdef ddwaf_object *obj
        obj = self._ptr + idx
        obj.type = DDWAF_OBJ_TYPE.DDWAF_OBJ_ARRAY
        obj.array = self._ptr + array_idx
        obj.nbEntries = nb_entries

    cdef void _make_map(self, ssize_t idx, ssize_t array_idx, ssize_t nb_entries):
        cdef ddwaf_object *obj
        obj = self._ptr + idx
        obj.type = DDWAF_OBJ_TYPE.DDWAF_OBJ_MAP
        obj.array = self._ptr + array_idx
        obj.nbEntries = nb_entries

    cdef int _set_parameter(self, ssize_t idx, object string) except -1:
        cdef const char * ptr
        cdef ssize_t length
        cdef ddwaf_object *obj

        if isinstance(string, six.binary_type):
            ptr = PyBytes_AsString(string)
            length = PyBytes_Size(string)
        else:
            IF PY_MAJOR_VERSION >= 3:
                ptr = PyUnicode_AsUTF8AndSize(string, &length)
            if ptr == NULL:
                string = PyUnicode_AsEncodedString(string, "utf-8", "surrogatepass")
                ptr = PyBytes_AsString(string)
                length = PyBytes_Size(string)
        self._string_refs.append(string)

        obj = self._ptr + idx
        obj.parameterName = ptr
        obj.parameterNameLength = length
        return 0

    cdef void _convert(self, value, max_objects) except *:
        cdef object stack
        cdef ssize_t i, j, n, idx, items_idx

        i = 0
        stack = deque([(self._reserve_obj(), value)], maxlen=max_objects)
        while len(stack) and (max_objects is None or i < <ssize_t?> max_objects):
            idx, val = stack.popleft()

            if isinstance(val, (int, float)):
                val = str(val)

            if isinstance(val, (six.binary_type, six.text_type)):
                self._make_string(idx, val)

            elif isinstance(val, Mapping):
                n = len(val)
                items_idx = self._reserve_obj(n)
                self._make_map(idx, items_idx, n)
                # size of val must not change!! should not happen
                # while holding the GIL?
                for j, (k, v) in enumerate(six.iteritems(val)):
                    if not isinstance(k, (six.binary_type, six.text_type)):
                        if isinstance(k, (int, float)):
                            k = str(k)
                        else:
                            continue
                    self._set_parameter(items_idx + j, k)
                    stack.append((items_idx + j, v))

            elif isinstance(val, Sequence):
                n = len(val)
                items_idx = self._reserve_obj(n)
                self._make_array(idx, items_idx, n)
                stack.extend([(items_idx + j, val[j]) for j in range(n)])

            i += 1

    def __repr__(self):
        return "<{0.__class__.__name__} for {0._next_idx} elements>".format(self)

    def __sizeof__(self):
        return super(_Wrapper, self).__sizeof__() + self._size * sizeof(ddwaf_object)

    def __dealloc__(self):
        PyMem_Free(self._ptr)

cdef class DDWafContext(object):
    cdef ddwaf_context _ctx
    cdef object _disposed

    def __init__(self):
        self._disposed = False

    cdef set_context(self, ddwaf_context ctx):
        self._ctx = ctx

    def run(self, data, timeout_ms=DEFAULT_DDWAF_TIMEOUT_MS):
        cdef ddwaf_result result
        if self._disposed:
            raise RuntimeError("Running a disposed context")
        try:
            wrapper = _Wrapper(data)
            ret_code = ddwaf_run(self._ctx, (<_Wrapper?>wrapper)._ptr, &result, <uint64_t?> timeout_ms * 1000)
            if ret_code == DDWAF_RET_CODE.DDWAF_ERR_INTERNAL:
                raise RuntimeError
            if ret_code == DDWAF_RET_CODE.DDWAF_ERR_INVALID_OBJECT or \
                    ret_code == DDWAF_RET_CODE.DDWAF_ERR_INVALID_ARGUMENT:
                raise ValueError
            response = {
                "timeout": result.timeout,
                "data": None,
                # "perf_data": None,
                # "action": None: will be used when we consider blocking
            }
            if result.data != NULL:
                response["data"] = (<bytes> result.data).decode("utf-8")
            # if result.perfData != NULL:
            #     response["perf_data"] (<bytes> result.perfData).decode("utf-8")
            return response
        finally:
            ddwaf_result_free(&result)

    @property
    def disposed(self):
        return self._disposed

    def dispose(self):
        if self._disposed:
            return
        self._disposed = True
        ddwaf_context_destroy(self._ctx)

    def __dealloc__(self):
        self.dispose()


cdef class DDWaf(object):
    """
    A DDWaf instance performs a matching operation on provided data according
    to some rules.
    """

    cdef ddwaf_handle _handle
    cdef object _rules

    def __init__(self, rules):
        cdef ddwaf_object* rule_objects
        self._rules = _Wrapper(rules, max_objects=None)
        rule_objects = (<_Wrapper?>self._rules)._ptr;
        self._handle = ddwaf_init(rule_objects, NULL)
        if <void *> self._handle == NULL:
            raise ValueError("invalid rules") # TODO(@vdetuckheim) replace by custom InvalidRulesError

    @property
    def required_data(self):
        cdef uint32_t size
        cdef const char* const* ptr

        addresses = []
        ptr = ddwaf_required_addresses(self._handle, &size)
        for i in range(size):
            addresses.append((<bytes> ptr[i]).decode("utf-8"))
        return addresses

    def create_waf_context(self):
        ctx = ddwaf_context_init(self._handle, NULL)
        if <void *> ctx == NULL:
            raise RuntimeError
        res = DDWafContext()
        res.set_context(ctx)
        return res

    def __dealloc__(self):
        ddwaf_destroy(self._handle)
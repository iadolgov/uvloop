@cython.internal
@cython.no_gc_clear
cdef class UVPoll(UVHandle):
    cdef _init(self, int fd):
        cdef int err

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_poll_t))
        if self._handle is NULL:
            self._close()
            raise MemoryError()

        err = uv.uv_poll_init(self._loop.uvloop,
                              <uv.uv_poll_t *>self._handle, fd)
        if err < 0:
            __cleanup_handle_after_init(<UVHandle>self)
            raise convert_error(err)

        self._handle.data = <void*> self
        self.fd = fd
        self.reading_handle = None
        self.writing_handle = None

    @staticmethod
    cdef UVPoll new(Loop loop, int fd):
        cdef UVPoll handle
        handle = UVPoll.__new__(UVPoll)
        handle._set_loop(loop)
        handle._init(fd)
        return handle

    cdef int is_active(self):
        return (self.reading_handle is not None or
                self.writing_handle is not None)

    cdef inline _poll_start(self, int flags):
        cdef int err

        self._ensure_alive()

        err = uv.uv_poll_start(
            <uv.uv_poll_t*>self._handle,
            flags,
            __on_uvpoll_event)

        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef inline _poll_stop(self):
        cdef int err

        if not self._is_alive():
            return

        err = uv.uv_poll_stop(<uv.uv_poll_t*>self._handle)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef start_reading(self, Handle callback):
        cdef:
            int mask = 0

        if self.reading_handle is None:
            # not reading right now, setup the handle

            mask = uv.UV_READABLE
            if self.writing_handle is not None:
                # are we writing right now?
                mask |= uv.UV_WRITABLE

            self._poll_start(mask)

        self.reading_handle = callback

    cdef start_writing(self, Handle callback):
        cdef:
            int mask = 0

        if self.writing_handle is None:
            # not writing right now, setup the handle

            mask = uv.UV_WRITABLE
            if self.reading_handle is not None:
                # are we reading right now?
                mask |= uv.UV_READABLE

            self._poll_start(mask)

        self.writing_handle = callback

    cdef stop_reading(self):
        if self.reading_handle is None:
            return False

        self.reading_handle = None

        if self.writing_handle is None:
            self.stop()
        else:
            self._poll_start(uv.UV_WRITABLE)

        return True

    cdef stop_writing(self):
        if self.writing_handle is None:
            return False

        self.writing_handle = None

        if self.reading_handle is None:
            self.stop()
        else:
            self._poll_start(uv.UV_READABLE)

        return True

    cdef stop(self):
        self.reading_handle = None
        self.writing_handle = None
        self._poll_stop()


cdef void __on_uvpoll_event(uv.uv_poll_t* handle,
                            int status, int events) with gil:

    if __ensure_handle_data(<uv.uv_handle_t*>handle, "UVPoll callback") == 0:
        return

    cdef:
        UVPoll poll = <UVPoll> handle.data

    if status < 0:
        exc = convert_error(status)
        poll._fatal_error(exc, False)
        return

    if events | uv.UV_READABLE and poll.reading_handle is not None:
        try:
            poll.reading_handle._run()
        except BaseException as ex:
            poll._error(ex, False)
            # continue code execution

    if events | uv.UV_WRITABLE and poll.writing_handle is not None:
        try:
            poll.writing_handle._run()
        except BaseException as ex:
            poll._error(ex, False)

"""Resource controls for the generated-code child; these are not user isolation."""
import os
import time


class WindowsJob:
    def __init__(self, process, memory_bytes, cpu_seconds=10):
        import ctypes
        from ctypes import wintypes

        class BASIC(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong),
                        ("PerJobUserTimeLimit", ctypes.c_longlong),
                        ("LimitFlags", wintypes.DWORD),
                        ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t),
                        ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t),
                        ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD)]

        class IO(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class EXTENDED(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", BASIC), ("IoInfo", IO),
                        ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        class ACCOUNTING(ctypes.Structure):
            _fields_ = [("TotalUserTime", ctypes.c_longlong),
                        ("TotalKernelTime", ctypes.c_longlong),
                        ("ThisPeriodTotalUserTime", ctypes.c_longlong),
                        ("ThisPeriodTotalKernelTime", ctypes.c_longlong),
                        ("TotalPageFaultCount", wintypes.DWORD),
                        ("TotalProcesses", wintypes.DWORD),
                        ("ActiveProcesses", wintypes.DWORD),
                        ("TotalTerminatedProcesses", wintypes.DWORD)]

        api = ctypes.WinDLL("kernel32", use_last_error=True)
        api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        api.CreateJobObjectW.restype = wintypes.HANDLE
        api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                                ctypes.c_void_p, wintypes.DWORD]
        api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        api.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        api.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                                  ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p]
        api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.api = api
        self.accounting_type = ACCOUNTING
        self.handle = api.CreateJobObjectW(None, None)
        if not self.handle:
            raise OSError("cannot create resource job")
        info = EXTENDED()
        # KILL_ON_JOB_CLOSE | PROCESS_MEMORY | ACTIVE_PROCESS | PROCESS_TIME
        info.BasicLimitInformation.LimitFlags = 0x2000 | 0x100 | 0x8 | 0x2
        # Windows venv python.exe redirector, base interpreter, and conhost/descendant
        # handles can briefly coexist on Windows 11 while blocking runaway fork bombs.
        info.BasicLimitInformation.ActiveProcessLimit = 4
        info.BasicLimitInformation.PerProcessUserTimeLimit = int(cpu_seconds * 10000000)
        info.ProcessMemoryLimit = memory_bytes
        if not api.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            self.close()
            raise OSError("cannot set resource job limits")
        if not api.AssignProcessToJobObject(self.handle, wintypes.HANDLE(process._handle)):
            self.close()
            raise OSError("cannot attach generated-code worker to resource job")

    def close(self, timeout=5):
        if self.handle:
            import ctypes
            try:
                # KILL_ON_JOB_CLOSE is asynchronous. Keep our exact job handle
                # until every owned process has exited before deleting its cwd.
                if not self.api.TerminateJobObject(self.handle, 1):
                    raise OSError("cannot terminate the owned Python resource job")
                deadline = time.monotonic() + timeout
                while True:
                    info = self.accounting_type()
                    if not self.api.QueryInformationJobObject(
                            self.handle, 1, ctypes.byref(info), ctypes.sizeof(info), None):
                        raise OSError("cannot query the owned Python resource job")
                    if info.ActiveProcesses == 0:
                        break
                    if time.monotonic() >= deadline:
                        raise TimeoutError("owned Python resource job did not stop before cleanup")
                    time.sleep(0.01)
            finally:
                self.api.CloseHandle(self.handle)
                self.handle = None


def posix_limit(memory_bytes):
    import resource
    resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
    resource.setrlimit(resource.RLIMIT_FSIZE, (24 * 1024 * 1024, 24 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))


def child_environment():
    # Keep only OS/runtime variables needed to load Python and the official DLLs.
    keys = ("SYSTEMROOT", "WINDIR", "TEMP", "TMP", "PATH")
    result = {key: os.environ[key] for key in keys if key in os.environ}
    result["PYTHONIOENCODING"] = "utf-8"
    return result

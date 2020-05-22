#!/usr/bin/python
# This won't catch all new processes: an application may fork() but not exec().

from __future__ import print_function
from bcc import BPF
from bcc.utils import ArgString, printb
import bcc.utils as utils
import argparse
import re
import time
from collections import defaultdict
import os
import sys
import signal
import time
import shutil

# define BPF program
bpf_text = """
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>
#include <linux/fs.h>

#define ARGSIZE  256

struct data_t {
    u32 pid;  // PID as in the userspace term (i.e. task->tgid in kernel)
    char path[ARGSIZE];
    int retval;
};

BPF_PERF_OUTPUT(events);

int syscall__execve(struct pt_regs *ctx,
    const char __user *filename,
    const char __user *const __user *__argv,
    const char __user *const __user *__envp)
{
    // create data here and pass to submit_arg to save stack space (#555)
    struct data_t data = {};
    struct task_struct *task;

    data.pid = bpf_get_current_pid_tgid() >> 32;
    bpf_probe_read(data.path, sizeof(data.path), filename);
    events.perf_submit(ctx, &data, sizeof(struct data_t));

    return 0;
}
"""

def getRealPath(exec_path):
    path=exec_path.strip()
    if not path.startswith("/"):
        path=shutil.which(path)
    if path:
        path=os.path.realpath(path)
    if path and os.path.isfile(path):
            return path
            
    print("'{0}' can not be find".format(exec_path))

def getParam():
    global exec_path_proxy, exec_path_noproxy
    exec_path_str=os.getenv('program_proxy')
    if exec_path_str: 
        paths=exec_path_str.split(':')
        exec_path_proxy=[getRealPath(x) for x in paths]
    print("program with proxy:", end =" ")
    print(*exec_path_proxy,flush=True)
     
    exec_path_str=os.getenv('program_noproxy')
    if exec_path_str: 
        paths=exec_path_str.split(':')
        exec_path_noproxy=[getRealPath(x) for x in paths]
    print("program without proxy:", end =" ")
    print(*exec_path_noproxy, flush=True)

def exit_gracefully(signum, frame):
    print("execsnoop receive signal: {0}".format(signum),flush=True)
    sys.exit(0)

def attach(pid, path, proxy=True):
    if proxy:
        print("proxy: %-6d %s" % (pid, path),flush=True)
        os.system("/usr/bin/cgproxy --pid {0}".format(pid))
    else:
        print("noproxy: %-6d %s" % (pid, path),flush=True)
        os.system("/usr/bin/cgproxy --pid {0} --noproxy".format(pid))

def processAlreadyRunning():
    from subprocess import check_output
    def get_pid(name):
        return map(int,check_output(["pidof",name]).split())
    global exec_path_proxy, exec_path_noproxy
    for path in exec_path_proxy:
        for pid in get_pid(path):
            attach(pid,path,True)
    for path in exec_path_noproxy:
        for pid in get_pid(path):
            attach(pid,path,False)

signal.signal(signal.SIGINT, exit_gracefully)
signal.signal(signal.SIGHUP, exit_gracefully)
signal.signal(signal.SIGTERM, exit_gracefully)

show_ignore=False
exec_path_proxy=[]
exec_path_noproxy=[]
getParam()
processAlreadyRunning()

# initialize BPF
b = BPF(text=bpf_text)
execve_fnname = b.get_syscall_fnname("execve")
b.attach_kprobe(event=execve_fnname, fn_name="syscall__execve")

# process event
def print_event(cpu, data, size):
    event = b["events"].event(data)
    pid=event.pid
    exec_path=event.path.decode('utf-8')
    if (exec_path in exec_path_noproxy):
        attach(pid, exec_path, False)
    elif (exec_path in exec_path_proxy):
        attach(pid, exec_path, True)
    elif (show_ignore):
        print("ignore: %-6d %s" % (pid, exec_path),flush=True)


# loop with callback to print_event
b["events"].open_perf_buffer(print_event)
while 1:
    b.perf_buffer_poll()
#include <libproc.h>

int launch_entry_process_path(int pid, void *buffer, unsigned int size) {
    return proc_pidpath(pid, buffer, size);
}

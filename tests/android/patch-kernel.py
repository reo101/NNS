"""Apply the phone's exact seccomp allowlist implementation to emulator ACK.
The phone patch has SuSFS-specific context; the emulator deliberately omits
SuSFS, which is unrelated to NNS. Fail if either source anchor drifts.
"""
from pathlib import Path
import sys

patch = Path(sys.argv[1]).read_text()
added = '\n'.join(line[1:] for line in patch.splitlines()
                  if line.startswith('+') and not line.startswith('+++'))
start = added.index('/*\n * Exec-time seccomp bypass allowlist.')
end = added.index('#endif /* CONFIG_KSU */', start) + len('#endif /* CONFIG_KSU */')
Path('fs/nns-seccomp.h').write_text('#include <linux/mutex.h>\n#include <linux/sysctl.h>\n' + added[start:end] + '\n')
call = added[end:].strip() + '\n'
assert call.startswith('#ifdef CONFIG_KSU') and call.endswith('#endif\n')
p = Path('fs/exec.c')
text = p.read_text()
anchor = '#include <linux/coredump.h>\n'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '#include "nns-seccomp.h"\n')
head, tail = text.split('static int do_execveat_common(', 1)
anchor = '\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n'
assert tail.split('\n}\n', 1)[0].count(anchor) == 1
declaration = '''#ifdef CONFIG_KSU
extern bool ksu_execveat_hook;
extern int ksu_handle_execveat_ksud(int *, struct filename **,
                                  struct user_arg_ptr *, struct user_arg_ptr *, int *);
#endif
'''
init_hook = '''#ifdef CONFIG_KSU
\tif (unlikely(ksu_execveat_hook))
\t\tksu_handle_execveat_ksud(&fd, &filename, &argv, &envp, &flags);
#endif
'''
p.write_text(head + declaration + 'static int do_execveat_common(' +
             tail.replace(anchor, anchor + '\n' + call + init_hook, 1))

# Built-in/non-SuSFS SukiSU needs its public fd-request entry point wired up.
# Normal reboot calls are unchanged; the ioctl layer enforces authorization.
p = Path('kernel/reboot.c')
text = p.read_text()
anchor = 'SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)'
assert text.count(anchor) == 1
head, tail = text.split(anchor)
declaration = '''#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);
#endif
'''
brace = tail.index('{') + 1
tail = tail[:brace] + '''
#ifdef CONFIG_KSU
\tif ((unsigned int)magic1 == 0xDEADBEEF)
\t\treturn ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
''' + tail[brace:]
p.write_text(head + declaration + anchor + tail)

# The pinned SukiSU snapshot passes its SUSFS pointer-shaped null argument
# to the non-SUSFS by-value API. Keep this compatibility fix emulator-only.
p = Path('KernelSU/kernel/sulog/event.c')
text = p.read_text()
assert text.count('#define USER_ARG_NULL user_arg_null_ptr()') == 1
p.write_text(text.replace('#define USER_ARG_NULL user_arg_null_ptr()',
                          '#define USER_ARG_NULL (*user_arg_null_ptr())'))

# These optional 6.6 hooks are supplied by SUSFS. Without it, the snapshot
# already has local fallbacks, but its declarations forgot to be weak.
p = Path('KernelSU/kernel/feature/selinux_hide.c')
text = p.read_text()
for name in ('context_struct_compute_av_fn', 'security_dump_masked_av_fn'):
    anchor = 'extern void ' + name
    assert text.count(anchor) == 1
    text = text.replace(anchor, 'extern __weak void ' + name)
p.write_text(text)

# x86 generic-entry kernels moved seccomp state out of thread flags.
for p in Path('KernelSU/kernel').rglob('*.c'):
    text = p.read_text()
    if 'test_thread_flag(TIF_SECCOMP)' in text:
        p.write_text(text.replace('test_thread_flag(TIF_SECCOMP)', '(current->seccomp.mode != 0)'))

"""Check the Zig readiness adapter without mounting or Android properties."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='nns-storage-controller-') as temporary, open('/proc/self/ns/mnt', 'rb') as namespace:
    directory = Path(temporary)
    (directory / 'stub.c').write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
int __system_property_set(const char *name, const char *value) {
    printf("%s=%s\n", name, value);
    fflush(stdout);
    const char *failure = getenv("NNS_STORAGE_TEST_PROPERTY_FAILURE");
    return failure && !strcmp(failure, value) ? -1 : 0;
}
int nns_storage_test_engine(int descriptor) {
    puts("engine");
    fflush(stdout);
    struct stat initial, current;
    if (fstat(descriptor, &initial) || stat("/proc/self/ns/mnt", &current) ||
        initial.st_dev != current.st_dev || initial.st_ino != current.st_ino) return 19;
    if (getenv("NNS_STORAGE_TEST_ENGINE_EXIT")) exit(17);
    return getenv("NNS_STORAGE_TEST_ENGINE_FAILURE") ? 18 : 0;
}
''')
    (directory / 'stub.zig').write_text('''
const std = @import("std");
extern fn nns_storage_test_engine(descriptor: c_int) c_int;
pub fn run(arguments: []const [*:0]const u8, initial_namespace: ?i32) void {
    _ = arguments;
    const result = nns_storage_test_engine(initial_namespace orelse -1);
    if (result != 0) std.process.exit(@intCast(result));
}
''')
    object_file = directory / 'stub.o'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-c',
                    str(directory / 'stub.c'), '-o', str(object_file)], check=True)
    archive = directory / 'libcontroller.a'
    subprocess.run(['zig', 'build-lib', '-static', '-fno-entry', '-fPIC', '-target',
                    os.uname().machine + '-linux-musl', '-O', 'small', '--dep', 'storage',
                    '-Mroot=' + str(ROOT / 'integrations/rom/storage/controller.zig'),
                    '-Mstorage=' + str(directory / 'stub.zig'),
                    '-femit-bin=' + str(archive)], check=True)
    executable = directory / 'controller'
    subprocess.run(['cc', str(object_file), '-Wl,--whole-archive', str(archive),
                    '-Wl,--no-whole-archive', '-o', str(executable)], check=True)

    def execute(*arguments, namespace_descriptor=namespace.fileno(), **environment):
        values = {**os.environ, 'ANDROID_FILE__proc_1_ns_mnt': str(namespace_descriptor), **environment}
        return subprocess.run([str(executable), *arguments], capture_output=True, text=True,
                              pass_fds=(namespace_descriptor,),
                              env={name: value for name, value in values.items() if value is not None})

    expected = 'sys.nns.storage.ready=0\nengine\nsys.nns.storage.ready=1\n'
    for arguments in ((), ('--check',)):
        result = execute(*arguments)
        assert result.returncode == 0 and result.stdout == expected, result
    for arguments in (('--mode',), ('unexpected',), ('--check', 'unexpected')):
        result = execute(*arguments)
        assert result.returncode != 0 and not result.stdout, result
    for value in (None, '', '-1', '+1', ' 1', '1x', '2147483648', '2147483647'):
        result = execute(ANDROID_FILE__proc_1_ns_mnt=value)
        assert result.returncode != 0 and result.stdout == 'sys.nns.storage.ready=0\n', result
    with open('/dev/null', 'rb') as other:
        result = execute(namespace_descriptor=other.fileno())
        assert result.returncode != 0 and result.stdout == 'sys.nns.storage.ready=0\nengine\n', result
    for variable in ('NNS_STORAGE_TEST_ENGINE_EXIT', 'NNS_STORAGE_TEST_ENGINE_FAILURE'):
        result = execute(**{variable: '1'})
        assert result.returncode != 0 and result.stdout == 'sys.nns.storage.ready=0\nengine\n', result
    result = execute(NNS_STORAGE_TEST_PROPERTY_FAILURE='0')
    assert result.returncode != 0 and result.stdout == 'sys.nns.storage.ready=0\n', result
    result = execute(NNS_STORAGE_TEST_PROPERTY_FAILURE='1')
    assert result.returncode != 0 and result.stdout == expected, result

print('PASS: Zig storage readiness is published only after successful validation')

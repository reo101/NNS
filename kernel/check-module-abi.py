"""Compare a kernel's exported symbol CRCs with installed module requirements."""
import argparse
import json
from pathlib import Path
import subprocess


def versions(text):
    result = {}
    for line in text.splitlines():
        if line.strip():
            crc, symbol, *_ = line.split()
            result[symbol] = int(crc, 16)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('symbols', type=Path)
    parser.add_argument('modules', type=Path)
    parser.add_argument('--modprobe', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    kernel = versions(args.symbols.read_text())
    modules = sorted(args.modules.rglob('*.ko'))
    if not kernel or not modules:
        parser.error('Nonempty kernel symbols and installed modules are required')
    exports = {}
    imports = {}
    failures = []
    for module in modules:
        name = str(module.relative_to(args.modules))
        imports[name] = versions(subprocess.check_output(
            [args.modprobe, '--show-modversions', str(module)], text=True))
        try:
            exported = subprocess.check_output(
                [args.modprobe, '--show-exports', str(module)], text=True, stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as error:
            # libkmod returns ENODATA for valid modules with no exported symbols.
            if error.returncode != 1 or error.output or not (error.stderr or '').rstrip().endswith('No data available'):
                raise
            exported = ''
        for symbol, crc in versions(exported).items():
            if symbol in kernel:
                failures.append({'module': name, 'symbol': symbol, 'reason': 'duplicate_kernel_export'})
            if symbol in exports and exports[symbol] != crc:
                failures.append({'module': name, 'symbol': symbol, 'reason': 'ambiguous_module_export'})
            exports[symbol] = crc
    provided = exports | kernel
    checked = 0
    for module, required in imports.items():
        for symbol, crc in required.items():
            checked += 1
            if symbol not in provided or provided[symbol] != crc:
                failures.append({'module': module, 'symbol': symbol,
                                 'expected_crc': crc, 'provided_crc': provided.get(symbol)})
    if not checked:
        parser.error('Installed modules contain no symbol version requirements')
    report = {'state': 'failed' if failures else 'passed', 'module_count': len(modules),
              'kernel_export_count': len(kernel), 'checked_import_count': checked,
              'failures': failures}
    with args.output.open('x') as output:
        output.write(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'failures'}))
    if failures:
        raise SystemExit('Module symbol compatibility failed; read ' + str(args.output))


if __name__ == '__main__':
    main()

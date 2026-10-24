"""Optional Windows parse check; NOT a replacement for Swift compilation, type checking or XCTest."""
from pathlib import Path

from tree_sitter_language_pack import get_parser

root = Path(__file__).resolve().parents[1]
parser = get_parser('swift')
files = sorted(p for d in ('Sources', 'Tests', 'iOSApp') for p in (root / d).rglob('*.swift'))
files.append(root / 'Package.swift')
failures = []
for path in files:
    source = path.read_bytes()
    tree = parser.parse(source.decode('utf-8'))
    nodes = [tree.root_node()]
    while nodes:
        node = nodes.pop()
        if node.is_error() or node.is_missing():
            point = node.start_position()
            where = f'{getattr(point, "row", "?")}:{getattr(point, "column", "?")}'  # 0-based
            failures.append((str(path.relative_to(root)), where,
                             node.kind(), source[node.start_byte():node.end_byte()].decode('utf-8')[:160]))
        nodes.extend(node.child(i) for i in range(node.child_count()))
for failure in failures:
    print(failure)
print(f'Parsed {len(files)} Swift files; syntax findings: {len(failures)}. Swift compilation is still required.')
raise SystemExit(1 if failures or not files else 0)

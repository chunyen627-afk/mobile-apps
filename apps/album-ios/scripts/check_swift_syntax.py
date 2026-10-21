"""Optional Windows parse check; NOT a replacement for xcodebuild type checking."""
from pathlib import Path
from tree_sitter_language_pack import get_parser

root = Path(__file__).resolve().parents[1]
parser = get_parser('swift')
files = sorted(root.rglob('*.swift'))
failures = []
for path in files:
    source = path.read_bytes()
    tree = parser.parse(source.decode('utf-8'))
    nodes = [tree.root_node()]
    while nodes:
        node = nodes.pop()
        if node.is_error() or node.is_missing():
            failures.append((str(path.relative_to(root)), str(node.start_position()),
                             node.kind(), source[node.start_byte():node.end_byte()].decode('utf-8')[:160]))
        nodes.extend(node.child(i) for i in range(node.child_count()))
for failure in failures:
    print(failure)
print(f'Parsed {len(files)} Swift files; syntax findings: {len(failures)}. Xcode type checking is still required.')
raise SystemExit(1 if failures or not files else 0)

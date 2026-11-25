"""Print the name of every test esctest would run, one `Class.test_method` a line.

Reads esctest's sources without importing them: `esctest.py` runs the whole
suite when it is imported, and the names are wanted before a terminal is. The
classes are the ones `tests/__init__.py` lists in `tests`; the methods are each
class's own `test_` methods and those of the classes it derives from, which is
how the save-and-restore-cursor tests come to run three times over.

    python3 esctest_names.py /path/to/esctest2
"""

import ast
import os
import sys


def base_name(node):
    """`Base` for `Base`, and for `tests.module.Base`."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return None


def main(root):
    directory = os.path.join(root, "esctest", "tests")
    classes = {}
    listed = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".py"):
            continue
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8") as source:
            tree = ast.parse(source.read(), path)
        for node in tree.body:
            if isinstance(node, ast.ClassDef):
                methods = [
                    item.name
                    for item in node.body
                    if isinstance(item, ast.FunctionDef) and item.name.startswith("test_")
                ]
                bases = [base_name(base) for base in node.bases]
                classes[node.name] = (bases, methods)
            elif name == "__init__.py" and isinstance(node, ast.Assign):
                targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
                if "tests" in targets and isinstance(node.value, ast.List):
                    listed = [base_name(item) for item in node.value.elts]

    def methods_of(name, seen=()):
        if name not in classes or name in seen:
            return set()
        bases, own = classes[name]
        found = set(own)
        for base in bases:
            found |= methods_of(base, seen + (name,))
        return found

    for name in listed:
        for method in sorted(methods_of(name)):
            print("%s.%s" % (name, method))


if __name__ == "__main__":
    main(sys.argv[1])

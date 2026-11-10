import ast
from collections import Counter


class BodyUses:
    """Syntactic uses across a function and all nested scopes."""

    def __init__(self, node):
        self.node = node
        self.nodes = tuple(ast.walk(node))
        self.calls = [item for item in self.nodes if isinstance(item, ast.Call)]
        self.name_uses = Counter(
            item.id for item in self.nodes if isinstance(item, ast.Name)
        )
        self.names = set(self.name_uses)
        self.named_calls = {}
        for call in self.calls:
            if isinstance(call.func, ast.Name):
                self.named_calls.setdefault(call.func.id, []).append(call)
        self.call_names = set(self.named_calls)
        self.loads = {
            item.id
            for item in self.nodes
            if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Load)
        }
        self.stores = {
            item.id
            for item in self.nodes
            if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Store)
        }
        self.bound_names = self.stores | {
            item.arg for item in self.nodes if isinstance(item, ast.arg)
        }

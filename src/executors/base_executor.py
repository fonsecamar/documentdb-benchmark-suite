import re
import copy
from typing import Any, Dict, List
from collections import defaultdict

class BaseExecutor:
    abstract = True
    _param_pattern = re.compile(r'@\w+')

    def __init__(self, environment):
        self.environment = environment

    def _fire_event(self, request_type: str, name: str, response_time: float, exception: Exception = None, response_length: int = 0) -> None:
        """Fire a request event."""
        self.environment.events.request.fire(
            request_type=request_type,
            name=name,
            response_time=response_time,
            exception=exception,
            response_length=response_length,
        )

    def _connect(self) -> None:
        raise NotImplementedError("Subclasses must implement this method.")
    
    def _disconnect(self) -> None:
        raise NotImplementedError("Subclasses must implement this method.")

    def _map_all_param_paths(self, obj: Any, param_names: List[str]) -> Dict[str, List[List[Any]]]:
        """Map all parameter names to their paths in a nested object."""
        result = defaultdict(list)
        def recurse(o, current_path=None):
            if current_path is None:
                current_path = []
            if isinstance(o, dict):
                for k, v in o.items():
                    for param in param_names:
                        if v == param:
                            result[param].append(current_path + [k])
                    if isinstance(v, (dict, list)):
                        recurse(v, current_path + [k])
            elif isinstance(o, list):
                for idx, item in enumerate(o):
                    for param in param_names:
                        if item == param:
                            result[param].append(current_path + [idx])
                    if isinstance(item, (dict, list)):
                        recurse(item, current_path + [idx])
        recurse(obj)
        return dict(result)

    def _replace_json_param_at_paths(self, obj: Any, paths: List[List[Any]], value: Any) -> Any:
        """Replace all occurrences at the given paths in obj with value."""
        for path in paths:
            target = obj
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
        return obj

    def _replace_all_params(self, obj: Any, param_paths_dict: Dict[str, List[List[Any]]], param_values: Dict[str, Any], deepcopy_obj: bool = True) -> Any:
        """Replace all parameters in obj using the provided paths and values."""
        obj_copy = copy.deepcopy(obj) if deepcopy_obj else obj
        for param, paths in param_paths_dict.items():
            self._replace_json_param_at_paths(obj_copy, paths, param_values[param])
        return obj_copy    

    def execute(self, command: Any) -> None:
        """Subclasses must implement this method."""
        raise NotImplementedError("Subclasses must implement this method.")

    def run_startup(self, workloadName: str) -> None:
        """Subclasses must implement this method."""
        raise NotImplementedError("Subclasses must implement this method.")

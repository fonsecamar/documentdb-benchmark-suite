from typing import List, Dict, Any
from dataclasses import dataclass
from pathlib import Path
from enum import Enum
import json
import logging
import yaml

class StartUpFrequency(Enum):
    NEVER = "never"
    ONCE = "once"
    ALWAYS = "always"

@dataclass
class TaskConfig:
    taskWeight: int
    taskName: str
    command: Dict[str, Any]

    @staticmethod
    def from_dict(data: dict):
        return TaskConfig(
            taskWeight=data.get("taskWeight", 1),
            taskName=data.get("taskName"),
            command=data.get("command", {})
        )

@dataclass
class Settings:
    workloadName: str
    type: str
    runStartUpFrequency: StartUpFrequency
    tasks: List[TaskConfig]

def get_config_path() -> Path:
    if Path.cwd() == Path('/app'):
        return Path('/app/config')
    return Path(__file__).parent.parent / 'config/'

def load_tasks(config: dict) -> List[TaskConfig]:
    tasks = []
    name_count = {}
    for task in config.get("tasks", []):
        base_name = task.get("taskName")
        if base_name in name_count:
            name_count[base_name] += 1
            task["taskName"] = f"{base_name}_{name_count[base_name]}"
        else:
            name_count[base_name] = 0
        tasks.append(TaskConfig.from_dict(task))
    return tasks

def init_settings() -> List[Settings]:

    config_dir = get_config_path()
    config_dir = config_dir.resolve()

    logging.info(f"Loading settings from all JSON and YAML files in {config_dir}")
    settings_list: List[Settings] = []
    if not config_dir.exists():
        logging.warning(f"Config directory {config_dir} does not exist.")
        return settings_list

    for config_file in config_dir.glob('*'):
        if config_file.suffix.lower() not in ['.json', '.yaml', '.yml'] or config_file.stem.lower().endswith('_startup'):
            continue
        try:
            with open(config_file, 'r', encoding='utf-8') as file:
                if config_file.suffix.lower() == '.json':
                    config = json.load(file)
                else:
                    config = yaml.safe_load(file)
            workload_name = config_file.stem
            
            run_startup_frequency_value = config.get("runStartUpFrequency", "Never")
            frequency_mapping = {
                    "never": StartUpFrequency.NEVER,
                    "once": StartUpFrequency.ONCE,
                    "always": StartUpFrequency.ALWAYS
                }
            run_startup_frequency = frequency_mapping.get(run_startup_frequency_value.lower(),StartUpFrequency.NEVER)

            tasks = load_tasks(config)
            settings_list.append(Settings(
                workloadName=workload_name,
                type="DOCUMENTDB",
                runStartUpFrequency=run_startup_frequency,
                tasks=tasks
            ))
        except Exception as e:
            logging.error(f"Failed to load {config_file}: {e}")
    return settings_list
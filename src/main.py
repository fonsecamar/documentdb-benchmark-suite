from locust import User, events
from locust.runners import MasterRunner, LocalRunner
from executors.documentdb_executor import DocumentDBExecutor
import settings
from settings import Settings, StartUpFrequency
import logging
from typing import Any, Callable

logging.basicConfig(level=logging.INFO)
all_profiles = settings.init_settings()

@events.init_command_line_parser.add_listener
def _(parser):
    parser.add_argument("--documentdb-connection-string", type=str, is_required=True, is_secret=True, help="Format: mongodb+srv://<username>:<password>@<cluster-address>/?tls=true&authMechanism=SCRAM-SHA-256&retrywrites=false&maxIdleTimeMS=120000")

@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    if isinstance(environment.runner, MasterRunner) or isinstance(environment.runner, LocalRunner):
        for uc in environment.user_classes:
            if uc.runStartUp:
                environment.runner.state = "running"
                logging.info(f"Running startup for user class: {uc.__name__}")
                uc(environment).run_startup()
            else:
                logging.info(f"Skipping startup for user class: {uc.__name__}")


def create_task_function(command, task_name) -> Callable:
    def task_func(self):
        self.executor.execute(command, task_name)
    task_func.__name__ = task_name
    return task_func

def create_user_class(class_name: str, workload_settings: Settings):

    class DynamicUser(User):

        runStartUp = workload_settings.runStartUpFrequency != StartUpFrequency.NEVER

        def __init__(self, environment, *args, **kwargs):
            super().__init__(environment, *args, **kwargs)
            self.executor = DocumentDBExecutor(environment)
            self.workload_settings = workload_settings

        def run_startup(self):
            if self.executor and self.__class__.runStartUp:
                self.executor.run_startup(self.workload_settings.workloadName)
                self.__class__.runStartUp = self.workload_settings.runStartUpFrequency == StartUpFrequency.ALWAYS

        def on_stop(self):
            super().on_stop()

            if self.executor:
                try:
                    self.executor._disconnect()
                except Exception as e:
                    logging.error(f"Error disconnecting executor: {e}")

    task_list = []
    for task_def in workload_settings.tasks:
        fullTaskName = f"{workload_settings.workloadName}_{task_def.taskName}"
        func = create_task_function(task_def.command, fullTaskName)
        setattr(DynamicUser, task_def.taskName, func)
        logging.info(f"Adding task {task_def.taskName}:weight {task_def.taskWeight} to user class {class_name}")
        for i in range(task_def.taskWeight):
            task_list.append(func)
    
    DynamicUser.tasks = task_list
    DynamicUser.__name__ = class_name
    return DynamicUser

classes = {}
for setting in all_profiles:
    new_class_name = f"{setting.workloadName.replace('_', '')}_{setting.type}_User"
    logging.info(f"Creating user class: {new_class_name}")
    classes[new_class_name] = create_user_class(new_class_name, setting)

globals().update({cls.__name__: cls for cls in classes.values()})
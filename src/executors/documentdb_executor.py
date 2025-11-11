import logging
import settings
import sys
import time
import yaml

from datamanager import DataManager
from executors.base_executor import BaseExecutor
from pathlib import Path
from pymongo import MongoClient
from typing import Any, Dict, Optional

logging.getLogger("pymongo").setLevel(logging.INFO)

class DocumentDBExecutor(BaseExecutor):
    def __init__(self, environment: Any):
        super().__init__(environment)
        self.client: Optional[MongoClient] = None
        self.db = None
        self._connect()
        self._param_map_cache: Dict[str, Dict] = {}

    def _connect(self) -> None:
        try:
            self.client = MongoClient(
                self.environment.parsed_options.documentdb_connection_string,
                serverSelectionTimeoutMS=5000
            )
            logging.debug("DocumentDB connection established.")
        except Exception as e:
            logging.exception(f"DocumentDB connection error: {e}")
            self.client = None
            self.db = None

    def _disconnect(self) -> None:
        if self.client:
            self.client.close()
            self.client = None
            self.db = None
    
    def run_startup(self, workloadName: str) -> None:

        try:
            startup = Path(settings.get_config_path()) / f"{workloadName}_startup.yaml"

            logging.info(f"Executing startup script file: {startup}")

            with open(startup, 'r', encoding='utf-8') as file:
                mongoConfig = yaml.safe_load(file)
            for db in mongoConfig.get('databases', []):
                db_name = db.get('name')
                collections = db.get('collections', [])
                for coll in collections:
                    coll_name = coll.get('name')
                    database = self.client.get_database(db_name)
                    
                    if coll_name not in database.list_collection_names():
                        dbcoll = database.create_collection(coll_name)
                    else:
                        dbcoll = database.get_collection(coll_name)
                  
                    shard_key = coll.get('shardKey')
                    if shard_key:
                        admin_db = self.client['admin']
                        admin_db.command({
                            'shardCollection': f'{db_name}.{coll_name}',
                            'key': {shard_key: 'hashed'}
                        })

                    indexes = coll.get('indexes', [])
                    for index in indexes:
                        index_name = index.get('name')
                        keys = index.get('keys', {})
                        options = index.get('options', {})

                        dbcoll.create_index(keys, name=index_name, **options)

            self._disconnect()
        except Exception as e:
            logging.error(f"Error occurred while executing startup script file: {startup}. Exception: {e}")

    def execute(self, command: Dict, task_name: str) -> None:
        if self.client is None:
            logging.info("No DocumentDB client available. Attempting to connect.")
            self._connect()
            if self.client is None:
                logging.error("Connection to DocumentDB failed.")
                return

        db_name = command.get('database')
        db = self.client[db_name]

        update_template = {}
        command_type = command.get('type')
        batch_size = command.get('batchSize', 1)
        if command_type == 'insert':
            json_template = command.get('document', {})
        elif command_type == 'aggregate':
            json_template = command.get('pipeline', [])
        elif command_type in ('find', 'delete', 'update', 'replace'):
            json_template = command.get('filter', {})
            if command_type == 'update':
                update_template = command.get('update', {})
            elif command_type == 'replace':
                update_template = command.get('replacement', {})
        else:
            json_template = {}

        cache_key = f"{task_name}:{command_type}"
        cache = self._param_map_cache.get(cache_key)
        if not cache:
            parameters = command.get('parameters', [])
            param_names = [param.get('name') for param in parameters]
            param_paths_dict = self._map_all_param_paths(json_template, param_names)
            param_paths_dict_upd = self._map_all_param_paths(update_template, param_names)
            cache = {
                'parameters': parameters,
                'param_names': param_names,
                'param_paths_dict': param_paths_dict,
                'param_paths_dict_upd': param_paths_dict_upd
            }
            self._param_map_cache[cache_key] = cache
        else:
            parameters = cache['parameters']
            param_names = cache['param_names']
            param_paths_dict = cache['param_paths_dict']
            param_paths_dict_upd = cache['param_paths_dict_upd']

        bulkInsert = []
        for i in range(batch_size):
            param_values = {param['name']: DataManager.generate_param_value(param) for param in parameters}
            final_command = self._replace_all_params(json_template, param_paths_dict, param_values)
            bulkInsert.append(final_command)
        
        upd_command = self._replace_all_params(update_template, param_paths_dict_upd, param_values)

        collection_name = command.get('collection')
        collection = db[collection_name] if collection_name else None

        db_op = None
        projection = None
        limit = 0
        sort = None

        if command_type == 'insert':
            if batch_size > 1:
                db_op = lambda: collection.insert_many(bulkInsert, ordered=False)
            else:
                db_op = lambda: collection.insert_one(final_command)
        elif command_type == 'aggregate':
            db_op = lambda: collection.aggregate(final_command).to_list()
        elif command_type == 'find':
            projection = command.get('projection', None)
            limit = command.get('limit', 0)
            sort = command.get('sort', None)
            db_op = lambda: collection.find(filter=final_command, projection=projection, limit=limit, sort=sort).to_list()
        elif command_type == 'update':
            db_op = lambda: collection.update_one(final_command, upd_command, upsert=True)
        elif command_type == 'replace':
            db_op = lambda: collection.replace_one(final_command, upd_command, upsert=True)
        elif command_type == 'delete':
            db_op = lambda: collection.delete_one(final_command)
        else:
            logging.error(f"Unsupported DocumentDB command type: {command_type}")
            return

        logging.debug(f"Executing DocumentDB {command_type} command: {final_command}{', update: ' + str(upd_command) if upd_command else ''}{', projection: ' + str(projection) if projection else ''}{', limit: ' + str(limit) if limit else ''}{', sort: ' + str(sort) if sort else ''}")

        start_time = time.perf_counter()
        try:
            result = db_op()
            total_time = int((time.perf_counter() - start_time) * 1000)
            logging.debug(f"DocumentDB {command_type} command result: {result}")
            length = sys.getsizeof(result)
            self._fire_event('DocumentDB', task_name, total_time, response_length=length)
        except Exception as e:
            total_time = int((time.perf_counter() - start_time) * 1000)
            self._fire_event('DocumentDB-Error', task_name, total_time, exception=e)
            logging.exception(f"Error executing DocumentDB command: {e}")

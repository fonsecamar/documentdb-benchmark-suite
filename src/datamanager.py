from datetime import datetime, timezone
from faker import Faker
from bson import ObjectId

import random
import uuid
import re
import logging

class DataManager:
    faker = Faker()
    
    _default_date_format = "%Y-%m-%dT%H:%M:%S.%fZ"

    # Regex cache for concat (avoid recompiling)
    _concat_pattern = re.compile(r"\{@\w+\}")
    
    # Type-to-function mapping (avoid giant if/elif chain)
    _type_generators = {
        'guid': lambda p, v: uuid.uuid4(),
        'objectid': lambda p, v: ObjectId(),
        'datetime': lambda p, v: datetime.strptime(
            datetime.now(timezone.utc).strftime(p.get('format', DataManager._default_date_format)),
            p.get('format', DataManager._default_date_format)
        ),
        'unix_timestamp': lambda p, v: int(datetime.now(timezone.utc).timestamp()),
        'random_int': lambda p, v: random.randint(p.get('start', 0), p.get('end', 100)),
        'random_float': lambda p, v: random.uniform(p.get('start', 0.0), p.get('end', 1.0)),
        'random_list': lambda p, v: random.choice(p.get('list', [])),
        'random_bool': lambda p, v: random.choice([True, False]),
        'random_string': lambda p, v: ''.join(random.choice(
            p.get('chars', "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        ) for _ in range(p.get('length', 10))),
        'constant': lambda p, v: p.get('value'),
    }
    
    @staticmethod
    def generate_param_value(param, values=None):
        param_type = param.get('type').lower()
        values = values or {}

        raw_value = DataManager._generate_raw_value(param_type, param, values)
        
        output_type = param.get('as')
        if output_type:
            converted_value = DataManager._convert_type(raw_value, output_type.lower(), param)
            return converted_value
        
        return raw_value

    @staticmethod
    def _generate_raw_value(param_type, param, values):
        """Generates raw value based on type (optimized with dict lookup)."""
        
        # Dict lookup is O(1) vs if/elif which is O(n)
        if param_type in DataManager._type_generators:
            return DataManager._type_generators[param_type](param, values)
        
        # Concat needs special logic
        if param_type == "concat":
            return DataManager._handle_concat(param, values)
        
        # Faker integration with method chaining support
        if param_type.startswith("faker."):
            return DataManager._call_faker_method(param_type[6:], param)
        
        logging.warning(f"Unknown parameter type: {param_type}. Returning empty string.")
        return ""
    
    @staticmethod
    def _handle_concat(param, values):
        """Concat optimization using list comprehension and cached regex."""
        value_str = param.get('value', '')
        parts = []
        last_end = 0
        
        for match in DataManager._concat_pattern.finditer(value_str):
            # Add text before placeholder
            parts.append(value_str[last_end:match.start()])
            # Add placeholder value
            key = match.group(0)[2:-1]  # Remove {@...}
            parts.append(str(values.get(key, '')))
            last_end = match.end()
        
        # Add remaining string
        if last_end < len(value_str):
            parts.append(value_str[last_end:])
        
        return ''.join(parts)

    @staticmethod
    def _convert_type(value, target_type, param):
        """Converts a value to the specified type (optimized)."""
        
        try:
            # String conversion (most common)
            if target_type in ("string", "str"):
                if isinstance(value, uuid.UUID):
                    return str(value)
                if isinstance(value, ObjectId):
                    return str(value)
                if isinstance(value, datetime):
                    return value.strftime(param.get('format', DataManager._default_date_format))
                return str(value)
            
            # Int conversion
            if target_type in ("int", "integer"):
                if isinstance(value, bool):
                    return 1 if value else 0
                if isinstance(value, str):
                    # Optimization: filter is faster than loop
                    cleaned = ''.join(filter(lambda c: c.isdigit() or c == '-', value))
                    return int(cleaned) if cleaned else 0
                return int(value)
            
            # Float conversion
            if target_type in ("float", "decimal"):
                if isinstance(value, str):
                    cleaned = ''.join(filter(lambda c: c.isdigit() or c in '.-', value))
                    return float(cleaned) if cleaned else 0.0
                return float(value)
            
            # Bool conversion
            if target_type in ("bool", "boolean"):
                if isinstance(value, str):
                    return value.lower() in ('true', '1', 'yes', 'y')
                return bool(value)
            
            # Hex conversion
            if target_type == "hex":
                if isinstance(value, uuid.UUID):
                    return value.hex
                if isinstance(value, int):
                    return hex(value)
                return str(value)
            
            # Case conversions
            if target_type == "upper":
                return str(value).upper()
            
            if target_type == "lower":
                return str(value).lower()
            
            # Bytes conversion
            if target_type == "bytes":
                if isinstance(value, uuid.UUID):
                    return value.bytes
                return str(value).encode('utf-8')
            
            logging.warning(f"Unknown conversion type: {target_type}. Returning value as-is.")
            return value
                
        except Exception as e:
            logging.error(f"Error converting value to {target_type}: {e}")
            return value

    @staticmethod
    def _call_faker_method(method_name, param):
        """
        Calls a Faker method dynamically with automatic method chaining support.
        
        YAML examples:
        - type: faker.email                    # Simple: faker.email()
        - type: faker.name                     # Simple: faker.name()
        - type: faker.date_time.timestamp      # Chain: faker.date_time().timestamp()
        - type: faker.address.replace          # Chain: faker.address().replace(...)
          args:
            old: "\n"
            new: ", "
        """
        try:
            # Parse method chain (e.g., "date_time.timestamp" -> ["date_time", "timestamp"])
            method_parts = method_name.split('.')
            
            # Get the first Faker method
            first_method = method_parts[0]
            faker_method = getattr(DataManager.faker, first_method, None)
            if faker_method is None:
                logging.warning(f"Faker method '{first_method}' not found. Returning empty string.")
                return ""
            
            # Execute first method (args only apply to first method)
            args = param.get('args', {})
            result = faker_method(**args) if callable(faker_method) else faker_method
            
            # Chain remaining methods automatically
            for method_part in method_parts[1:]:
                if hasattr(result, method_part):
                    chained_method = getattr(result, method_part)
                    # For chained methods, args apply to them
                    result = chained_method(**args) if callable(chained_method) and method_part == method_parts[-1] and args else (
                        chained_method() if callable(chained_method) else chained_method
                    )
                else:
                    logging.warning(f"Method '{method_part}' not found on result. Stopping chain.")
                    break
            
            # Convert datetime if needed
            if isinstance(result, datetime):
                return result.strftime(param.get('format', DataManager._default_date_format))
            
            return result
                
        except Exception as e:
            logging.error(f"Error calling Faker method '{method_name}': {e}")
            return ""
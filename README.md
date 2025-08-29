# DocumentDB Benchmarking Suite

## Objectives

This project enables comprehensive DocumentDB benchmarking using your own custom payloads and queries, designed to reflect real-world performance comparisons.

It provides a consistent and repeatable way to measure and compare database throughput, latency, and scalability across different environments.

The benchmarking suite is built for easy deployment, supporting both local execution with Docker and scalable deployments on Azure Kubernetes Service (AKS).

## About Locust

[Locust](https://locust.io/) is an open-source load testing tool that allows you to define user behavior in Python code and simulate millions of concurrent users. Locust is highly scalable, distributed, and provides a web-based UI for monitoring test progress and results. For more details, see the [Locust documentation](https://docs.locust.io/en/stable/).

## Installation Requirements

- Python 3.8+ (local execution)
- Docker (local Docker deployment)
- Azure CLI (AKS deployment)
- Bicep (AKS deployment)
- kubectl (AKS deployment)
- A pre-existing DocumentDB cluster for testing

## Configuration
Workload configuration files are located in the `config` directory.
You can edit the existing YAML template file or add more to define and customize benchmarking scenarios for DocumentDB.
Each YAML file appears as a user class in the Locust UI, allowing you to select and run different workloads.

When deploying to AKS, these configuration files are uploaded to the `config` File Share in Azure Blob Storage and should be updated there as needed.
For local runs, the `config` folder is mounted directly into the container, so no upload is required.

> [!NOTE]
>
> If you change a configuration file after Locust has started, you must restart the pods for changes to take effect.

### Preparing a workload test

- Edit or add a YAML file in `config/` (see `config/documentdb_workload.yaml` for an example). Each file defines a `tasks` array. Each task must have a `taskName`, a `taskWeight`, and a `command` object that describes the DB operation.

- Supported command types (in `command.type`): `insert`, `replace`, `update`, `delete`, `find`, `aggregate`.

- Common `command` fields:
  - `database`: database name to use
  - `collection`: collection name
  - `batchSize`: number of documents to generate per operation (used for inserts)
  - `parameters`: an array of parameter definitions used inside `document`, `filter`, `update`, or `pipeline` templates
  - `document` (for `insert`): JSON template for the document body (use parameter placeholders for dynamic values)
  - `filter` (for `find`, `delete`, `update`, `replace`): JSON template used as query/filter
  - `update` (for `update`): MongoDB update document (e.g. `$set`)
  - `replacement` (for `replace`): replacement document for `replace` operations
  - `projection`, `limit`, `sort` (for `find`)
  - `pipeline` (for `aggregate`): array of pipeline stages

- Parameter placeholders inside `document`, `filter`, `update`, and `pipeline` are simple string matches. Example: use the parameter name `"@player_id"` in both the `parameters` list and the template where it should be substituted.

### Supported parameter generators

The project uses `src/datamanager.py` to generate parameter values. Supported `type` values:

- guid
- objectid
- date
- datetime
- datetimeiso
- unix_timestamp
- unix_timestamp_as_string
- random_int
- random_int_as_string
- random_list
- random_bool
- random_string
- faker.timestamp
- faker.firstname
- faker.lastname
- faker.fullname
- faker.dateofbirth
- faker.address
- faker.phone
- faker.email
- faker.ipv6
- faker.ipv4
- faker.msisdn
- constant_string
- constant_int
- concat (use the '{@paramName}' pattern inside the `value` to insert other parameter values)

## Running local

1. Install Python dependencies:
```pwsh
pip install -r ./src/requirements.txt
```

2. Run locust
```pwsh
locust -f ./src/main.py --class-picker
```

## Local Deployment with Docker

1. Build the Docker image:
```pwsh
docker build -t documentdbbenchmark:latest ./src
```

2. Run the container:
```pwsh
docker run -p 8089:8089 -e LOCUST_OPTIONS="--class-picker" -v ${PWD}/config/:/app/config -d documentdbbenchmark:latest
```

## Deployment on Azure Kubernetes Service (AKS)

1. Setup Azure infrastructure:
```pwsh
./deploy/setupAKS.ps1 -ResourceGroupName <resource group name> -Location <location> [-AksName <aks name> -StorageAccountName <storage account> -AcrName <container registry> -Suffix <resource suffix> -AksVMSku <vm sku>]
```

> Resources created:
> - Resource group
> - Azure Blob Storage Standard and a File Share
> - Azure Container Registry Basic
> - Azure Kubernetes Services with 2 node pools
>
>> Database resources for performance testing are not created by this template.


2. Port-forward Locust master:
```pwsh
kubectl port-forward service/master 8089:8089
```

3. Access the Locust UI at http://localhost:8089. Select the workload profile, specify the number of users and ramp details, enter your database credentials in the `Custom` section and start the test.

### Useful commands

- Scale worker replicas:
```pwsh
kubectl scale deployment locust-worker --replicas <number of pods>
```

- Restart pods:
```pwsh
kubectl rollout restart deployment --namespace default
```
# Best Practice for Reporting Huawei Cloud LTS Logs to TrueWatch
## 1. Background and Challenges
The customer's business system is deployed on Huawei Cloud, using products like ELB and GaussDB,or other middlewares. Log centralized management relies on Huawei Cloud LTS, but storing logs only in LTS makes it difficult to achieve:
- Full-link observability (unification of logs, metrics, and trace data)
- Intelligent retrieval and alerting (cross-cluster, cross-application log analysis)
- Visualization and tracking combined with business metrics

TrueWatch enables unified full-link observability. Real-time reporting of LTS logs is required to integrate logs with applications, infrastructure, user experience, etc., for integrated observability.


## 2. Overall Architecture Design
### Architecture Diagram (Mermaid Format)
```mermaid
graph LR
    A[Huawei Cloud Products<br/>(ELB, GaussDB, etc.)] -->|Log Output| B[LTS Log Service]
    B -->|Real-time Dump| C[DMS Kafka Message Channel]
    C -->|Log Consumption| D[DataKit Kafka Input<br/>(Deployed on Client-side such as ECS)]
    D -->|Send Logs| E[TrueWatch]
    E -->|Function Support| F[Visual Analysis]
    E -->|Function Support| G[Log Viewing]
    E -->|Function Support| H[Log Storage]
    E -->|Function Support| I[Intelligent Alerting]
    E -->|Function Support| J[Unified Log Retrieval]
```

### Component Description
- **LTS**: Responsible for log collection and centralized management
- **DMS Kafka**: A highly reliable message channel that enables real-time log dumping and decoupling
- **DataKit Kafka Input**: Deployed on the client side (e.g., Elastic Cloud Server), consumes Kafka logs and sends them to TrueWatch
- **TrueWatch**: Provides functions like unified log retrieval, query analysis, dashboard display, and intelligent alerting


## 3. Prerequisites
1. Create DMS and LTS services on Huawei Cloud
2. Activate a TrueWatch account
3. Prepare an VM for deploying DataKit,or leverage any existing Datakit


## 4. Configuration Steps
### Step 1: Enable Log Dumping in LTS
Next, we will use the Huawei Cloud ELB Service as an example to explain how to configure the LTS-DMS-DataKit forwarding pipeline. Please note that if you are using other cloud services, please replace the topic name or related naming conventions with those corresponding to the cloud service you need to collect data from.


#### Huawei Cloud ELB log forwarding example:
1. Log in to the Huawei Cloud Console → LTS Console
2. Click "Log Dump"
3. Configure the dump target:
   - Dump Object: Select DMS instance
   - Log Group Name: Its-group-SLB  <-- you can pick other name and replace it here
   - Log Stream Name: Its-topic-SLB <-- you can pick other name and replace it here
   - Kafka Instance: kafka-1602029427
   - Topic: topic-30039942
   - Dump Format: Original log format
4. After configuration, check if logs are generated in the LTS log group


### Step 2: Deploy DataKit
Please note that if you've deployed a datakit already, you can ignore this installation and turn to Step 3.

Execute the installation command in the environment to be collected (e.g., ECS) (replace the token with the actual value of your TrueWatch space):
```bash
DK_DEF_INPUTS="cpu,mem,disk,diskio,swap,system,net,host_process,hostobject,container,dk,statsd" DK_DATAWAY="https://id1-openway.truewatch.com?token=**************" bash -c "$(curl -L https://static.truewatch.com/datakit/install.sh)" "
```


### Step 3: Enable the KafkaMQ Collector
1. Enter the `kafkamq` directory under the DataKit installation path (default: `/usr/local/datakit/conf.d/samples`)
2. Copy `kafkamq.conf.sample` and rename it to `kafkamq.conf`
3. Adjust core configurations:
```ini
# {"version": "1.81.1", "desc": "do NOT edit this line"}
[[inputs.kafkamq]]
  # Where to get this address: Huawei Cloud DMS Kafka instance connection address (IP + port)
  addrs = ["192.168.0.106:9092"]
  kafka_version = "3.0.0"  # Corresponding to the Kafka version in use
  group_id = "datakit-group"  # Consumer group name
  assignor = "roundrobin"  # Partition assignment strategy
  offsets=-1  # -1: Latest offset, -2: Earliest offset

  [inputs.kafkamq.custom]
    [inputs.kafkamq.custom.log_topic_map]
      "<YOUR-TOPIC-NAME-1>"=""
	  "<YOUR-TOPIC-NAME-2>"=""
      ...

```
**Note**: the config sections [inputs.kafkamq.custom] and [inputs.kafkamq.custom.log_topic_map] must be uncommented and edited, the datakit kafka input use those keys under log_topic_map config block to decide which topic to consume.

#### How to Obtain the Kafka Address (`addrs` Value)
The `addrs` is the **connection address (IP + port) of the Huawei Cloud DMS Kafka instance** (where LTS dumps logs). To get it:
1. Log in to Huawei Cloud Console → Go to "Distributed Message Service (DMS)" → Select the target Kafka instance;
2. In the instance's "Basic Information" page, find the "Connection Information" section;
3. Select the appropriate address:
   - If DataKit is deployed in Huawei Cloud VPC (e.g., ECS), use the **Private Network Address**;
   - If DataKit is deployed outside Huawei Cloud, enable public network access for the Kafka instance first, then use the **Public Network Address**;
4. Copy the IP + port (e.g., `192.168.0.106:9092`) and fill it into the `addrs` field.


### Step 4: Restart DataKit to Take Effect
```bash
datakit service -R
```


### Step 5: Verify Log Access in TrueWatch
1. Log in to the TrueWatch Console → Log Viewer, and check that relevant logs have been collected
2. Verify the log field extraction results, ensuring fields like `backend_ip`, `client_ip`, and `elb_response_code` are parsed correctly


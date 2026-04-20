use serde::{Deserialize, Serialize};

/// Request body for POST /v1/jobs/parse.
#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ParseJobRequest {
    #[serde(rename = "JobHCL")]
    pub job_hcl: String,
    pub canonicalize: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variables: Option<String>,
}

/// Request body for POST /v1/jobs.
#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct JobSubmitRequest<'a> {
    pub job: &'a serde_json::Value,
}

/// Response from POST /v1/jobs.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct JobSubmitResponse {
    #[serde(rename = "EvalID")]
    pub eval_id: String,
    #[serde(default)]
    pub job_modify_index: u64,
    #[serde(default)]
    pub warnings: Option<String>,
}

/// Request body for PUT /v1/job/{id}/scale.
#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ScaleRequest {
    pub count: Option<u32>,
    pub target: ScaleTarget,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ScaleTarget {
    pub group: String,
}

/// Response from GET /v1/job/{id}.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Job {
    #[serde(rename = "ID")]
    pub id: String,
    pub name: String,
    pub status: String,
    #[serde(default)]
    pub task_groups: Vec<TaskGroup>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct TaskGroup {
    pub name: String,
    pub count: u32,
}

/// Response from GET /v1/job/{id}/allocations.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Allocation {
    #[serde(rename = "ID")]
    pub id: String,
    #[serde(rename = "JobID")]
    pub job_id: String,
    pub client_status: String,
    pub desired_status: String,
    pub task_group: String,
    #[serde(default)]
    pub resources: Option<AllocResources>,
    #[serde(default)]
    pub allocated_resources: Option<AllocatedResources>,
}

impl Allocation {
    pub fn is_running(&self) -> bool {
        self.client_status == "running" && self.desired_status == "run"
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AllocResources {
    #[serde(default)]
    pub networks: Vec<NetworkResource>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AllocatedResources {
    #[serde(default)]
    pub shared: Option<SharedResources>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct SharedResources {
    #[serde(default)]
    pub ports: Vec<PortMapping>,
    #[serde(default)]
    pub networks: Vec<NetworkResource>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct NetworkResource {
    #[serde(rename = "IP")]
    pub ip: String,
    #[serde(default)]
    pub dynamic_ports: Vec<Port>,
    #[serde(default)]
    pub reserved_ports: Vec<Port>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Port {
    pub label: String,
    pub value: u16,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct PortMapping {
    pub label: String,
    pub value: u16,
    pub to: u16,
    #[serde(rename = "HostIP")]
    pub host_ip: String,
}

/// Nomad event stream types.
///
/// Nomad sends heartbeat frames as `{}` to keep the connection alive,
/// so both `index` and `events` must tolerate missing fields.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct EventStreamFrame {
    #[serde(default)]
    pub events: Vec<EventEnvelope>,
    #[serde(default)]
    pub index: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct EventEnvelope {
    pub topic: String,
    #[serde(rename = "Type")]
    pub event_type: String,
    pub payload: serde_json::Value,
}

/// Scale API response.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ScaleResponse {
    #[serde(default)]
    pub warnings: String,
}

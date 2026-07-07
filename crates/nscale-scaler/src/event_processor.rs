use std::collections::HashSet;
use std::sync::Arc;

use tokio::sync::{Mutex, mpsc};
use tracing::{debug, info, warn};

use nscale_core::job::{JobId, ScaleUnit};
use nscale_core::traits::ActivityStore;
use nscale_nomad::events::NomadEvent;
use nscale_store::registry::JobRegistry;
use nscale_waker::coordinator::WakeCoordinator;

/// Processes Nomad event stream to reactively update job states.
///
/// Replaces the polling-based approach by subscribing to `Allocation` events
/// from Nomad's `/v1/event/stream`. When an allocation transitions to running,
/// activity is recorded. When all allocations stop, the coordinator is notified
/// the job is dormant.
pub struct EventProcessor {
    coordinator: Arc<WakeCoordinator>,
    store: Arc<dyn ActivityStore>,
    registry: Arc<JobRegistry>,
    /// Allocation IDs already seen as running — prevents redundant
    /// `record_activity` calls on event stream replay / reconnect.
    seen_running: Mutex<HashSet<String>>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum AllocationEventAction {
    RecordActivity,
    MarkDormant,
    Ignore,
}

fn allocation_event_action(client_status: &str, desired_status: &str) -> AllocationEventAction {
    match (client_status, desired_status) {
        ("running", "run") => AllocationEventAction::RecordActivity,
        ("complete" | "failed" | "lost", _) | (_, "stop") => AllocationEventAction::MarkDormant,
        _ => AllocationEventAction::Ignore,
    }
}

fn stopped_allocation_should_remove_activity() -> bool {
    false
}

impl EventProcessor {
    pub fn new(
        coordinator: Arc<WakeCoordinator>,
        store: Arc<dyn ActivityStore>,
        registry: Arc<JobRegistry>,
    ) -> Self {
        Self {
            coordinator,
            store,
            registry,
            seen_running: Mutex::new(HashSet::new()),
        }
    }

    /// Consume events from the Nomad event stream and update internal state.
    pub async fn run(self, mut rx: mpsc::Receiver<NomadEvent>) {
        info!("event processor started");

        while let Some(event) = rx.recv().await {
            if let Err(e) = self.handle_event(&event).await {
                warn!(
                    error = %e,
                    topic = %event.topic,
                    event_type = %event.event_type,
                    "failed to handle nomad event"
                );
            }
        }

        info!("event processor stopped (channel closed)");
    }

    async fn handle_event(&self, event: &NomadEvent) -> nscale_core::error::Result<()> {
        match event.topic.as_str() {
            "Allocation" => self.handle_allocation_event(event).await,
            _ => {
                debug!(topic = %event.topic, "ignoring unhandled event topic");
                Ok(())
            }
        }
    }

    async fn handle_allocation_event(&self, event: &NomadEvent) -> nscale_core::error::Result<()> {
        // Extract allocation fields from the Nomad event payload.
        // The payload structure is: { "Allocation": { "JobID": "...", "ClientStatus": "...", ... } }
        let alloc = match event.payload.get("Allocation") {
            Some(a) => a,
            None => {
                debug!("allocation event missing Allocation key");
                return Ok(());
            }
        };

        let job_id_str = match alloc.get("JobID").and_then(|v| v.as_str()) {
            Some(id) => id,
            None => return Ok(()),
        };

        let alloc_id = alloc
            .get("ID")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let client_status = alloc
            .get("ClientStatus")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let desired_status = alloc
            .get("DesiredStatus")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let job_id = JobId(job_id_str.to_string());
        let alloc_group = alloc
            .get("TaskGroup")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        // Only process events for registered jobs
        let registration = match self.registry.get(&job_id).await? {
            Some(reg) => reg,
            None => return Ok(()),
        };

        // Key by the scale-to-zero unit for this allocation's group. Single-group
        // jobs collapse to the job id (unchanged); multi-group jobs use the
        // composite so each group is tracked independently.
        let unit = match (&registration.scale_unit, alloc_group.is_empty()) {
            (Some(_), false) => ScaleUnit::composite(&job_id, alloc_group),
            _ => ScaleUnit(job_id.0.clone()),
        };

        debug!(
            job_id = %job_id,
            unit = %unit,
            alloc_id = %alloc_id,
            client_status,
            desired_status,
            event_type = %event.event_type,
            "processing allocation event"
        );

        match allocation_event_action(client_status, desired_status) {
            AllocationEventAction::RecordActivity => {
                // Deduplicate: only record activity the first time we see
                // this allocation reach running state. Prevents redundant
                // writes on event stream replay / reconnect.
                let is_new = {
                    let mut seen = self.seen_running.lock().await;
                    seen.insert(alloc_id.clone())
                };
                if is_new {
                    debug!(unit = %unit, alloc_id = %alloc_id, "allocation running, recording activity");
                    self.store.record_activity(&unit).await?;
                } else {
                    debug!(unit = %unit, alloc_id = %alloc_id, "allocation already seen running, skipping activity");
                }
            }
            AllocationEventAction::MarkDormant => {
                // Allocation stopped — remove from seen-running set and check
                // if the job should be marked dormant.
                {
                    let mut seen = self.seen_running.lock().await;
                    seen.remove(&alloc_id);
                }
                debug!(
                    job_id = %job_id,
                    alloc_id = %alloc_id,
                    client_status,
                    desired_status,
                    "allocation stopped"
                );
                // We only mark dormant; the scale-down controller still handles
                // the actual scale-down decision. Do not remove activity here:
                // autoscaling N→N-1 also emits stopped allocation events while
                // the unit still has running allocations. Clearing activity here
                // would hide the unit from idle scale-to-zero checks.
                self.coordinator.mark_dormant(&unit);
                if stopped_allocation_should_remove_activity() {
                    let _ = self.store.remove_activity(&unit).await;
                }
                info!(
                    job_id = %job_id,
                    unit = %unit,
                    service_name = %registration.service_name,
                    "unit marked dormant via event stream"
                );
            }
            AllocationEventAction::Ignore => {
                debug!(
                    job_id = %job_id,
                    client_status,
                    desired_status,
                    "ignoring allocation state"
                );
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stopped_allocation_marks_dormant_without_implying_activity_removal() {
        assert_eq!(
            allocation_event_action("complete", "stop"),
            AllocationEventAction::MarkDormant
        );
        assert_eq!(
            allocation_event_action("running", "run"),
            AllocationEventAction::RecordActivity
        );
        assert_eq!(
            allocation_event_action("pending", "run"),
            AllocationEventAction::Ignore
        );
        assert!(!stopped_allocation_should_remove_activity());
    }
}

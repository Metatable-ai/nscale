use std::collections::BTreeSet;

use serde_json::Value;
use tracing::warn;

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{JobId, JobRegistration, ServiceName};

const TRAEFIK_ENABLE_TAG: &str = "traefik.enable=true";
const ROUTER_PREFIX: &str = "traefik.http.routers.";

pub fn inject_nscale_tags(
    job: &mut Value,
    file_provider_service: &str,
) -> Result<Vec<JobRegistration>> {
    let job_obj = job
        .as_object_mut()
        .ok_or_else(|| NscaleError::Nomad("parsed job is not a JSON object".to_string()))?;

    let job_id = job_obj
        .get("ID")
        .and_then(Value::as_str)
        .or_else(|| job_obj.get("Name").and_then(Value::as_str))
        .ok_or_else(|| NscaleError::Nomad("parsed job is missing ID".to_string()))?
        .to_string();

    let task_groups = job_obj
        .get_mut("TaskGroups")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| {
            NscaleError::Nomad(format!("parsed job '{}' is missing TaskGroups", job_id))
        })?;

    let mut seen = BTreeSet::new();
    let mut registrations = Vec::new();

    for task_group in task_groups {
        let task_group_obj = task_group.as_object_mut().ok_or_else(|| {
            NscaleError::Nomad(format!("task group in job '{}' is not an object", job_id))
        })?;

        let group_name = task_group_obj
            .get("Name")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                NscaleError::Nomad(format!("task group in job '{}' is missing Name", job_id))
            })?
            .to_string();

        if let Some(services) = task_group_obj
            .get_mut("Services")
            .and_then(Value::as_array_mut)
        {
            inject_service_tags(
                &job_id,
                &group_name,
                services,
                file_provider_service,
                &mut seen,
                &mut registrations,
            )?;
        }

        if let Some(tasks) = task_group_obj
            .get_mut("Tasks")
            .and_then(Value::as_array_mut)
        {
            for task in tasks {
                let task_obj = task.as_object_mut().ok_or_else(|| {
                    NscaleError::Nomad(format!(
                        "task in group '{}' of job '{}' is not an object",
                        group_name, job_id
                    ))
                })?;

                if let Some(services) = task_obj.get_mut("Services").and_then(Value::as_array_mut) {
                    inject_service_tags(
                        &job_id,
                        &group_name,
                        services,
                        file_provider_service,
                        &mut seen,
                        &mut registrations,
                    )?;
                }
            }
        }
    }

    Ok(registrations)
}

fn inject_service_tags(
    job_id: &str,
    group_name: &str,
    services: &mut [Value],
    file_provider_service: &str,
    seen: &mut BTreeSet<(String, String, String)>,
    registrations: &mut Vec<JobRegistration>,
) -> Result<()> {
    for service in services {
        let service_obj = service.as_object_mut().ok_or_else(|| {
            NscaleError::Nomad(format!(
                "service in group '{}' of job '{}' is not an object",
                group_name, job_id
            ))
        })?;

        let service_name = service_obj
            .get("Name")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                NscaleError::Nomad(format!(
                    "service in group '{}' of job '{}' is missing Name",
                    group_name, job_id
                ))
            })?
            .to_string();

        let tags_value = service_obj
            .entry("Tags".to_string())
            .or_insert_with(|| Value::Array(Vec::new()));
        let tags = tags_value.as_array_mut().ok_or_else(|| {
            NscaleError::Nomad(format!(
                "service '{}' in group '{}' of job '{}' has non-array Tags",
                service_name, group_name, job_id
            ))
        })?;

        let has_traefik_enabled = tags
            .iter()
            .filter_map(Value::as_str)
            .any(|tag| tag == TRAEFIK_ENABLE_TAG);
        if !has_traefik_enabled {
            continue;
        }

        let router_names = collect_router_names(tags);
        if router_names.is_empty() {
            return Err(NscaleError::Nomad(format!(
                "traefik-enabled service '{}' in group '{}' of job '{}' is missing explicit router tags",
                service_name, group_name, job_id
            )));
        }

        for router_name in router_names {
            upsert_router_service_tag(tags, &router_name, file_provider_service);
        }

        if seen.insert((
            job_id.to_string(),
            service_name.clone(),
            group_name.to_string(),
        )) {
            registrations.push(JobRegistration {
                job_id: JobId(job_id.to_string()),
                service_name: ServiceName(service_name),
                nomad_group: group_name.to_string(),
            });
        }
    }

    Ok(())
}

fn collect_router_names(tags: &[Value]) -> BTreeSet<String> {
    tags.iter()
        .filter_map(Value::as_str)
        .filter_map(|tag| tag.strip_prefix(ROUTER_PREFIX))
        .filter_map(|tag| {
            tag.split_once('.')
                .map(|(router_name, _)| router_name.to_string())
        })
        .collect()
}

fn upsert_router_service_tag(
    tags: &mut Vec<Value>,
    router_name: &str,
    file_provider_service: &str,
) {
    let prefix = format!("{ROUTER_PREFIX}{router_name}.service=");
    let desired = format!("{prefix}{file_provider_service}");

    let mut matching_indexes = tags
        .iter()
        .enumerate()
        .filter_map(|(index, value)| {
            value
                .as_str()
                .filter(|tag| tag.starts_with(&prefix))
                .map(|_| index)
        })
        .collect::<Vec<_>>();

    if let Some(first_index) = matching_indexes.first().copied() {
        if tags[first_index].as_str() != Some(desired.as_str()) {
            if let Some(existing) = tags[first_index].as_str() {
                warn!(
                    router_name,
                    old = existing,
                    new = desired,
                    "overriding Traefik router service tag for nscale"
                );
            }
            tags[first_index] = Value::String(desired.clone());
        }

        for index in matching_indexes.drain(1..).rev() {
            tags.remove(index);
        }

        return;
    }

    tags.push(Value::String(desired));
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::inject_nscale_tags;

    #[test]
    fn injects_nscale_tag_into_task_level_service() {
        let mut job = json!({
            "ID": "echo-s2z",
            "TaskGroups": [{
                "Name": "main",
                "Tasks": [{
                    "Name": "echo",
                    "Services": [{
                        "Name": "echo-s2z",
                        "Tags": [
                            "traefik.enable=true",
                            "traefik.http.routers.echo-s2z.rule=Host(`echo-s2z.localhost`)",
                            "traefik.http.routers.echo-s2z.entryPoints=http"
                        ]
                    }]
                }]
            }]
        });

        let registrations = inject_nscale_tags(&mut job, "s2z-nscale@file").unwrap();

        let tags = job["TaskGroups"][0]["Tasks"][0]["Services"][0]["Tags"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>();

        assert!(tags.contains(&"traefik.http.routers.echo-s2z.service=s2z-nscale@file"));
        assert_eq!(registrations.len(), 1);
        assert_eq!(registrations[0].job_id.0, "echo-s2z");
        assert_eq!(registrations[0].service_name.0, "echo-s2z");
        assert_eq!(registrations[0].nomad_group, "main");
    }

    #[test]
    fn injects_group_level_services_and_overrides_existing_target() {
        let mut job = json!({
            "ID": "api-job",
            "TaskGroups": [{
                "Name": "main",
                "Services": [{
                    "Name": "api",
                    "Tags": [
                        "traefik.enable=true",
                        "traefik.http.routers.api.rule=Host(`api.example.com`)",
                        "traefik.http.routers.api.service=consulcatalog"
                    ]
                }]
            }]
        });

        let registrations = inject_nscale_tags(&mut job, "s2z-nscale@file").unwrap();
        let tags = job["TaskGroups"][0]["Services"][0]["Tags"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>();

        assert!(tags.contains(&"traefik.http.routers.api.service=s2z-nscale@file"));
        assert!(!tags.contains(&"traefik.http.routers.api.service=consulcatalog"));
        assert_eq!(registrations.len(), 1);
        assert_eq!(registrations[0].service_name.0, "api");
    }

    #[test]
    fn injects_all_traefik_enabled_services() {
        let mut job = json!({
            "ID": "multi-service-job",
            "TaskGroups": [{
                "Name": "main",
                "Tasks": [{
                    "Name": "svc-a-task",
                    "Services": [{
                        "Name": "svc-a",
                        "Tags": [
                            "traefik.enable=true",
                            "traefik.http.routers.svc-a.rule=Host(`a.example.com`)"
                        ]
                    }]
                }, {
                    "Name": "svc-b-task",
                    "Services": [{
                        "Name": "svc-b",
                        "Tags": [
                            "traefik.enable=true",
                            "traefik.http.routers.svc-b.rule=Host(`b.example.com`)"
                        ]
                    }, {
                        "Name": "internal",
                        "Tags": ["other.tag=true"]
                    }]
                }]
            }]
        });

        let registrations = inject_nscale_tags(&mut job, "s2z-nscale@file").unwrap();

        assert_eq!(registrations.len(), 2);
        assert_eq!(registrations[0].job_id.0, "multi-service-job");
        assert_eq!(registrations[1].job_id.0, "multi-service-job");
        assert_eq!(registrations[0].nomad_group, "main");
        assert_eq!(registrations[1].nomad_group, "main");
    }

    #[test]
    fn injection_is_idempotent() {
        let mut job = json!({
            "ID": "echo-s2z",
            "TaskGroups": [{
                "Name": "main",
                "Tasks": [{
                    "Name": "echo",
                    "Services": [{
                        "Name": "echo-s2z",
                        "Tags": [
                            "traefik.enable=true",
                            "traefik.http.routers.echo-s2z.rule=Host(`echo-s2z.localhost`)",
                            "traefik.http.routers.echo-s2z.service=s2z-nscale@file"
                        ]
                    }]
                }]
            }]
        });

        let first = inject_nscale_tags(&mut job, "s2z-nscale@file").unwrap();
        let second = inject_nscale_tags(&mut job, "s2z-nscale@file").unwrap();
        let tags = job["TaskGroups"][0]["Tasks"][0]["Services"][0]["Tags"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|tag| *tag == "traefik.http.routers.echo-s2z.service=s2z-nscale@file")
            .count();

        assert_eq!(first.len(), 1);
        assert_eq!(second.len(), 1);
        assert_eq!(tags, 1);
    }

    #[test]
    fn errors_when_traefik_router_name_is_missing() {
        let mut job = json!({
            "ID": "broken-job",
            "TaskGroups": [{
                "Name": "main",
                "Tasks": [{
                    "Name": "web",
                    "Services": [{
                        "Name": "broken",
                        "Tags": ["traefik.enable=true"]
                    }]
                }]
            }]
        });

        let error = inject_nscale_tags(&mut job, "s2z-nscale@file").unwrap_err();
        assert!(error.to_string().contains("missing explicit router tags"));
    }
}

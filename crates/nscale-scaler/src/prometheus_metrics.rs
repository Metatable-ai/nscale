use std::collections::BTreeSet;
use std::time::Duration;

use async_trait::async_trait;
use nscale_core::error::{NscaleError, Result};
use nscale_core::job::JobRegistration;
use serde::Deserialize;

use crate::autoscale_policy::MetricSnapshot;
use crate::metrics_provider::MetricsProvider;

const ERROR_RATE_DENOMINATOR_FLOOR: &str = "0.000001";

pub struct PrometheusMetricsProvider {
    client: reqwest::Client,
    base_url: String,
    provider: String,
}

impl PrometheusMetricsProvider {
    pub fn new(base_url: &str, provider: &str, timeout: Duration) -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(timeout)
                .build()
                .expect("failed to build HTTP client for Prometheus autoscaling metrics"),
            base_url: base_url.trim_end_matches('/').to_string(),
            provider: provider.to_string(),
        }
    }

    async fn query(&self, query: &str) -> Result<Option<f64>> {
        let url = format!("{}/api/v1/query", self.base_url);
        let resp = self
            .client
            .get(&url)
            .query(&[("query", query)])
            .send()
            .await
            .map_err(|e| NscaleError::Consul(format!("prometheus query failed: {e}")))?;

        if !resp.status().is_success() {
            return Err(NscaleError::Consul(format!(
                "prometheus query returned {}",
                resp.status()
            )));
        }

        let body = resp
            .text()
            .await
            .map_err(|e| NscaleError::Consul(format!("failed to read prometheus response: {e}")))?;

        parse_prometheus_instant_value(&body)
    }
}

#[async_trait]
impl MetricsProvider for PrometheusMetricsProvider {
    async fn snapshot(
        &self,
        registration: &JobRegistration,
        window: Duration,
    ) -> Result<MetricSnapshot> {
        let regex = label_regex_for_registration(registration, &self.provider);
        let escaped_job = escape_label_value(&registration.job_id.0);
        let range = prometheus_window(window);

        let request_rate_query = traefik_request_rate_query(&regex, &range, None);
        let error_count_query = traefik_request_rate_query(&regex, &range, Some("5.."));
        let error_rate_query = format!(
            "({error_count_query}) / clamp_min(({request_rate_query}), {ERROR_RATE_DENOMINATOR_FLOOR})"
        );
        let latency_query = format!(
            "histogram_quantile(0.95, sum by (le) (rate(nscale_proxy_request_duration_seconds_bucket{{job_id=\"{escaped_job}\"}}[{range}]))) * 1000"
        );

        Ok(MetricSnapshot {
            request_rate_rps: self.query(&request_rate_query).await?,
            p95_latency_ms: self.query(&latency_query).await?,
            error_rate: self.query(&error_rate_query).await?,
            in_flight: None,
        })
    }
}

fn traefik_request_rate_query(regex: &str, range: &str, code_filter: Option<&str>) -> String {
    let code_matcher = code_filter
        .map(|code| format!(",code=~\"{code}\""))
        .unwrap_or_default();

    format!(
        "(sum(rate(traefik_router_requests_total{{router=~\"{regex}\"{code_matcher}}}[{range}])) or vector(0)) + (sum(rate(traefik_service_requests_total{{service=~\"{regex}\"{code_matcher}}}[{range}])) or vector(0))"
    )
}

fn metric_labels_for_registration(registration: &JobRegistration, provider: &str) -> Vec<String> {
    let mut labels = BTreeSet::new();
    labels.insert(format!("{}@{}", registration.service_name.0, provider));
    for router in &registration.traefik_routers {
        labels.insert(format!("{}@{}", router, provider));
    }
    labels.into_iter().collect()
}

fn label_regex_for_registration(registration: &JobRegistration, provider: &str) -> String {
    metric_labels_for_registration(registration, provider)
        .into_iter()
        .map(|label| escape_label_value(&escape_regex_literal(&label)))
        .collect::<Vec<_>>()
        .join("|")
}

fn escape_regex_literal(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\\' | '.' | '+' | '*' | '?' | '(' | ')' | '|' | '[' | ']' | '{' | '}' | '^' | '$' => {
                escaped.push('\\');
                escaped.push(ch);
            }
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn escape_label_value(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

pub fn prometheus_window(window: Duration) -> String {
    format!("{}s", window.as_secs())
}

pub fn parse_prometheus_instant_value(body: &str) -> Result<Option<f64>> {
    let response: PrometheusInstantResponse = serde_json::from_str(body)?;
    if response.status != "success" {
        return Err(NscaleError::Consul(format!(
            "prometheus query status was {}",
            response.status
        )));
    }
    if response.data.result_type != "vector" {
        return Err(NscaleError::Consul(format!(
            "prometheus query returned {} result",
            response.data.result_type
        )));
    }

    let Some(sample) = response.data.result.first() else {
        return Ok(None);
    };
    let Some(value) = sample.value.get(1).and_then(serde_json::Value::as_str) else {
        return Ok(None);
    };

    Ok(value.parse::<f64>().ok().filter(|value| value.is_finite()))
}

#[derive(Deserialize)]
struct PrometheusInstantResponse {
    status: String,
    data: PrometheusInstantData,
}

#[derive(Deserialize)]
struct PrometheusInstantData {
    #[serde(rename = "resultType")]
    result_type: String,
    result: Vec<PrometheusInstantSample>,
}

#[derive(Deserialize)]
struct PrometheusInstantSample {
    value: Vec<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics_provider::MetricsProvider;
    use nscale_core::job::{JobId, JobRegistration, ServiceName};
    use std::time::Duration;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn formats_prometheus_range_window() {
        assert_eq!(prometheus_window(Duration::from_secs(30)), "30s");
        assert_eq!(prometheus_window(Duration::from_secs(90)), "90s");
    }

    #[test]
    fn parses_single_vector_value() {
        let body = r#"{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[123,"4.5"]}]}}"#;
        assert_eq!(parse_prometheus_instant_value(body).unwrap(), Some(4.5));
    }

    #[test]
    fn parses_empty_vector_as_missing_metric() {
        let body = r#"{"status":"success","data":{"resultType":"vector","result":[]}}"#;
        assert_eq!(parse_prometheus_instant_value(body).unwrap(), None);
    }

    #[test]
    fn parses_nan_vector_as_missing_metric() {
        let body = r#"{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[123,"NaN"]}]}}"#;
        assert_eq!(parse_prometheus_instant_value(body).unwrap(), None);
    }

    #[test]
    fn escapes_label_regex_for_promql_string_context() {
        let registration = JobRegistration {
            job_id: JobId("api".to_string()),
            service_name: ServiceName("api.v1(blue)".to_string()),
            nomad_group: "api".to_string(),
            autoscaling: None,
            traefik_routers: vec!["route\"north\nwest\\edge".to_string()],
        };

        assert_eq!(
            label_regex_for_registration(&registration, "consul.catalog?"),
            "api\\\\.v1\\\\(blue\\\\)@consul\\\\.catalog\\\\?|route\\\"north\\nwest\\\\\\\\edge@consul\\\\.catalog\\\\?"
        );
    }

    #[test]
    fn traefik_request_query_zero_fills_missing_router_or_service_metrics() {
        let query = traefik_request_rate_query("api@consulcatalog", "60s", None);

        assert!(query.contains("or vector(0)"));
        assert!(query.contains("traefik_router_requests_total"));
        assert!(query.contains("traefik_service_requests_total"));
        assert!(!query.contains("clamp_min"));
    }

    #[test]
    fn traefik_error_rate_query_preserves_low_volume_error_ratios() {
        let request_rate_query = traefik_request_rate_query("api@consulcatalog", "60s", None);
        let error_count_query = traefik_request_rate_query("api@consulcatalog", "60s", Some("5.."));
        let error_rate_query = format!(
            "({error_count_query}) / clamp_min(({request_rate_query}), {ERROR_RATE_DENOMINATOR_FLOOR})"
        );

        assert!(error_rate_query.contains("code=~\"5..\""));
        assert!(error_rate_query.contains("clamp_min("));
        assert!(error_rate_query.contains(ERROR_RATE_DENOMINATOR_FLOOR));
        assert!(!error_rate_query.contains("clamp_min((sum"));
        assert!(!error_rate_query.contains(", 1)"));
    }

    #[tokio::test]
    async fn snapshot_preserves_empty_vector_metrics_as_missing() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v1/query"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(
                r#"{"status":"success","data":{"resultType":"vector","result":[]}}"#,
                "application/json",
            ))
            .expect(3)
            .mount(&server)
            .await;
        let provider =
            PrometheusMetricsProvider::new(&server.uri(), "consulcatalog", Duration::from_secs(1));

        let snapshot = provider
            .snapshot(&registration(), Duration::from_secs(30))
            .await
            .unwrap();

        assert_eq!(snapshot.request_rate_rps, None);
        assert_eq!(snapshot.p95_latency_ms, None);
        assert_eq!(snapshot.error_rate, None);
        assert_eq!(snapshot.in_flight, None);
    }

    #[tokio::test]
    async fn snapshot_returns_error_on_prometheus_http_failure() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v1/query"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;
        let provider =
            PrometheusMetricsProvider::new(&server.uri(), "consulcatalog", Duration::from_secs(1));

        let err = provider
            .snapshot(&registration(), Duration::from_secs(30))
            .await
            .unwrap_err();

        assert!(err.to_string().contains("prometheus query returned 500"));
    }

    fn registration() -> JobRegistration {
        JobRegistration {
            job_id: JobId("api".to_string()),
            service_name: ServiceName("api".to_string()),
            nomad_group: "api".to_string(),
            autoscaling: None,
            traefik_routers: vec!["api-router".to_string()],
        }
    }
}

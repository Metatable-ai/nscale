use nscale_core::job::JobAutoscalingPolicy;

#[derive(Debug, Clone, Default)]
pub struct MetricSnapshot {
    pub request_rate_rps: Option<f64>,
    pub p95_latency_ms: Option<f64>,
    pub error_rate: Option<f64>,
    pub in_flight: Option<u64>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum AutoscaleDirection {
    Up,
    Down,
    None,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct AutoscaleDecision {
    pub current_count: u32,
    pub desired_count: u32,
    pub direction: AutoscaleDirection,
    pub reason: String,
}

pub fn decide_autoscale(
    policy: &JobAutoscalingPolicy,
    current_count: u32,
    metrics: &MetricSnapshot,
    downscale_blocked: bool,
) -> AutoscaleDecision {
    let mut raw_desired: Option<u32> = None;
    let mut reasons = Vec::new();

    if let (Some(rate), Some(target)) = (
        metrics.request_rate_rps,
        policy.target_requests_per_second_per_instance,
    ) && target > 0.0
    {
        let desired = (rate / target).ceil().max(policy.min_count as f64) as u32;
        raw_desired = Some(desired);
        reasons.push("request-rate");
    }

    if let (Some(latency), Some(target)) = (metrics.p95_latency_ms, policy.target_p95_latency_ms) {
        if latency > target {
            raw_desired = Some(
                raw_desired
                    .unwrap_or(current_count)
                    .max(current_count + policy.scale_up_step),
            );
        } else {
            raw_desired = Some(
                raw_desired
                    .unwrap_or(policy.min_count)
                    .max(policy.min_count),
            );
        }
        reasons.push("latency");
    }

    if let (Some(error_rate), Some(max_error_rate)) = (metrics.error_rate, policy.max_error_rate) {
        if error_rate > max_error_rate {
            raw_desired = Some(raw_desired.unwrap_or(current_count).max(current_count + 1));
        } else {
            raw_desired = Some(
                raw_desired
                    .unwrap_or(policy.min_count)
                    .max(policy.min_count),
            );
        }
        reasons.push("error-rate");
    }

    let Some(raw_desired) = raw_desired else {
        return no_change(current_count, "missing-metrics");
    };

    let clamped = raw_desired.clamp(policy.min_count, policy.max_count);
    let desired_count = if clamped > current_count {
        current_count
            .saturating_add(policy.scale_up_step)
            .min(clamped)
    } else if clamped < current_count {
        if downscale_blocked || metrics.in_flight.unwrap_or(0) > 0 {
            current_count
        } else {
            current_count
                .saturating_sub(policy.scale_down_step)
                .max(clamped)
        }
    } else {
        current_count
    };

    let direction = if desired_count > current_count {
        AutoscaleDirection::Up
    } else if desired_count < current_count {
        AutoscaleDirection::Down
    } else {
        AutoscaleDirection::None
    };

    AutoscaleDecision {
        current_count,
        desired_count,
        direction,
        reason: if reasons.is_empty() {
            "within-target".to_string()
        } else {
            reasons.join(",")
        },
    }
}

fn no_change(current_count: u32, reason: &str) -> AutoscaleDecision {
    AutoscaleDecision {
        current_count,
        desired_count: current_count,
        direction: AutoscaleDirection::None,
        reason: reason.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nscale_core::job::JobAutoscalingPolicy;

    fn policy() -> JobAutoscalingPolicy {
        JobAutoscalingPolicy {
            enabled: true,
            min_count: 1,
            max_count: 10,
            scale_to_zero: true,
            scale_up_step: 2,
            scale_down_step: 1,
            target_requests_per_second_per_instance: Some(10.0),
            target_p95_latency_ms: Some(500.0),
            max_error_rate: Some(0.05),
            cooldown_secs: None,
            decision_window_secs: None,
        }
    }

    #[test]
    fn request_rate_scales_up_with_step_limit() {
        let decision = decide_autoscale(
            &policy(),
            1,
            &MetricSnapshot {
                request_rate_rps: Some(25.0),
                p95_latency_ms: None,
                error_rate: None,
                in_flight: None,
            },
            false,
        );

        assert_eq!(decision.desired_count, 3);
        assert_eq!(decision.direction, AutoscaleDirection::Up);
        assert!(decision.reason.contains("request-rate"));
    }

    #[test]
    fn max_count_caps_scale_up() {
        let mut policy = policy();
        policy.max_count = 4;
        policy.scale_up_step = 10;

        let decision = decide_autoscale(
            &policy,
            3,
            &MetricSnapshot {
                request_rate_rps: Some(100.0),
                p95_latency_ms: None,
                error_rate: None,
                in_flight: None,
            },
            false,
        );

        assert_eq!(decision.desired_count, 4);
    }

    #[test]
    fn downscale_respects_step_limit() {
        let mut policy = policy();
        policy.scale_down_step = 2;

        let decision = decide_autoscale(
            &policy,
            6,
            &MetricSnapshot {
                request_rate_rps: Some(5.0),
                p95_latency_ms: Some(100.0),
                error_rate: Some(0.0),
                in_flight: None,
            },
            false,
        );

        assert_eq!(decision.desired_count, 4);
        assert_eq!(decision.direction, AutoscaleDirection::Down);
    }

    #[test]
    fn downscale_can_be_blocked() {
        let decision = decide_autoscale(
            &policy(),
            6,
            &MetricSnapshot {
                request_rate_rps: Some(5.0),
                p95_latency_ms: Some(100.0),
                error_rate: Some(0.0),
                in_flight: Some(1),
            },
            true,
        );

        assert_eq!(decision.desired_count, 6);
        assert_eq!(decision.direction, AutoscaleDirection::None);
    }

    #[test]
    fn high_latency_scales_up() {
        let decision = decide_autoscale(
            &policy(),
            2,
            &MetricSnapshot {
                request_rate_rps: Some(10.0),
                p95_latency_ms: Some(900.0),
                error_rate: None,
                in_flight: None,
            },
            false,
        );

        assert_eq!(decision.desired_count, 4);
        assert_eq!(decision.direction, AutoscaleDirection::Up);
        assert!(decision.reason.contains("latency"));
    }

    #[test]
    fn missing_metrics_noops() {
        let decision = decide_autoscale(
            &policy(),
            2,
            &MetricSnapshot {
                request_rate_rps: None,
                p95_latency_ms: None,
                error_rate: None,
                in_flight: None,
            },
            false,
        );

        assert_eq!(decision.desired_count, 2);
        assert_eq!(decision.direction, AutoscaleDirection::None);
    }

    #[test]
    fn latency_below_target_scales_down_toward_min_count() {
        let mut policy = policy();
        policy.target_requests_per_second_per_instance = None;
        policy.max_error_rate = None;

        let decision = decide_autoscale(
            &policy,
            3,
            &MetricSnapshot {
                request_rate_rps: None,
                p95_latency_ms: Some(100.0),
                error_rate: None,
                in_flight: None,
            },
            false,
        );

        assert_eq!(decision.desired_count, 2);
        assert_eq!(decision.direction, AutoscaleDirection::Down);
        assert!(decision.reason.contains("latency"));
    }

    #[test]
    fn error_rate_below_target_scales_down_toward_min_count() {
        let mut policy = policy();
        policy.target_requests_per_second_per_instance = None;
        policy.target_p95_latency_ms = None;

        let decision = decide_autoscale(
            &policy,
            3,
            &MetricSnapshot {
                request_rate_rps: None,
                p95_latency_ms: None,
                error_rate: Some(0.0),
                in_flight: None,
            },
            false,
        );

        assert_eq!(decision.desired_count, 2);
        assert_eq!(decision.direction, AutoscaleDirection::Down);
        assert!(decision.reason.contains("error-rate"));
    }
}

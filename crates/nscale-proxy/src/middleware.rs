//! Request-routing helpers for the proxy.

/// Extract the service/job label from a raw `Host` header value.
///
/// The first label before the first `.` is used, and any trailing `:port` is
/// stripped. Returns `None` only when the input is empty.
pub fn extract_job_id_from_host(host: &str) -> Option<String> {
    let label = host.split('.').next().unwrap_or(host);
    let label = label.split(':').next().unwrap_or(label);
    if label.is_empty() {
        None
    } else {
        Some(label.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_hostname() {
        assert_eq!(
            extract_job_id_from_host("my-service"),
            Some("my-service".into())
        );
    }

    #[test]
    fn hostname_with_domain() {
        assert_eq!(
            extract_job_id_from_host("my-service.example.com"),
            Some("my-service".into())
        );
    }

    #[test]
    fn hostname_with_port() {
        assert_eq!(
            extract_job_id_from_host("my-service:8080"),
            Some("my-service".into())
        );
    }

    #[test]
    fn hostname_with_domain_and_port() {
        assert_eq!(
            extract_job_id_from_host("my-service.example.com:443"),
            Some("my-service".into())
        );
    }

    #[test]
    fn subdomain_chain() {
        assert_eq!(
            extract_job_id_from_host("my-service.sub.example.com"),
            Some("my-service".into())
        );
    }

    #[test]
    fn ip_address_host() {
        assert_eq!(extract_job_id_from_host("192.168.1.1"), Some("192".into()));
    }

    #[test]
    fn ip_address_with_port() {
        assert_eq!(
            extract_job_id_from_host("192.168.1.1:3000"),
            Some("192".into())
        );
    }

    #[test]
    fn empty_host_returns_none() {
        assert_eq!(extract_job_id_from_host(""), None);
    }

    #[test]
    fn port_only_returns_none() {
        // ":8080" -> first split on '.' is ":8080", split on ':' -> ""
        assert_eq!(extract_job_id_from_host(":8080"), None);
    }

    #[test]
    fn localhost() {
        assert_eq!(
            extract_job_id_from_host("localhost"),
            Some("localhost".into())
        );
    }

    #[test]
    fn localhost_with_port() {
        assert_eq!(
            extract_job_id_from_host("localhost:3000"),
            Some("localhost".into())
        );
    }

    #[test]
    fn hyphenated_job_name() {
        assert_eq!(
            extract_job_id_from_host("my-cool-service.traefik.local:9999"),
            Some("my-cool-service".into())
        );
    }
}

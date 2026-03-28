use std::sync::atomic::{AtomicU8, Ordering};

use nscale_core::job::Endpoint;

/// Atomic state values for a job's wake lifecycle.
pub const STATE_DORMANT: u8 = 0;
pub const STATE_WAKING: u8 = 1;
pub const STATE_READY: u8 = 2;

/// Per-job wake state shared across request tasks.
pub struct WakeState {
    pub status: AtomicU8,
    pub notify: tokio::sync::broadcast::Sender<WakeResult>,
}

/// Result broadcast to all waiters once a wake-up completes.
#[derive(Debug, Clone)]
pub enum WakeResult {
    Ready(Endpoint),
    Failed(String),
}

impl WakeState {
    pub fn new_waking() -> (Self, tokio::sync::broadcast::Receiver<WakeResult>) {
        let (tx, rx) = tokio::sync::broadcast::channel(1);
        let state = Self {
            status: AtomicU8::new(STATE_WAKING),
            notify: tx,
        };
        (state, rx)
    }

    pub fn is_dormant(&self) -> bool {
        self.status.load(Ordering::Acquire) == STATE_DORMANT
    }

    pub fn is_waking(&self) -> bool {
        self.status.load(Ordering::Acquire) == STATE_WAKING
    }

    pub fn is_ready(&self) -> bool {
        self.status.load(Ordering::Acquire) == STATE_READY
    }

    /// Attempt to transition from DORMANT to WAKING.
    /// Returns true if this caller won the race (i.e., should start the wake task).
    pub fn try_start_wake(&self) -> bool {
        self.status
            .compare_exchange(STATE_DORMANT, STATE_WAKING, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    pub fn set_ready(&self) {
        self.status.store(STATE_READY, Ordering::Release);
    }

    pub fn set_dormant(&self) {
        self.status.store(STATE_DORMANT, Ordering::Release);
    }
}

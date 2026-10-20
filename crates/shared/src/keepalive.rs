//! Leaf primitives for Kubernetes capability-job pod shutdown. Shared by
//! the pod servers (toolset and inference) that need to know when it is
//! safe to stop accepting connections.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::Mutex;

/// Run activity a [`ShutdownWatcher`] reads: how many calls are executing and
/// when the last one started or finished. A fresh process counts its own start
/// as the last activity, so an idle pod that is never dialed still exits after
/// its window. Shared by the capability-job pod servers (tool and inference),
/// which hold it behind an `Arc` and mutate the counters as calls come and go.
pub struct Activity {
    pub in_flight: AtomicI64,
    pub completed: AtomicI64,
    pub last_activity: Mutex<Instant>,
}

impl Activity {
    pub fn new() -> Self {
        Self {
            in_flight: AtomicI64::new(0),
            completed: AtomicI64::new(0),
            last_activity: Mutex::new(Instant::now()),
        }
    }

    pub async fn touch(&self) {
        *self.last_activity.lock().await = Instant::now();
    }
}

impl Default for Activity {
    fn default() -> Self {
        Self::new()
    }
}

/// Resolves when a capability-job pod's server should stop accepting
/// connections.
pub struct ShutdownWatcher {
    activity: Arc<Activity>,
}

impl ShutdownWatcher {
    pub fn new(activity: Arc<Activity>) -> Self {
        Self { activity }
    }

    /// A one-shot pod (`keepalive` false) exits once its single call finishes; a
    /// keepalive pod ignores the completed count and exits after `idle_window`
    /// elapses with no call in flight. `idle_window` also bounds a pod the
    /// harness never dials, so it does not linger to its Job deadline.
    pub async fn wait(self, keepalive: bool, idle_window: Duration) {
        loop {
            tokio::time::sleep(Duration::from_millis(500)).await;
            if self.activity.in_flight.load(Ordering::SeqCst) > 0 {
                continue;
            }
            if !keepalive && self.activity.completed.load(Ordering::SeqCst) >= 1 {
                return;
            }
            if self.activity.last_activity.lock().await.elapsed() >= idle_window {
                return;
            }
        }
    }
}

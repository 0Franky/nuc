pub mod actor;
pub mod time_utils;

pub use actor::NotificationPluginActor;
pub use time_utils::{chrono_now_iso8601, days_to_ymd, is_leap};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_iso8601_format() {
        let ts = chrono_now_iso8601();
        assert!(ts.contains('T'));
        assert!(ts.ends_with('Z'));
        // Should look like: 2026-09-08T19:03:12.123Z
        assert!(ts.len() >= 20);
    }

    #[test]
    fn test_days_to_ymd() {
        // 2026-09-08 is day 20704 since epoch (approx)
        let (y, m, d) = days_to_ymd(0);
        assert_eq!(y, 1970);
        assert_eq!(m, 1);
        assert_eq!(d, 1);
    }
}

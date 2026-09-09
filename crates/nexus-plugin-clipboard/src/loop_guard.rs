use std::collections::HashSet;

/// Prevents infinite synchronization ping-pong loops
pub struct ClipboardLoopGuard {
    seen_hashes: HashSet<[u8; 32]>,
}

impl ClipboardLoopGuard {
    pub fn new() -> Self {
        Self {
            seen_hashes: HashSet::new(),
        }
    }

    pub fn is_known_or_insert(&mut self, text: &str) -> bool {
        let hash = *blake3::hash(text.as_bytes()).as_bytes();
        if self.seen_hashes.contains(&hash) {
            true
        } else {
            // Keep set size bounded to 500 recent items
            if self.seen_hashes.len() > 500 {
                self.seen_hashes.clear();
            }
            self.seen_hashes.insert(hash);
            false
        }
    }
}

impl Default for ClipboardLoopGuard {
    fn default() -> Self {
        Self::new()
    }
}

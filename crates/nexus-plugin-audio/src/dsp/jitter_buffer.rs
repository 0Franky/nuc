use std::collections::VecDeque;

/// Adaptive Jitter Buffer for managing network packet arrival variance
pub struct AdaptiveJitterBuffer {
    queue: VecDeque<(u32, u64, Vec<u8>)>, // (seq, timestamp_us, opus_data)
    target_delay_ms: f32,
    last_seq: Option<u32>,
}

impl AdaptiveJitterBuffer {
    pub fn new(initial_delay_ms: f32) -> Self {
        Self {
            queue: VecDeque::new(),
            target_delay_ms: initial_delay_ms,
            last_seq: None,
        }
    }

    pub fn push_packet(&mut self, seq: u32, timestamp_us: u64, data: Vec<u8>) {
        self.queue.push_back((seq, timestamp_us, data));
        if self.queue.len() > 1 {
            let len = self.queue.len();
            if self.queue[len - 2].0 > seq {
                self.queue.make_contiguous().sort_by_key(|item| item.0);
            }
        }
    }

    pub fn pop_frame(&mut self) -> Option<Vec<u8>> {
        if self.queue.len() < 2 {
            return None;
        }

        if let Some((seq, _, data)) = self.queue.pop_front() {
            self.last_seq = Some(seq);
            Some(data)
        } else {
            None
        }
    }

    pub fn target_delay(&self) -> f32 {
        self.target_delay_ms
    }
}

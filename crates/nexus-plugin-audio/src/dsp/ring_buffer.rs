use std::sync::atomic::{AtomicU64, Ordering};

/// A Lock-Free Single-Producer Single-Consumer (SPSC) RingBuffer for Low-Latency Audio Samples
pub struct AudioRingBuffer {
    buffer: Vec<f32>,
    capacity: usize,
    read_pos: AtomicU64,
    write_pos: AtomicU64,
}

impl AudioRingBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            buffer: vec![0.0; capacity],
            capacity,
            read_pos: AtomicU64::new(0),
            write_pos: AtomicU64::new(0),
        }
    }

    /// Push audio samples from the OS capture loop (Producer)
    pub fn push_slice(&mut self, samples: &[f32]) -> usize {
        let write = self.write_pos.load(Ordering::Relaxed);
        let read = self.read_pos.load(Ordering::Acquire);
        let available = self.capacity - ((write - read) as usize);

        let to_write = samples.len().min(available);
        for (i, &sample) in samples.iter().enumerate().take(to_write) {
            let idx = ((write + i as u64) as usize) % self.capacity;
            self.buffer[idx] = sample;
        }

        self.write_pos.store(write + to_write as u64, Ordering::Release);
        to_write
    }

    /// Pop audio samples into the encoder / network packetizer (Consumer)
    pub fn pop_slice(&mut self, out: &mut [f32]) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Relaxed);
        let available = (write - read) as usize;

        let to_read = out.len().min(available);
        for (i, slot) in out.iter_mut().enumerate().take(to_read) {
            let idx = ((read + i as u64) as usize) % self.capacity;
            *slot = self.buffer[idx];
        }

        self.read_pos.store(read + to_read as u64, Ordering::Release);
        to_read
    }

    pub fn available_to_read(&self) -> usize {
        let write = self.write_pos.load(Ordering::Relaxed);
        let read = self.read_pos.load(Ordering::Relaxed);
        (write - read) as usize
    }
}

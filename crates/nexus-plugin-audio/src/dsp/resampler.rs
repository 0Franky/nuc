/// Clock Drift Resampler: Gently adjusts sample rate to avoid underruns/overruns
pub struct DriftResampler {
    resample_ratio: f32,
}

impl DriftResampler {
    pub fn new() -> Self {
        Self {
            resample_ratio: 1.0,
        }
    }

    pub fn set_drift_adjustment(&mut self, factor: f32) {
        self.resample_ratio = factor.clamp(0.995, 1.005);
    }

    pub fn process_linear(&self, input: &[f32], output: &mut [f32]) -> usize {
        let in_len = input.len();
        let out_len = output.len();
        let mut out_idx = 0;

        let mut in_pos = 0.0f32;
        while out_idx < out_len && in_pos < (in_len as f32 - 1.0) {
            let idx0 = in_pos.floor() as usize;
            let idx1 = (idx0 + 1).min(in_len - 1);
            let frac = in_pos - idx0 as f32;

            output[out_idx] = input[idx0] * (1.0 - frac) + input[idx1] * frac;
            out_idx += 1;
            in_pos += self.resample_ratio;
        }

        out_idx
    }
}

impl Default for DriftResampler {
    fn default() -> Self {
        Self::new()
    }
}

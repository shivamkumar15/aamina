use anyhow::{Context, Result};
use cpal::SampleFormat;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use ringbuf::HeapRb;
use std::env;
use std::io::Read;
use std::net::TcpListener;
use std::sync::{Arc, atomic::{AtomicU64, Ordering}};
use std::thread;
use std::time::Duration;

/// Rate the phone records and sends (see `sampleRate` in `MainActivity.kt`).
/// The stream is converted to the rate the output device asks for, otherwise
/// a 48 kHz laptop plays a 44.1 kHz stream ~9% too fast.
const DEFAULT_INPUT_RATE: u32 = 44_100;

/// Listen on every interface: the app asks for a *laptop IP*, so binding
/// loopback only would make Wi-Fi use impossible. `adb reverse` with 127.0.0.1
/// keeps working. Override with `AAMINA_BIND` (e.g. `127.0.0.1:5000`).
const DEFAULT_BIND: &str = "0.0.0.0:5000";

fn main() -> Result<()> {
    println!("Aamina Receiver Starting...");

    let bind_addr = env::var("AAMINA_BIND").unwrap_or_else(|_| DEFAULT_BIND.to_string());
    let listener = TcpListener::bind(&bind_addr)
        .with_context(|| format!("Failed to bind receiver on {bind_addr}"))?;

    println!("Waiting for Android connection on {bind_addr}...");
    println!("Tip: enter the laptop's LAN IP in the app, or run `adb reverse tcp:5000 tcp:5000` and use 127.0.0.1.");

    let host = cpal::default_host();
    let device = if let Ok(substr) = env::var("AAMINA_OUTPUT_CONTAINS") {
        let mut found = None;
        for d in host.output_devices().context("Failed to list output devices")? {
            if let Ok(name) = d.name() {
                if name.to_lowercase().contains(&substr.to_lowercase()) {
                    found = Some(d);
                    break;
                }
            }
        }
        found.context("No output device matched AAMINA_OUTPUT_CONTAINS")?
    } else {
        host.default_output_device()
            .context("No output device available")?
    };

    if let Ok(name) = device.name() {
        println!("Output device: {name}");
    }

    let output_config = device.default_output_config()?;
    let sample_format = output_config.sample_format();
    let config: cpal::StreamConfig = output_config.into();

    let output_rate = config.sample_rate.0;
    let input_rate = env::var("AAMINA_INPUT_RATE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|rate| *rate > 0)
        .unwrap_or(DEFAULT_INPUT_RATE);

    println!(
        "Using output config: {} Hz, {} ch, {:?} (phone sends {} Hz)",
        output_rate, config.channels, sample_format, input_rate
    );
    if input_rate != output_rate {
        println!("Resampling {} Hz -> {} Hz", input_rate, output_rate);
    }

    // Ring holds ~1 s of interleaved output samples. Longer stalls are handled
    // by dropping samples (counted below) instead of growing the latency.
    let ring = HeapRb::<i16>::new((output_rate as usize * config.channels as usize).max(44_100));
    let (mut producer, mut consumer) = ring.split();

    let bytes_in = Arc::new(AtomicU64::new(0));
    let sample_abs_sum = Arc::new(AtomicU64::new(0));
    let sample_count = Arc::new(AtomicU64::new(0));
    let sample_abs_max = Arc::new(AtomicU64::new(0));
    let dropped_samples = Arc::new(AtomicU64::new(0));
    let bytes_in_stats = Arc::clone(&bytes_in);
    let sample_abs_sum_stats = Arc::clone(&sample_abs_sum);
    let sample_count_stats = Arc::clone(&sample_count);
    let sample_abs_max_stats = Arc::clone(&sample_abs_max);
    let dropped_samples_stats = Arc::clone(&dropped_samples);

    thread::spawn(move || {
        let mut stat_last = 0_u64;
        loop {
            thread::sleep(Duration::from_secs(1));
            let total = bytes_in_stats.load(Ordering::Relaxed);
            let delta = total.saturating_sub(stat_last);
            stat_last = total;
            let kbps = (delta as f64 * 8.0) / 1000.0;
            let abs_sum = sample_abs_sum_stats.swap(0, Ordering::Relaxed);
            let count = sample_count_stats.swap(0, Ordering::Relaxed);
            let max_abs = sample_abs_max_stats.swap(0, Ordering::Relaxed);
            let dropped = dropped_samples_stats.swap(0, Ordering::Relaxed);
            let avg_abs = if count > 0 {
                abs_sum as f64 / count as f64
            } else {
                0.0
            };
            println!(
                "Input rate: {:.1} kbps | avg sample level: {:.1} | peak: {} | dropped: {}",
                kbps, avg_abs, max_abs, dropped
            );
        }
    });

    let bytes_in_reader = Arc::clone(&bytes_in);
    let sample_abs_sum_reader = Arc::clone(&sample_abs_sum);
    let sample_count_reader = Arc::clone(&sample_count);
    let sample_abs_max_reader = Arc::clone(&sample_abs_max);
    let dropped_samples_reader = Arc::clone(&dropped_samples);
    thread::spawn(move || {
        let mut resampler = Resampler::new(input_rate, output_rate);
        let mut buffer = [0_u8; 4096];
        // Leftover byte of an odd-length read, see decode_pcm16.
        let mut pending_byte: Option<u8>;
        let mut decoded: Vec<i16> = Vec::with_capacity(2048);
        let mut converted: Vec<i16> = Vec::with_capacity(4096);

        loop {
            let (mut socket, addr) = loop {
                match listener.accept() {
                    Ok(pair) => break pair,
                    Err(err) => {
                        eprintln!("Accept error: {err}");
                        thread::sleep(Duration::from_millis(250));
                    }
                }
            };
            println!("Connected: {addr}");
            pending_byte = None;
            resampler.reset();

            loop {
                match socket.read(&mut buffer) {
                    Ok(0) => {
                        println!("Android disconnected");
                        break;
                    }
                    Ok(size) => {
                        bytes_in_reader.fetch_add(size as u64, Ordering::Relaxed);
                        decode_pcm16(&buffer[..size], &mut pending_byte, &mut decoded);

                        for &sample in &decoded {
                            let abs = sample.unsigned_abs() as u64;
                            sample_abs_sum_reader.fetch_add(abs, Ordering::Relaxed);
                            let _ = sample_abs_max_reader.fetch_max(abs, Ordering::Relaxed);
                            sample_count_reader.fetch_add(1, Ordering::Relaxed);
                        }

                        // `converted` accumulates across reads unless reset:
                        // process() appends, so leftovers would be re-pushed
                        // on every read (and grow without bound).
                        converted.clear();
                        resampler.process(&decoded, &mut converted);
                        for &sample in &converted {
                            if producer.push(sample).is_err() {
                                // Ring is full: the output device is not
                                // draining fast enough. Dropping here keeps
                                // playback moving instead of stalling.
                                dropped_samples_reader.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                    }
                    Err(err) => {
                        eprintln!("Socket read error: {err}");
                        break;
                    }
                }
            }
        }
    });

    let err_fn = |err| eprintln!("Stream error: {err}");
    let stream = match sample_format {
        SampleFormat::I16 => device.build_output_stream(
            &config,
            move |data: &mut [i16], _| {
                for sample in data.iter_mut() {
                    *sample = consumer.pop().unwrap_or(0);
                }
            },
            err_fn,
            None,
        )?,
        SampleFormat::F32 => device.build_output_stream(
            &config,
            move |data: &mut [f32], _| {
                for sample in data.iter_mut() {
                    let v = consumer.pop().unwrap_or(0);
                    *sample = v as f32 / i16::MAX as f32;
                }
            },
            err_fn,
            None,
        )?,
        SampleFormat::U16 => device.build_output_stream(
            &config,
            move |data: &mut [u16], _| {
                for sample in data.iter_mut() {
                    let v = consumer.pop().unwrap_or(0);
                    *sample = (v as i32 + i16::MAX as i32 + 1) as u16;
                }
            },
            err_fn,
            None,
        )?,
        _ => anyhow::bail!("Unsupported output sample format: {sample_format:?}"),
    };

    stream.play()?;
    println!("Playing audio. Keep this process running.");

    loop {
        thread::sleep(Duration::from_secs(1));
    }
}

/// Splits a TCP read into little-endian i16 samples.
///
/// TCP is a byte stream with no message framing, so an odd-length read leaves
/// half a sample behind. That byte is carried over to the next read instead of
/// being discarded — dropping it would shift every following sample by one
/// byte, which sounds like permanent static.
fn decode_pcm16(bytes: &[u8], pending: &mut Option<u8>, out: &mut Vec<i16>) {
    out.clear();
    if bytes.is_empty() {
        return;
    }

    let mut start = 0;
    if let Some(low) = pending.take() {
        out.push(i16::from_le_bytes([low, bytes[0]]));
        start = 1;
    }

    let mut chunks = bytes[start..].chunks_exact(2);
    for chunk in &mut chunks {
        out.push(i16::from_le_bytes([chunk[0], chunk[1]]));
    }
    if let [trailing] = chunks.remainder() {
        *pending = Some(*trailing);
    }
}

/// Converts interleaved i16 samples to another sample rate with linear
/// interpolation. Runs on the socket thread so the audio callback stays a
/// plain ring-buffer pop.
///
/// Note: linear interpolation is not an anti-aliasing filter, so downsampling
/// (input rate above output rate) folds some high-frequency content. It is
/// still far better than playing mismatched rates at the wrong speed.
struct Resampler {
    /// Input samples consumed per output sample (`from_rate / to_rate`).
    step: f64,
    /// Fractional input position (relative to `index`) of the next output.
    next_pos: f64,
    /// Input position of `prev`.
    index: f64,
    prev: i16,
    primed: bool,
}

impl Resampler {
    fn new(from_rate: u32, to_rate: u32) -> Self {
        debug_assert!(from_rate > 0 && to_rate > 0);
        Self {
            step: f64::from(from_rate) / f64::from(to_rate),
            next_pos: 0.0,
            index: 0.0,
            prev: 0,
            primed: false,
        }
    }

    /// Drops stream history so a reconnect does not interpolate across the gap.
    fn reset(&mut self) {
        self.next_pos = 0.0;
        self.index = 0.0;
        self.primed = false;
    }

    fn process(&mut self, input: &[i16], out: &mut Vec<i16>) {
        if self.step == 1.0 {
            out.extend_from_slice(input);
            return;
        }

        for &sample in input {
            if !self.primed {
                self.primed = true;
                self.prev = sample;
                self.index = 0.0;
                self.next_pos = 0.0;
                continue;
            }

            // `prev` sits at `index`, `sample` at `index + 1`: emit every
            // output position that falls inside that interval.
            while self.next_pos < self.index + 1.0 {
                let frac = (self.next_pos - self.index) as f32;
                let value = self.prev as f32 + (sample as f32 - self.prev as f32) * frac;
                out.push(value.round().clamp(i16::MIN as f32, i16::MAX as f32) as i16);
                self.next_pos += self.step;
            }
            self.index += 1.0;
            self.prev = sample;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_keeps_half_a_sample_across_reads() {
        let stream = [1_u8, 0, 2, 0, 3, 0];
        let mut pending = None;
        let mut out = Vec::new();

        // A three byte read holds one whole sample plus the low byte of the
        // next one; the remainder must survive into the following read.
        decode_pcm16(&stream[..3], &mut pending, &mut out);
        assert_eq!(out, vec![1]);
        assert_eq!(pending, Some(2));

        decode_pcm16(&stream[3..], &mut pending, &mut out);
        assert_eq!(out, vec![2, 3]);
        assert_eq!(pending, None);
    }

    #[test]
    fn decode_handles_byte_at_a_time() {
        let stream = [0xFF, 0x7F, 0x00, 0x80];
        let mut pending = None;
        let mut all = Vec::new();

        for chunk in stream.chunks(1) {
            let mut out = Vec::new();
            decode_pcm16(chunk, &mut pending, &mut out);
            all.extend_from_slice(&out);
        }
        assert_eq!(all, vec![i16::MAX, i16::MIN]);
        assert_eq!(pending, None);
    }

    #[test]
    fn resampler_passes_through_matching_rates() {
        let input: Vec<i16> = (0..100).map(|i| (i * 300) as i16).collect();
        let mut resampler = Resampler::new(44_100, 44_100);
        let mut out = Vec::new();
        resampler.process(&input, &mut out);
        assert_eq!(out, input);
    }

    #[test]
    fn resampler_produces_expected_sample_count() {
        for (from_rate, to_rate) in [(44_100_u32, 48_000_u32), (48_000, 44_100), (16_000, 48_000)] {
            let input = vec![1_i16; from_rate as usize]; // 1 second
            let mut resampler = Resampler::new(from_rate, to_rate);
            let mut out = Vec::new();
            resampler.process(&input, &mut out);

            // The last input sample is only kept as interpolation history, so
            // up to one output sample per input sample may be missing at the
            // end of a finite buffer.
            let tolerance = (f64::from(to_rate) / f64::from(from_rate)).ceil() as usize + 1;
            let expected = to_rate as usize;
            assert!(
                out.len().abs_diff(expected) <= tolerance,
                "{from_rate} -> {to_rate}: got {} samples, expected ~{expected} (+/- {tolerance})",
                out.len()
            );
        }
    }

    #[test]
    fn resampler_keeps_interpolation_positions_in_order() {
        // A steep ramp makes resampling errors obvious: the output must keep
        // the input slope and must never leave the input range.
        let input: Vec<i16> = (0..=2000).map(|i| (i * 10) as i16).collect();
        let mut resampler = Resampler::new(44_100, 48_000);
        let mut out = Vec::new();
        resampler.process(&input, &mut out);

        assert!(out.len() > input.len(), "upsampling must add samples");
        assert!(
            out.windows(2).all(|w| w[1] > w[0]),
            "output must increase strictly"
        );
        assert!(out[0] >= input[0] && out[out.len() - 1] <= *input.last().unwrap());

        // Same slope as the input: 48000 output samples cover 2001 input
        // samples, i.e. ~1.09 output samples per input sample.
        let ratio = out.len() as f64 / input.len() as f64;
        assert!(
            (ratio - 48_000.0 / 44_100.0).abs() < 0.01,
            "unexpected rate ratio {ratio}"
        );
    }

    #[test]
    fn resampler_decimates_by_dropping_intermediate_positions() {
        // 88.2 kHz -> 44.1 kHz must emit every second sample.
        let input: Vec<i16> = (0..1000).map(|i| (i * 10) as i16).collect();
        let mut resampler = Resampler::new(88_200, 44_100);
        let mut out = Vec::new();
        resampler.process(&input, &mut out);

        assert_eq!(out.len(), 500);
        assert_eq!(out[0], input[0]);
        assert_eq!(out[1], input[2]);
        assert_eq!(out[249], input[498]);
    }

    #[test]
    fn resampler_reset_forgets_history() {
        let mut resampler = Resampler::new(44_100, 48_000);
        let mut out = Vec::new();

        resampler.process(&[10_000, -10_000], &mut out);
        assert!(!out.is_empty());
        out.clear();

        resampler.reset();
        resampler.process(&[0, 0], &mut out);
        assert!(
            out.iter().all(|&s| s == 0),
            "no interpolation may cross the reset"
        );
    }
}

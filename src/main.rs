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

fn main() -> Result<()> {
    println!("Aamina Receiver Starting...");

    let listener = TcpListener::bind("127.0.0.1:5000")
        .context("Failed to bind receiver on 127.0.0.1:5000")?;

    println!("Waiting for Android connection on 127.0.0.1:5000...");

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

    println!(
        "Using output config: {} Hz, {} ch, {:?}",
        config.sample_rate.0,
        config.channels,
        sample_format
    );

    let ring = HeapRb::<i16>::new((config.sample_rate.0 as usize * config.channels as usize).max(44_100));
    let (mut producer, mut consumer) = ring.split();

    let bytes_in = Arc::new(AtomicU64::new(0));
    let sample_abs_sum = Arc::new(AtomicU64::new(0));
    let sample_count = Arc::new(AtomicU64::new(0));
    let sample_abs_max = Arc::new(AtomicU64::new(0));
    let bytes_in_stats = Arc::clone(&bytes_in);
    let sample_abs_sum_stats = Arc::clone(&sample_abs_sum);
    let sample_count_stats = Arc::clone(&sample_count);
    let sample_abs_max_stats = Arc::clone(&sample_abs_max);

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
            let avg_abs = if count > 0 {
                abs_sum as f64 / count as f64
            } else {
                0.0
            };
            println!(
                "Input rate: {:.1} kbps | avg sample level: {:.1} | peak: {}",
                kbps, avg_abs, max_abs
            );
        }
    });

    let bytes_in_reader = Arc::clone(&bytes_in);
    thread::spawn(move || {
        loop {
            match listener.accept() {
                Ok((mut socket, addr)) => {
                    println!("Connected: {addr}");
                    let mut buffer = [0_u8; 4096];
                    loop {
                        match socket.read(&mut buffer) {
                            Ok(0) => {
                                println!("Android disconnected");
                                break;
                            }
                            Ok(size) => {
                                bytes_in_reader.fetch_add(size as u64, Ordering::Relaxed);
                                for chunk in buffer[..size].chunks_exact(2) {
                                    let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
                                    let abs = sample.unsigned_abs() as u64;
                                    sample_abs_sum.fetch_add(abs, Ordering::Relaxed);
                                    let _ = sample_abs_max.fetch_max(abs, Ordering::Relaxed);
                                    sample_count.fetch_add(1, Ordering::Relaxed);
                                    let _ = producer.push(sample);
                                }
                            }
                            Err(err) => {
                                eprintln!("Socket read error: {err}");
                                break;
                            }
                        }
                    }
                }
                Err(err) => {
                    eprintln!("Accept error: {err}");
                    thread::sleep(Duration::from_millis(250));
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

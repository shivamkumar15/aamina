# Aamina

Aamina is a project consisting of a Rust-based core application and a Flutter mobile application.

## Project Structure

- `src/` - Rust source code (Core application using Tokio, Cpal, Ringbuf)
- `aamina_mobile/` - Flutter mobile application

## Getting Started

### Prerequisites
- [Rust & Cargo](https://rustup.rs/) (for the core application)
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (for the mobile app)

### Building the Rust Core
```bash
cargo build
```

### Running the Mobile App
```bash
cd aamina_mobile
flutter pub get
flutter run
```

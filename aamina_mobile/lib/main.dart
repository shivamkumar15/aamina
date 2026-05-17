import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const AaminaApp());
}

class AaminaApp extends StatelessWidget {
  const AaminaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AudioPage(),
    );
  }
}

class AudioPage extends StatefulWidget {
  const AudioPage({super.key});

  @override
  State<AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<AudioPage> {
  static const platform = MethodChannel("aamina/audio");

  String mode = "internal";

  bool running = false;

  /// Request RECORD_AUDIO permission at runtime.
  /// Without this, AudioRecord creation crashes with SecurityException
  /// on Android 6+ (API 23+).
  Future<bool> _ensurePermissions() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> toggle() async {
    try {
      if (!running) {
        final granted = await _ensurePermissions();
        if (!granted) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Microphone permission is required for audio capture."),
            ),
          );
          return;
        }
        await platform.invokeMethod("startCapture", {"mode": mode});
      } else {
        await platform.invokeMethod("stopCapture");
      }

      setState(() {
        running = !running;
      });
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Unable to start streaming right now."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      backgroundColor: Colors.black,

      appBar: AppBar(
        title: const Text("Aamina"),
      ),

      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: "internal", label: Text("Internal")),
                ButtonSegment(value: "mic", label: Text("Mic")),
                ButtonSegment(value: "tone", label: Text("Test Tone")),
              ],
              selected: {mode},
              onSelectionChanged: running
                  ? null
                  : (set) {
                      setState(() {
                        mode = set.first;
                      });
                    },
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: toggle,
              child: Text(running ? "Stop Streaming" : "Start Streaming"),
            ),
          ],
        ),
      ),
    );
  }
}

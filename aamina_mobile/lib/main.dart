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

  /// True while waiting for the user to grant screen-capture permission
  /// (internal mode opens the Android MediaProjection dialog and the
  /// native side only answers afterwards).
  bool waitingForPermission = false;

  /// Last status / error message shown under the buttons.
  String status = "Idle — start the receiver on your laptop first.";

  final TextEditingController hostController =
      TextEditingController(text: "127.0.0.1");

  /// When true (internal mode only), the phone's media volume is set to 0
  /// while streaming and restored when streaming stops.
  bool mutePhone = false;

  /// Phone media volume before we muted it, so it can be restored.
  int? savedVolume;

  @override
  void dispose() {
    hostController.dispose();
    super.dispose();
  }

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
          setState(() {
            status = "Microphone permission denied — streaming needs it.";
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Microphone permission is required for audio capture."),
            ),
          );
          return;
        }
        setState(() {
          waitingForPermission = mode == "internal";
          status = mode == "internal"
              ? "Tap “Start now” on the Android screen-capture prompt…"
              : "Connecting to ${hostController.text.trim()}:5000…";
        });
        await platform.invokeMethod("startCapture", {
          "mode": mode,
          "host": hostController.text.trim(),
          "port": 5000,
        });
        // Mute the phone speaker (internal mode): AudioPlaybackCapture
        // keeps flowing; the stream is played on the laptop, so plug your
        // earphones into the LAPTOP.
        if (mode == "internal" && mutePhone) {
          try {
            savedVolume = await platform.invokeMethod<int>("getVolume");
            await platform.invokeMethod("setVolume", {"volume": 0});
          } catch (_) {
            savedVolume = null;
          }
        }
        setState(() {
          running = true;
          waitingForPermission = false;
          status = mode == "internal"
              ? "Streaming internal audio — play something!"
              : mode == "mic"
                  ? "Streaming microphone — speak to test."
                  : "Streaming test tone (440 Hz).";
        });
      } else {
        await platform.invokeMethod("stopCapture");
        if (savedVolume != null) {
          try {
            await platform.invokeMethod("setVolume", {"volume": savedVolume});
          } catch (_) {}
          savedVolume = null;
        }
        setState(() {
          running = false;
          waitingForPermission = false;
          status = "Stopped.";
        });
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (savedVolume != null) {
        try {
          await platform.invokeMethod("setVolume", {"volume": savedVolume});
        } catch (_) {}
        savedVolume = null;
      }
      setState(() {
        running = false;
        waitingForPermission = false;
        status = e.code == "DENIED"
            ? "Screen-capture was denied — try again and tap “Start now”."
            : "Could not start: ${e.message ?? e.code}";
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.code == "DENIED" ? "Screen-capture denied." : "Unable to start streaming right now.")),
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
              onPressed: waitingForPermission ? null : toggle,
              child: Text(waitingForPermission
                  ? "Waiting for permission…"
                  : running
                      ? "Stop Streaming"
                      : "Start Streaming"),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: TextField(
                controller: hostController,
                enabled: !running && !waitingForPermission,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: "Laptop IP (127.0.0.1 = USB via adb reverse)",
                  labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54),
                  ),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Checkbox(
                  value: mutePhone,
                  onChanged: running || waitingForPermission
                      ? null
                      : (v) => setState(() => mutePhone = v ?? false),
                ),
                const Flexible(
                  child: Text(
                    "Mute phone while streaming\n(listen on laptop 🎧)",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

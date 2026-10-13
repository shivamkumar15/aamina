import 'dart:async';
import 'dart:math' as math;

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
    const seed = Color(0xFF7C6CFF);
    final darkScheme =
        ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF0B0F1E),
          surfaceContainerLow: const Color(0xFF12172B),
          surfaceContainerHigh: const Color(0xFF1A2138),
          primary: const Color(0xFF8B7DFF),
          secondary: const Color(0xFF4DE3C2),
          tertiary: const Color(0xFF7CC4FF),
        );

    return MaterialApp(
      title: 'Aamina',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        scaffoldBackgroundColor: const Color(0xFF0B0F1E),
        fontFamilyFallback: const ['Roboto', 'Inter', 'sans-serif'],
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          color: const Color(0xFF141A30),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0E1330),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF8B7DFF), width: 1.6),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: const AudioPage(),
    );
  }
}

enum _StatusKind { idle, waitingPermission, connecting, live, waitingLaptop }

class AudioPage extends StatefulWidget {
  const AudioPage({super.key});

  @override
  State<AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<AudioPage>
    with SingleTickerProviderStateMixin {
  static const platform = MethodChannel('aamina/audio');

  String mode = 'internal';
  bool running = false;

  /// True while waiting for the user to grant screen-capture permission
  /// (internal mode opens the Android MediaProjection dialog and the
  /// native side only answers afterwards).
  bool waitingForPermission = false;

  /// Last status / error message shown under the buttons.
  String status = 'Idle — start the receiver on your laptop first.';

  final TextEditingController hostController = TextEditingController(
    text: '127.0.0.1',
  );

  /// When true (internal mode only), the phone's media volume is set to 0
  /// while streaming and restored when streaming stops.
  bool mutePhone = false;

  /// Live native state (connected / last error), polled while streaming.
  /// Without this the button says "Streaming" even when the socket never
  /// connected (e.g. adb reverse missing).
  String connectionState = '';
  Timer? _pollTimer;

  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    hostController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pulseController.dispose();
    hostController.dispose();
    super.dispose();
  }

  /// Request RECORD_AUDIO permission at runtime.
  /// Without this, AudioRecord creation crashes with SecurityException
  /// on Android 6+ (API 23+).
  ///
  /// Only the capturing modes need it — "tone" just synthesises PCM, so it
  /// must keep working when the user declines the microphone prompt.
  Future<bool> _ensurePermissions() async {
    if (mode == 'tone') return true;
    final permissionStatus = await Permission.microphone.request();
    return permissionStatus.isGranted;
  }

  Future<void> toggle() async {
    try {
      if (!running) {
        final host = hostController.text.trim();
        if (host.isEmpty) {
          _showSnack('Enter your laptop IP first.');
          setState(() {
            status = 'Enter your laptop IP first — 127.0.0.1 for USB.';
          });
          return;
        }
        final granted = await _ensurePermissions();
        if (!mounted) return;
        if (!granted) {
          setState(() {
            status = 'Microphone permission denied — streaming needs it.';
          });
          _showSnack('Microphone permission is required for audio capture.');
          return;
        }
        setState(() {
          waitingForPermission = mode == 'internal';
          status = mode == 'internal'
              ? 'Tap “Start now” on the Android screen-capture prompt…'
              : 'Connecting to $host:5000…';
        });
        // The mute flag is applied natively AFTER the screen-capture grant
        // dialog (internal mode), so it is always passed through. Mute the
        // phone speaker: the silent player keeps the pipeline alive; your
        // earphones must be plugged into the LAPTOP.
        await platform.invokeMethod('startCapture', {
          'mode': mode,
          'host': host,
          'port': 5000,
          'mutePhone': mode == 'internal' && mutePhone,
        });
        // The native side answers only after the user granted (or denied)
        // screen capture, so this widget can be gone by now.
        if (!mounted) return;
        setState(() {
          running = true;
          waitingForPermission = false;
          status = mode == 'internal'
              ? (mutePhone
                    ? 'Streaming (phone muted — listen on your laptop 🎧)'
                    : 'Streaming internal audio — play something!')
              : mode == 'mic'
              ? 'Streaming microphone — speak to test.'
              : 'Streaming test tone (440 Hz).';
        });
        _startPolling();
      } else {
        await platform.invokeMethod('stopCapture');
        _stopPolling();
        if (!mounted) return;
        setState(() {
          running = false;
          waitingForPermission = false;
          connectionState = '';
          status = 'Stopped.';
        });
      }
    } on PlatformException catch (e) {
      _stopPolling();
      if (!mounted) return;
      setState(() {
        running = false;
        waitingForPermission = false;
        connectionState = '';
        status = e.code == 'DENIED'
            ? 'Screen-capture was denied — try again and tap “Start now”.'
            : 'Could not start: ${e.message ?? e.code}';
      });
      _showSnack(
        e.code == 'DENIED'
            ? 'Screen-capture denied.'
            : 'Unable to start streaming right now.',
      );
    } on MissingPluginException {
      // The aamina/audio channel only exists in the Android app; without this
      // the button would silently do nothing on desktop/web.
      _stopPolling();
      if (!mounted) return;
      setState(() {
        running = false;
        waitingForPermission = false;
        connectionState = '';
        status = 'Streaming is only implemented on Android.';
      });
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollState(),
    );
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollState() async {
    if (!running) return;
    try {
      final state = await platform.invokeMapMethod<String, dynamic>('getState');
      if (!mounted || !running) return;
      final connected = state?['connected'] == true;
      final lastError = state?['lastError'] as String?;
      final host = state?['host'] ?? hostController.text.trim();
      final port = state?['port'] ?? 5000;
      setState(() {
        connectionState = connected
            ? 'Connected to $host:$port — audio flowing.'
            : 'Waiting for laptop at $host:$port…'
                  '${lastError != null ? '\n$lastError' : ''}'
                  '\nUSB: run `adb reverse tcp:$port tcp:$port`.';
      });
    } catch (_) {
      // Poll is best-effort; the toggle() error paths own failure display.
    }
  }

  bool get _connected => connectionState.startsWith('Connected');

  _StatusKind get _statusKind {
    if (waitingForPermission) return _StatusKind.waitingPermission;
    if (!running) return _StatusKind.idle;
    if (_connected) return _StatusKind.live;
    if (connectionState.isEmpty) return _StatusKind.connecting;
    return _StatusKind.waitingLaptop;
  }

  (String, Color, IconData) _pill() {
    switch (_statusKind) {
      case _StatusKind.live:
        return ('●  LIVE', const Color(0xFF4DE3C2), Icons.bolt);
      case _StatusKind.waitingPermission:
        return (
          '◌  PERMISSION',
          const Color(0xFFB9A8FF),
          Icons.shield_outlined,
        );
      case _StatusKind.connecting:
        return ('◌  CONNECTING', const Color(0xFF7CC4FF), Icons.sync);
      case _StatusKind.waitingLaptop:
        return ('○  WAITING', const Color(0xFFFFC857), Icons.wifi_find);
      case _StatusKind.idle:
        return ('○  IDLE', Colors.white54, Icons.circle_outlined);
    }
  }

  String get _modeTitle {
    switch (mode) {
      case 'mic':
        return 'Microphone';
      case 'tone':
        return 'Test tone';
      default:
        return 'Internal audio';
    }
  }

  Future<void> _copyAdbCommand() async {
    await Clipboard.setData(
      const ClipboardData(text: 'adb reverse tcp:5000 tcp:5000'),
    );
    if (!mounted) return;
    _showSnack('Copied: adb reverse tcp:5000 tcp:5000');
  }

  void _useQuickHost(String value) {
    hostController.text = value;
    hostController.selection = TextSelection.fromPosition(
      TextPosition(offset: value.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pill = _pill();
    final connected = _connected;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF161233), Color(0xFF0B0F1E), Color(0xFF0A1A22)],
            stops: [0.0, 0.45, 1.0],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(pill),
                const SizedBox(height: 18),
                _buildHeroCard(theme, connected),
                const SizedBox(height: 16),
                _buildSourceSection(theme),
                const SizedBox(height: 16),
                _buildConnectionCard(theme),
                const SizedBox(height: 16),
                _buildOptionsCard(theme),
                const SizedBox(height: 16),
                _buildSetupCard(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader((String, Color, IconData) pill) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            gradient: const LinearGradient(
              colors: [Color(0xFF8B7DFF), Color(0xFF4DE3C2)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF8B7DFF).withValues(alpha: 0.45),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(
            Icons.graphic_eq_rounded,
            color: Colors.white,
            size: 26,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Aamina',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  color: Colors.white,
                ),
              ),
              Text(
                'Phone → Laptop audio bridge',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white60,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: pill.$2.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: pill.$2.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(pill.$3, size: 13, color: pill.$2),
              const SizedBox(width: 6),
              Text(
                pill.$1,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                  color: pill.$2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeroCard(ThemeData theme, bool connected) {
    final busy = waitingForPermission;
    final buttonLabel = busy
        ? 'Waiting for permission…'
        : running
        ? 'Stop Streaming'
        : 'Start Streaming';
    final buttonIcon = busy
        ? null
        : running
        ? Icons.stop_rounded
        : Icons.play_arrow_rounded;

    return Card(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: running ? 0.09 : 0.06),
              Colors.transparent,
            ],
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _modeTitle,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          color: Color(0xFF9D92FF),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        running
                            ? (connected
                                  ? 'Audio is flowing to your laptop.'
                                  : 'Trying to reach your laptop…')
                            : 'Ready when you are.',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        status,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                _PulseOrb(
                  animation: _pulseController,
                  active: running,
                  connected: connected,
                ),
              ],
            ),
            const SizedBox(height: 14),
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, _) {
                return _EqualizerBars(
                  running: running,
                  tick: _pulseController.value,
                );
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: busy ? null : toggle,
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: Colors.white.withValues(alpha: 0.10),
                  disabledForegroundColor: Colors.white60,
                  backgroundColor: running
                      ? const Color(0xFFFF5D6C)
                      : const Color(0xFF7C6CFF),
                  foregroundColor: Colors.white,
                  shadowColor:
                      (running
                              ? const Color(0xFFFF5D6C)
                              : const Color(0xFF7C6CFF))
                          .withValues(alpha: 0.5),
                  elevation: 8,
                ),
                child: busy
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Colors.white70,
                            ),
                          ),
                          SizedBox(width: 12),
                          Text('Waiting for permission…'),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(buttonIcon, size: 24),
                          const SizedBox(width: 8),
                          Text(buttonLabel),
                        ],
                      ),
              ),
            ),
            if (connectionState.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color:
                      (connected
                              ? const Color(0xFF4DE3C2)
                              : const Color(0xFFFFC857))
                          .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color:
                        (connected
                                ? const Color(0xFF4DE3C2)
                                : const Color(0xFFFFC857))
                            .withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      connected
                          ? Icons.check_circle_rounded
                          : Icons.hourglass_bottom_rounded,
                      size: 18,
                      color: connected
                          ? const Color(0xFF4DE3C2)
                          : const Color(0xFFFFC857),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        connectionState,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: connected
                              ? const Color(0xFFBFF3E6)
                              : const Color(0xFFFFE3A8),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSourceSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.tune_rounded,
          title: 'Audio source',
          subtitle: 'What should this phone send?',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _SourceCard(
                selected: mode == 'internal',
                enabled: !running && !waitingForPermission,
                icon: Icons.smartphone_rounded,
                title: 'Internal',
                subtitle: 'Music & video',
                badge: 'Android 10+',
                onTap: () => setState(() => mode = 'internal'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SourceCard(
                selected: mode == 'mic',
                enabled: !running && !waitingForPermission,
                icon: Icons.mic_rounded,
                title: 'Mic',
                subtitle: 'Voice & room',
                badge: 'Mic perm.',
                onTap: () => setState(() => mode = 'mic'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SourceCard(
                selected: mode == 'tone',
                enabled: !running && !waitingForPermission,
                icon: Icons.music_note_rounded,
                title: 'Test tone',
                subtitle: '440 Hz check',
                badge: 'No perm.',
                onTap: () => setState(() => mode = 'tone'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConnectionCard(ThemeData theme) {
    final host = hostController.text.trim();
    final isUsb = host == '127.0.0.1' || host == 'localhost';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(
              icon: Icons.laptop_mac_rounded,
              title: 'Laptop connection',
              subtitle: 'Where is the Rust receiver running?',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: hostController,
              enabled: !running && !waitingForPermission,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
              decoration: InputDecoration(
                labelText: 'Laptop IP  •  port 5000',
                labelStyle: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
                hintText: 'e.g. 192.168.1.10',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.30),
                ),
                prefixIcon: const Icon(
                  Icons.wifi_rounded,
                  color: Color(0xFF9D92FF),
                ),
                suffixIcon: host.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        onPressed: running || waitingForPermission
                            ? null
                            : () => _useQuickHost(''),
                        icon: const Icon(
                          Icons.clear_rounded,
                          size: 18,
                          color: Colors.white54,
                        ),
                      ),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-zA-Z.:]')),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _QuickChip(
                  icon: Icons.usb_rounded,
                  label: 'USB • 127.0.0.1',
                  selected: isUsb,
                  onTap: running || waitingForPermission
                      ? null
                      : () => _useQuickHost('127.0.0.1'),
                ),
                _QuickChip(
                  icon: Icons.wifi_rounded,
                  label: 'Wi-Fi • 192.168.1.x',
                  selected: !isUsb && host.isNotEmpty,
                  onTap: running || waitingForPermission
                      ? null
                      : () {
                          if (host.isEmpty || isUsb) {
                            _useQuickHost('192.168.1.');
                          }
                        },
                ),
                if (host.isNotEmpty)
                  _QuickChip(
                    icon: Icons.backspace_outlined,
                    label: 'Clear',
                    selected: false,
                    onTap: running || waitingForPermission
                        ? null
                        : () => _useQuickHost(''),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7CC4FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.terminal_rounded,
                      size: 18,
                      color: Color(0xFF7CC4FF),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'USB mode needs one command',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'adb reverse tcp:5000 tcp:5000',
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Copy adb command',
                    onPressed: _copyAdbCommand,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionsCard(ThemeData theme) {
    final internalOnly = mode == 'internal';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            SwitchListTile(
              value: mutePhone,
              onChanged: (running || waitingForPermission || !internalOnly)
                  ? null
                  : (v) => setState(() => mutePhone = v),
              secondary: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFB9A8FF).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.volume_off_rounded,
                  color: Color(0xFFB9A8FF),
                ),
              ),
              title: const Text(
                'Mute phone while streaming',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                  color: Colors.white,
                ),
              ),
              subtitle: Text(
                internalOnly
                    ? 'Listen on laptop headphones 🎧 • volume restored after'
                    : 'Only available for Internal audio',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Colors.white60,
                  height: 1.4,
                ),
              ),
              activeThumbColor: const Color(0xFF4DE3C2),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            _SectionTitle(
              icon: Icons.checklist_rounded,
              title: 'Get connected in 30s',
              subtitle: 'Three steps, then press Start.',
            ),
            SizedBox(height: 12),
            _StepTile(
              number: '1',
              title: 'Start the laptop receiver',
              body: 'Run  cargo run  on your laptop. It listens on :5000.',
              doneIcon: Icons.dns_rounded,
            ),
            _StepTile(
              number: '2',
              title: 'Point the phone at it',
              body: 'USB → 127.0.0.1 (+ adb reverse). Wi-Fi → laptop LAN IP.',
              doneIcon: Icons.smartphone_rounded,
            ),
            _StepTile(
              number: '3',
              title: 'Pick a source & stream',
              body:
                  'Internal needs “Start now” once. Plug earphones into laptop.',
              doneIcon: Icons.headphones_rounded,
              isLast: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 16, color: const Color(0xFF9D92FF)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  final bool selected;
  final bool enabled;
  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;
  final VoidCallback onTap;

  const _SourceCard({
    required this.selected,
    required this.enabled,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? const Color(0xFF8B7DFF)
        : Colors.white.withValues(alpha: 0.10);
    return Opacity(
      opacity: enabled ? 1.0 : 0.75,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF8B7DFF).withValues(alpha: 0.16)
                : const Color(0xFF141A30),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: selected ? 1.6 : 1.0),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFF8B7DFF).withValues(alpha: 0.30),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF8B7DFF)
                      : Colors.white.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 22, color: Colors.white),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.white60),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF4DE3C2).withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: selected ? const Color(0xFF4DE3C2) : Colors.white54,
                  ),
                ),
              ),
              if (selected) ...[
                const SizedBox(height: 8),
                const Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: Color(0xFF4DE3C2),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _QuickChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF8B7DFF).withValues(alpha: 0.20)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? const Color(0xFF8B7DFF).withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? const Color(0xFFB9A8FF) : Colors.white60,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseOrb extends StatelessWidget {
  final Animation<double> animation;
  final bool active;
  final bool connected;

  const _PulseOrb({
    required this.animation,
    required this.active,
    required this.connected,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = !active
        ? const Color(0xFF3A4160)
        : connected
        ? const Color(0xFF4DE3C2)
        : const Color(0xFFFFC857);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value;
        final scale = active ? 1.0 + 0.06 * math.sin(t * 2 * math.pi) : 1.0;
        return SizedBox(
          width: 92,
          height: 92,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (active)
                ...List.generate(2, (i) {
                  final progress = (t + i * 0.5) % 1.0;
                  return Container(
                    width: 88 * (0.55 + 0.45 * progress),
                    height: 88 * (0.55 + 0.45 * progress),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: baseColor.withValues(
                          alpha: (1 - progress) * 0.5,
                        ),
                        width: 1.6,
                      ),
                    ),
                  );
                }),
              Transform.scale(
                scale: scale,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: active
                          ? [baseColor, baseColor.withValues(alpha: 0.55)]
                          : [const Color(0xFF2A3252), const Color(0xFF1A2138)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: baseColor.withValues(
                          alpha: active ? 0.55 : 0.20,
                        ),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Icon(
                    !active
                        ? Icons.graphic_eq_rounded
                        : connected
                        ? Icons.graphic_eq_rounded
                        : Icons.wifi_find_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EqualizerBars extends StatelessWidget {
  final bool running;
  final double tick;

  const _EqualizerBars({required this.running, required this.tick});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(28, (i) {
        final double height;
        if (!running) {
          height = 5 + (i % 3 == 0 ? 4 : 2);
        } else {
          final wave = math.sin(tick * 2 * math.pi + i * 0.65) * 0.5 + 0.5;
          final wave2 = math.sin(tick * 2 * math.pi * 2 + i * 0.3) * 0.5 + 0.5;
          height = 6 + wave * 22 + wave2 * 8;
        }
        final isPeak = running && height > 24;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 5,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 2.2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: running
                  ? (isPeak
                        ? [const Color(0xFF4DE3C2), const Color(0xFF8B7DFF)]
                        : [
                            const Color(0xFF8B7DFF).withValues(alpha: 0.9),
                            const Color(0xFF8B7DFF).withValues(alpha: 0.35),
                          ])
                  : [
                      Colors.white.withValues(alpha: 0.18),
                      Colors.white.withValues(alpha: 0.08),
                    ],
            ),
          ),
        );
      }),
    );
  }
}

class _StepTile extends StatelessWidget {
  final String number;
  final String title;
  final String body;
  final IconData doneIcon;
  final bool isLast;

  const _StepTile({
    required this.number,
    required this.title,
    required this.body,
    required this.doneIcon,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF8B7DFF), Color(0xFF5B8CFF)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                number,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 26,
                margin: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(doneIcon, size: 20, color: Colors.white24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

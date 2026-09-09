import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';

class TouchpadRemoteScreen extends StatefulWidget {
  const TouchpadRemoteScreen({super.key});

  @override
  State<TouchpadRemoteScreen> createState() => _TouchpadRemoteScreenState();
}

class _TouchpadRemoteScreenState extends State<TouchpadRemoteScreen> {
  bool _gyroPointerActive = false;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final Map<int, Offset> _currentPointers = {};
  final Map<int, Offset> _startPointers = {};
  int _maxPointersInGesture = 0;
  bool _gestureMoved = false;
  DateTime? _gestureStartTime;
  bool _leftButtonDown = false;
  bool _rightButtonDown = false;
  double _smoothDx = 0.0;
  double _smoothDy = 0.0;
  double _accumX = 0.0;
  double _accumY = 0.0;

  // Double-tap and drag state (Mac/Windows precision trackpad style)
  DateTime? _lastTapUpTime;
  Offset? _lastTapUpPos;
  bool _isTapDragging = false;

  double _touchAccumX = 0.0;
  double _touchAccumY = 0.0;

  bool _ctrlActive = false;
  bool _altActive = false;
  bool _winActive = false;

  @override
  void dispose() {
    _gyroSub?.cancel();
    if (_leftButtonDown || _isTapDragging) {
      NexusFfiBridge.instance.sendTouchpadButton("Left", false);
    }
    if (_rightButtonDown) {
      NexusFfiBridge.instance.sendTouchpadButton("Right", false);
    }
    if (_ctrlActive) NexusFfiBridge.instance.sendKeyboardKey("Control", isDown: false);
    if (_altActive) NexusFfiBridge.instance.sendKeyboardKey("Alt", isDown: false);
    if (_winActive) NexusFfiBridge.instance.sendKeyboardKey("Win", isDown: false);
    super.dispose();
  }

  void _toggleGyro(bool active) {
    setState(() => _gyroPointerActive = active);
    _gyroSub?.cancel();
    _smoothDx = 0.0;
    _smoothDy = 0.0;
    _accumX = 0.0;
    _accumY = 0.0;
    if (active) {
      _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen((event) {
        final rawYaw = event.z.abs() < 0.015 ? 0.0 : -event.z;
        final rawPitch = event.x.abs() < 0.015 ? 0.0 : -event.x;

        const speed = 36.0;
        final targetDx = rawYaw * speed;
        final targetDy = rawPitch * speed;

        _smoothDx = _smoothDx * 0.55 + targetDx * 0.45;
        _smoothDy = _smoothDy * 0.55 + targetDy * 0.45;

        _accumX += _smoothDx;
        _accumY += _smoothDy;

        final stepX = _accumX.truncate();
        final stepY = _accumY.truncate();

        if (stepX != 0 || stepY != 0) {
          _accumX -= stepX;
          _accumY -= stepY;
          NexusFfiBridge.instance.sendTouchpadDelta("00000000-0000-0000-0000-000000000001", stepX, stepY);
        }
      });
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    _currentPointers[event.pointer] = event.position;
    _startPointers[event.pointer] = event.position;

    if (_currentPointers.length == 1) {
      final now = DateTime.now();

      // Check for Double-Tap-to-Drag: 2nd tap down within 480ms and 80px
      if (_lastTapUpTime != null && _lastTapUpPos != null) {
        final timeDiff = now.difference(_lastTapUpTime!).inMilliseconds;
        final distDiff = (event.position - _lastTapUpPos!).distance;
        if (timeDiff <= 480 && distDiff <= 80.0) {
          _isTapDragging = true;
          _touchAccumX = 0.0;
          _touchAccumY = 0.0;
          NexusFfiBridge.instance.sendTouchpadButton("Left", true);
          HapticFeedback.heavyImpact();
          _lastTapUpTime = null;
          _lastTapUpPos = null;
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('🖱️ Selezione Testo / Trascinamento Attivo (Tasto Sinistro Premuto)!'),
                backgroundColor: NexusTheme.accentIndigo,
                duration: Duration(milliseconds: 700),
              ),
            );
          }
        }
      }

      _gestureStartTime = now;
      _maxPointersInGesture = 1;
      _gestureMoved = false;
      _touchAccumX = 0.0;
      _touchAccumY = 0.0;
    } else {
      if (_isTapDragging) {
        _isTapDragging = false;
        NexusFfiBridge.instance.sendTouchpadButton("Left", false);
      }
      if (_currentPointers.length > _maxPointersInGesture) {
        _maxPointersInGesture = _currentPointers.length;
      }
    }
    setState(() {});
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _currentPointers[event.pointer] = event.position;

    final startPos = _startPointers[event.pointer];
    if (startPos != null) {
      final totalDist = (event.position - startPos).distance;
      if (totalDist > 12.0) {
        _gestureMoved = true;
      }
    }

    if (_currentPointers.length == 1) {
      _touchAccumX += event.delta.dx * 1.45;
      _touchAccumY += event.delta.dy * 1.45;
      final stepX = _touchAccumX.truncate();
      final stepY = _touchAccumY.truncate();
      if (stepX != 0 || stepY != 0) {
        _touchAccumX -= stepX;
        _touchAccumY -= stepY;
        NexusFfiBridge.instance.sendTouchpadDelta("00000000-0000-0000-0000-000000000001", stepX, stepY);
      }
    } else if (_currentPointers.length >= 2) {
      final dy = event.delta.dy.round();
      if (dy != 0) {
        NexusFfiBridge.instance.sendTouchpadScroll(dy);
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _currentPointers.remove(event.pointer);
    _startPointers.remove(event.pointer);

    if (_currentPointers.isEmpty) {
      final now = DateTime.now();
      final durationMs = _gestureStartTime != null ? now.difference(_gestureStartTime!).inMilliseconds : 1000;

      if (_isTapDragging) {
        _isTapDragging = false;
        NexusFfiBridge.instance.sendTouchpadButton("Left", false);
        HapticFeedback.lightImpact();
        _lastTapUpTime = null;
        _lastTapUpPos = null;
      } else {
        if (_maxPointersInGesture >= 2) {
          if (durationMs < 450) {
            NexusFfiBridge.instance.sendTouchpadClick("Right");
            HapticFeedback.mediumImpact();
            _lastTapUpTime = null;
            _lastTapUpPos = null;
            if (mounted) {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('🖱️ Click Destro (Tap a 2 dita) inviato al PC!'),
                  backgroundColor: NexusTheme.successGreen,
                  duration: Duration(milliseconds: 600),
                ),
              );
            }
          }
        } else if (_maxPointersInGesture == 1) {
          if (!_gestureMoved && durationMs < 350) {
            NexusFfiBridge.instance.sendTouchpadClick("Left");
            HapticFeedback.lightImpact();
            _lastTapUpTime = now;
            _lastTapUpPos = event.position;
          } else {
            _lastTapUpTime = null;
            _lastTapUpPos = null;
          }
        }
      }

      _maxPointersInGesture = 0;
      _gestureMoved = false;
      _gestureStartTime = null;
      setState(() {});
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _currentPointers.remove(event.pointer);
    _startPointers.remove(event.pointer);
    if (_currentPointers.isEmpty) {
      if (_isTapDragging) {
        _isTapDragging = false;
        NexusFfiBridge.instance.sendTouchpadButton("Left", false);
      }
      _lastTapUpTime = null;
      _lastTapUpPos = null;
      _maxPointersInGesture = 0;
      _gestureMoved = false;
      _gestureStartTime = null;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Magic Trackpad & Remote Input'),
        actions: [
          IconButton(
            icon: Icon(
              Icons.highlight_rounded,
              color: _gyroPointerActive ? NexusTheme.errorRed : NexusTheme.textTertiary,
            ),
            onPressed: () => _toggleGyro(!_gyroPointerActive),
            tooltip: 'Puntatore Laser Giroscopio (Air Mouse)',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Top System Key Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: NexusTheme.surfaceSecondary,
              border: Border(bottom: BorderSide(color: NexusTheme.borderSubtle)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildKeyButton('Esc'),
                _buildKeyButton('Tab'),
                _buildKeyButton('Ctrl'),
                _buildKeyButton('Alt'),
                _buildKeyButton('Win'),
                _buildKeyButton('⌨️'),
              ],
            ),
          ),

          // Magic Trackpad Surface
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _isTapDragging
                      ? NexusTheme.warningAmberMuted
                      : NexusTheme.surfaceCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isTapDragging
                        ? NexusTheme.warningAmber
                        : (_gyroPointerActive ? NexusTheme.errorRed.withAlpha(140) : NexusTheme.borderCard),
                    width: _isTapDragging || _gyroPointerActive ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(40),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_isTapDragging) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD97706),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.amber, width: 1.5),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.drag_indicator_rounded, color: Colors.white, size: 18),
                              SizedBox(width: 8),
                              Text(
                                'SELEZIONE TESTO / DRAG ATTIVO (Tasto SX Mantenuto)',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                      Icon(
                        _isTapDragging
                            ? Icons.open_with_rounded
                            : (_gyroPointerActive ? Icons.flare_rounded : Icons.touch_app_outlined),
                        size: 48,
                        color: _isTapDragging
                            ? NexusTheme.warningAmber
                            : (_gyroPointerActive ? NexusTheme.errorRed : NexusTheme.textTertiary),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isTapDragging
                            ? 'Trascina il dito per selezionare il testo o spostare l\'elemento sul PC!\nSolleva il dito per rilasciare.'
                            : (_gyroPointerActive
                                ? '🔴 Puntatore Laser Giroscopico Attivo\nMuovi o inclina il telefono per muovere il mouse!'
                                : 'Area Trackpad Multi-Touch Reattiva\n1 dito: Cursore • Tap: Click SX • Doppio tap + trascina: Seleziona\n2 dita tap: Click DX • 2 dita trascina: Scroll'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _isTapDragging
                              ? Colors.amber.shade100
                              : (_gyroPointerActive ? Colors.redAccent.shade100 : NexusTheme.textSecondary),
                          fontSize: 12.5,
                          height: 1.4,
                          fontWeight: _isTapDragging || _gyroPointerActive ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Physical Left / Right Click Buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) {
                      setState(() => _leftButtonDown = true);
                      NexusFfiBridge.instance.sendTouchpadButton("Left", true);
                      HapticFeedback.heavyImpact();
                    },
                    onPointerUp: (_) {
                      setState(() => _leftButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton("Left", false);
                      HapticFeedback.lightImpact();
                    },
                    onPointerCancel: (_) {
                      setState(() => _leftButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton("Left", false);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _leftButtonDown ? NexusTheme.successGreen : NexusTheme.surfaceSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _leftButtonDown ? NexusTheme.successGreen : NexusTheme.borderCard,
                          width: _leftButtonDown ? 2 : 1,
                        ),
                        boxShadow: _leftButtonDown
                            ? [
                                BoxShadow(
                                  color: NexusTheme.successGreen.withAlpha(140),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                )
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('🖱️', style: TextStyle(fontSize: 16)),
                          const SizedBox(width: 8),
                          Text(
                            _leftButtonDown ? 'CLICK SX (TENUTO 🟢)' : 'CLICK SX',
                            style: TextStyle(
                              color: _leftButtonDown ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) {
                      setState(() => _rightButtonDown = true);
                      NexusFfiBridge.instance.sendTouchpadButton("Right", true);
                      HapticFeedback.heavyImpact();
                    },
                    onPointerUp: (_) {
                      setState(() => _rightButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton("Right", false);
                      HapticFeedback.lightImpact();
                    },
                    onPointerCancel: (_) {
                      setState(() => _rightButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton("Right", false);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _rightButtonDown ? NexusTheme.accentIndigo : NexusTheme.surfaceSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _rightButtonDown ? const Color(0xFF818CF8) : NexusTheme.borderCard,
                          width: _rightButtonDown ? 2 : 1,
                        ),
                        boxShadow: _rightButtonDown
                            ? [
                                BoxShadow(
                                  color: NexusTheme.accentIndigo.withAlpha(140),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                )
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('⚡', style: TextStyle(fontSize: 16)),
                          const SizedBox(width: 8),
                          Text(
                            _rightButtonDown ? 'CLICK DX (TENUTO 🟣)' : 'CLICK DX',
                            style: TextStyle(
                              color: _rightButtonDown ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _leftButtonDown
                  ? '🟢 Tasto SX premuto: muovi il telefono col Giroscopio per selezionare testo o trascinare!'
                  : '💡 Tieni premuto CLICK SX + muovi il telefono (Giroscopio) per selezionare testo!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: _leftButtonDown ? NexusTheme.successGreen : NexusTheme.textTertiary,
                fontWeight: _leftButtonDown ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),

          // Bottom Quick Media & Volume Controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: NexusTheme.surfaceSecondary,
              border: Border(top: BorderSide(color: NexusTheme.borderSubtle)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton.filledTonal(
                  style: IconButton.styleFrom(backgroundColor: NexusTheme.surfaceCard),
                  onPressed: () => NexusFfiBridge.instance.sendMediaControl("SEEK", positionMs: 0),
                  icon: const Icon(Icons.skip_previous_rounded),
                  tooltip: 'Ricomincia Video',
                ),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: NexusTheme.accentIndigo),
                  onPressed: () {
                    NexusFfiBridge.instance.sendMediaControl("PAUSE");
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('⏸️ Comando PAUSA inviato al PC'), duration: Duration(milliseconds: 600)),
                    );
                  },
                  icon: const Icon(Icons.pause_rounded, size: 26),
                  tooltip: 'Pausa PC',
                ),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: NexusTheme.successGreen),
                  onPressed: () {
                    NexusFfiBridge.instance.sendMediaControl("PLAY");
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('▶️ Comando PLAY inviato al PC'), duration: Duration(milliseconds: 600)),
                    );
                  },
                  icon: const Icon(Icons.play_arrow_rounded, size: 26),
                  tooltip: 'Riprendi PC',
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  style: IconButton.styleFrom(backgroundColor: NexusTheme.surfaceCard),
                  onPressed: () => NexusFfiBridge.instance.setMasterVolume(0.5),
                  icon: const Icon(Icons.volume_down_rounded),
                ),
                IconButton.filledTonal(
                  style: IconButton.styleFrom(backgroundColor: NexusTheme.surfaceCard),
                  onPressed: () => NexusFfiBridge.instance.setMasterVolume(0.9),
                  icon: const Icon(Icons.volume_up_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyButton(String label) {
    final isModifier = label == 'Ctrl' || label == 'Alt' || label == 'Win';
    final isActive = (label == 'Ctrl' && _ctrlActive) ||
        (label == 'Alt' && _altActive) ||
        (label == 'Win' && _winActive);

    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: isActive ? NexusTheme.accentIndigo : NexusTheme.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
      ),
      onPressed: () {
        HapticFeedback.lightImpact();
        if (label == '⌨️') {
          _openRemoteKeyboardModal();
        } else if (isModifier) {
          setState(() {
            if (label == 'Ctrl') {
              _ctrlActive = !_ctrlActive;
              NexusFfiBridge.instance.sendKeyboardKey('Control', isDown: _ctrlActive);
            } else if (label == 'Alt') {
              _altActive = !_altActive;
              NexusFfiBridge.instance.sendKeyboardKey('Alt', isDown: _altActive);
            } else if (label == 'Win') {
              _winActive = !_winActive;
              NexusFfiBridge.instance.sendKeyboardKey('Win', isDown: _winActive);
            }
          });
        } else {
          NexusFfiBridge.instance.sendKeyboardKey(label);
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⌨️ Tasto $label inviato al PC'),
              duration: const Duration(milliseconds: 600),
              backgroundColor: NexusTheme.accentIndigo,
            ),
          );
        }
      },
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: isActive ? Colors.white : NexusTheme.textSecondary,
        ),
      ),
    );
  }

  void _openRemoteKeyboardModal() {
    final textCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: NexusTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.keyboard_rounded, color: NexusTheme.accentIndigo, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'Tastiera Remota & Macro PC',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20, color: NexusTheme.textSecondary),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Digita o incolla testo da inviare direttamente alla finestra attiva del computer:',
              style: TextStyle(color: NexusTheme.textSecondary, fontSize: 11),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: textCtrl,
                    autofocus: true,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Scrivi qui il testo da inviare al PC...',
                      hintStyle: const TextStyle(color: NexusTheme.textTertiary, fontSize: 12),
                      filled: true,
                      fillColor: NexusTheme.background,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: NexusTheme.borderCard),
                      ),
                    ),
                    onSubmitted: (text) {
                      if (text.isNotEmpty) {
                        NexusFfiBridge.instance.sendTextInput(text);
                        textCtrl.clear();
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('⌨️ Testo digitato su PC: $text'), duration: const Duration(seconds: 2)),
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () {
                    final text = textCtrl.text;
                    if (text.isNotEmpty) {
                      NexusFfiBridge.instance.sendTextInput(text);
                      textCtrl.clear();
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('⌨️ Testo digitato su PC: $text'), duration: const Duration(seconds: 2)),
                      );
                    }
                  },
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('Invia'),
                  style: FilledButton.styleFrom(
                    backgroundColor: NexusTheme.accentIndigo,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Macro Rapide & Scorciatoie:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: NexusTheme.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildMacroChip('Ctrl + C', ['Control', 'C'], 'Copia'),
                _buildMacroChip('Ctrl + V', ['Control', 'V'], 'Incolla'),
                _buildMacroChip('Ctrl + Z', ['Control', 'Z'], 'Annulla'),
                _buildMacroChip('Win + D', ['Win', 'D'], 'Desktop'),
                _buildMacroChip('Alt + Tab', ['Alt', 'Tab'], 'Cambia App'),
                _buildSingleKeyChip('Invio ↵', 'Enter'),
                _buildSingleKeyChip('Backspace ⌫', 'Backspace'),
                _buildSingleKeyChip('Canc ⌦', 'Delete'),
                _buildSingleKeyChip('Spazio ␣', 'Space'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMacroChip(String label, List<String> combo, String tooltip) {
    return ActionChip(
      backgroundColor: NexusTheme.accentIndigoMuted,
      side: BorderSide(color: NexusTheme.accentIndigo.withAlpha(120), width: 0.8),
      avatar: const Icon(Icons.flash_on_rounded, size: 14, color: Color(0xFF818CF8)),
      label: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
      tooltip: tooltip,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusPill)),
      onPressed: () {
        HapticFeedback.lightImpact();
        NexusFfiBridge.instance.sendKeyboardCombo(combo);
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚡ Macro eseguita: $label ($tooltip)'),
            duration: const Duration(milliseconds: 700),
            backgroundColor: NexusTheme.accentIndigo,
          ),
        );
      },
    );
  }

  Widget _buildSingleKeyChip(String label, String key) {
    return ActionChip(
      backgroundColor: NexusTheme.surfaceSecondary,
      side: BorderSide(color: NexusTheme.borderCard, width: 0.8),
      label: Text(label, style: const TextStyle(fontSize: 11, color: NexusTheme.textPrimary)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusPill)),
      onPressed: () {
        HapticFeedback.lightImpact();
        NexusFfiBridge.instance.sendKeyboardKey(key);
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⌨️ Tasto $label inviato'),
            duration: const Duration(milliseconds: 600),
            backgroundColor: NexusTheme.accentIndigo,
          ),
        );
      },
    );
  }
}

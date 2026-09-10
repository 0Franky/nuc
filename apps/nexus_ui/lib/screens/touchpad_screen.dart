import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../services/lan_sync_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import '../widgets/remote_keyboard_modal.dart';
import '../widgets/target_device_selector.dart';

class TouchpadRemoteScreen extends StatefulWidget {
  const TouchpadRemoteScreen({super.key});

  @override
  State<TouchpadRemoteScreen> createState() => _TouchpadRemoteScreenState();
}

class _TouchpadRemoteScreenState extends State<TouchpadRemoteScreen> {
  String? _heldTargetId;
  String? _gestureTargetId;
  String _lastSelectedTarget = '';
  String get _targetPeerId =>
      _gestureTargetId ??
      _heldTargetId ??
      LanSyncService.instance.touchpadTargetId;

  @override
  void initState() {
    super.initState();
    _lastSelectedTarget = LanSyncService.instance.touchpadTargetId;
    LanSyncService.instance.addListener(_targetChanged);
  }

  void _targetChanged() {
    final next = LanSyncService.instance.touchpadTargetId;
    if (next == _lastSelectedTarget) return;
    _lastSelectedTarget = next;
    _releaseHeldInputs();
    if (mounted) setState(() {});
  }

  void _pinHeldTarget() => _heldTargetId ??= _targetPeerId;

  void _releaseHeldInputs() {
    final target = _targetPeerId;
    final left = _leftButtonDown || _isTapDragging;
    final right = _rightButtonDown;
    final ctrl = _ctrlActive, alt = _altActive, win = _winActive;
    _heldTargetId = _gestureTargetId = null;
    _leftButtonDown = _rightButtonDown = _isTapDragging = false;
    _ctrlActive = _altActive = _winActive = false;
    _currentPointers.clear();
    _startPointers.clear();
    _lastTapUpTime = null;
    _lastTapUpPos = null;
    _maxPointersInGesture = 0;
    _gestureStartTime = null;
    _touchAccumX = _touchAccumY = 0;
    if (left) {
      NexusFfiBridge.instance.sendTouchpadButton(
        'Left',
        false,
        targetPeerId: target,
      );
    }
    if (right) {
      NexusFfiBridge.instance.sendTouchpadButton(
        'Right',
        false,
        targetPeerId: target,
      );
    }
    if (ctrl) {
      NexusFfiBridge.instance.sendKeyboardKey(
        'Control',
        isDown: false,
        targetPeerId: target,
      );
    }
    if (alt) {
      NexusFfiBridge.instance.sendKeyboardKey(
        'Alt',
        isDown: false,
        targetPeerId: target,
      );
    }
    if (win) {
      NexusFfiBridge.instance.sendKeyboardKey(
        'Win',
        isDown: false,
        targetPeerId: target,
      );
    }
  }

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
    LanSyncService.instance.removeListener(_targetChanged);
    _releaseHeldInputs();
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
      _gyroSub =
          gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
              .listen((event) {
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
                  NexusFfiBridge.instance.sendTouchpadDelta(
                    _targetPeerId,
                    stepX,
                    stepY,
                  );
                }
              });
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    _gestureTargetId ??= _targetPeerId;
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
          _pinHeldTarget();
          NexusFfiBridge.instance.sendTouchpadButton(
            "Left",
            true,
            targetPeerId: _targetPeerId,
          );
          HapticFeedback.heavyImpact();
          _lastTapUpTime = null;
          _lastTapUpPos = null;
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  '🖱️ Selezione Testo / Trascinamento Attivo (Tasto Sinistro Premuto)!',
                ),
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
        NexusFfiBridge.instance.sendTouchpadButton(
          "Left",
          false,
          targetPeerId: _targetPeerId,
        );
      }
      if (_currentPointers.length > _maxPointersInGesture) {
        _maxPointersInGesture = _currentPointers.length;
      }
    }
    setState(() {});
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_currentPointers.containsKey(event.pointer)) return;
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
        NexusFfiBridge.instance.sendTouchpadDelta(_targetPeerId, stepX, stepY);
      }
    } else if (_currentPointers.length >= 2) {
      final dy = event.delta.dy.round();
      if (dy != 0) {
        NexusFfiBridge.instance.sendTouchpadScroll(
          dy,
          targetPeerId: _targetPeerId,
        );
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (!_currentPointers.containsKey(event.pointer)) return;
    _currentPointers.remove(event.pointer);
    _startPointers.remove(event.pointer);

    if (_currentPointers.isEmpty) {
      final now = DateTime.now();
      final durationMs = _gestureStartTime != null
          ? now.difference(_gestureStartTime!).inMilliseconds
          : 1000;

      if (_isTapDragging) {
        _isTapDragging = false;
        NexusFfiBridge.instance.sendTouchpadButton(
          "Left",
          false,
          targetPeerId: _targetPeerId,
        );
        HapticFeedback.lightImpact();
        _lastTapUpTime = null;
        _lastTapUpPos = null;
      } else {
        if (_maxPointersInGesture >= 2) {
          if (durationMs < 450) {
            NexusFfiBridge.instance.sendTouchpadClick(
              "Right",
              targetPeerId: _targetPeerId,
            );
            HapticFeedback.mediumImpact();
            _lastTapUpTime = null;
            _lastTapUpPos = null;
            if (mounted) {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    '🖱️ Click Destro (Tap a 2 dita) inviato al PC!',
                  ),
                  backgroundColor: NexusTheme.successGreen,
                  duration: Duration(milliseconds: 600),
                ),
              );
            }
          }
        } else if (_maxPointersInGesture == 1) {
          if (!_gestureMoved && durationMs < 350) {
            NexusFfiBridge.instance.sendTouchpadClick(
              "Left",
              targetPeerId: _targetPeerId,
            );
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
      _gestureTargetId = null;
      setState(() {});
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (!_currentPointers.containsKey(event.pointer)) return;
    _currentPointers.remove(event.pointer);
    _startPointers.remove(event.pointer);
    if (_currentPointers.isEmpty) {
      if (_isTapDragging) {
        _isTapDragging = false;
        NexusFfiBridge.instance.sendTouchpadButton(
          "Left",
          false,
          targetPeerId: _targetPeerId,
        );
      }
      _lastTapUpTime = null;
      _lastTapUpPos = null;
      _maxPointersInGesture = 0;
      _gestureMoved = false;
      _gestureStartTime = null;
      _gestureTargetId = null;
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
              color: _gyroPointerActive
                  ? NexusTheme.errorRed
                  : NexusTheme.textTertiary,
            ),
            onPressed: () => _toggleGyro(!_gyroPointerActive),
            tooltip: 'Puntatore Laser Giroscopio (Air Mouse)',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Top Target PC Switcher Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: TargetDeviceSelector(
              selectedDeviceId: _targetPeerId,
              compact: true,
              filterType: 'Desktop',
              title: "Controllo PC Attivo",
              onDeviceSelected: (_) {
                setState(() {});
              },
            ),
          ),

          ListenableBuilder(
            listenable: LanSyncService.instance,
            builder: (context, _) {
              final error = LanSyncService.instance.inputErrorFor(
                _targetPeerId,
              );
              if (error == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                child: Text(
                  error,
                  style: const TextStyle(color: NexusTheme.errorRed),
                ),
              );
            },
          ),

          // Top System Key Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: NexusTheme.surfaceSecondary,
              border: Border(
                bottom: BorderSide(color: NexusTheme.borderSubtle),
              ),
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
                margin: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _isTapDragging
                      ? NexusTheme.warningAmberMuted
                      : NexusTheme.surfaceCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isTapDragging
                        ? NexusTheme.warningAmber
                        : (_gyroPointerActive
                              ? NexusTheme.errorRed.withAlpha(140)
                              : NexusTheme.borderCard),
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD97706),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.amber, width: 1.5),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.drag_indicator_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'SELEZIONE TESTO / DRAG ATTIVO (Tasto SX Mantenuto)',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      Icon(
                        _isTapDragging
                            ? Icons.open_with_rounded
                            : (_gyroPointerActive
                                  ? Icons.flare_rounded
                                  : Icons.touch_app_outlined),
                        size: 48,
                        color: _isTapDragging
                            ? NexusTheme.warningAmber
                            : (_gyroPointerActive
                                  ? NexusTheme.errorRed
                                  : NexusTheme.textTertiary),
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
                              : (_gyroPointerActive
                                    ? Colors.redAccent.shade100
                                    : NexusTheme.textSecondary),
                          fontSize: 12.5,
                          height: 1.4,
                          fontWeight: _isTapDragging || _gyroPointerActive
                              ? FontWeight.bold
                              : FontWeight.normal,
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
                      _pinHeldTarget();
                      NexusFfiBridge.instance.sendTouchpadButton(
                        "Left",
                        true,
                        targetPeerId: _targetPeerId,
                      );
                      HapticFeedback.heavyImpact();
                    },
                    onPointerUp: (_) {
                      if (!_leftButtonDown) return;
                      setState(() => _leftButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton(
                        "Left",
                        false,
                        targetPeerId: _targetPeerId,
                      );
                      HapticFeedback.lightImpact();
                    },
                    onPointerCancel: (_) {
                      if (!_leftButtonDown) return;
                      setState(() => _leftButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton(
                        "Left",
                        false,
                        targetPeerId: _targetPeerId,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _leftButtonDown
                            ? NexusTheme.successGreen
                            : NexusTheme.surfaceSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _leftButtonDown
                              ? NexusTheme.successGreen
                              : NexusTheme.borderCard,
                          width: _leftButtonDown ? 2 : 1,
                        ),
                        boxShadow: _leftButtonDown
                            ? [
                                BoxShadow(
                                  color: NexusTheme.successGreen.withAlpha(140),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('🖱️', style: TextStyle(fontSize: 16)),
                          const SizedBox(width: 8),
                          Text(
                            _leftButtonDown
                                ? 'CLICK SX (TENUTO 🟢)'
                                : 'CLICK SX',
                            style: TextStyle(
                              color: _leftButtonDown
                                  ? Colors.black
                                  : Colors.white,
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
                      _pinHeldTarget();
                      NexusFfiBridge.instance.sendTouchpadButton(
                        "Right",
                        true,
                        targetPeerId: _targetPeerId,
                      );
                      HapticFeedback.heavyImpact();
                    },
                    onPointerUp: (_) {
                      if (!_rightButtonDown) return;
                      setState(() => _rightButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton(
                        "Right",
                        false,
                        targetPeerId: _targetPeerId,
                      );
                      HapticFeedback.lightImpact();
                    },
                    onPointerCancel: (_) {
                      if (!_rightButtonDown) return;
                      setState(() => _rightButtonDown = false);
                      NexusFfiBridge.instance.sendTouchpadButton(
                        "Right",
                        false,
                        targetPeerId: _targetPeerId,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _rightButtonDown
                            ? NexusTheme.accentIndigo
                            : NexusTheme.surfaceSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _rightButtonDown
                              ? const Color(0xFF818CF8)
                              : NexusTheme.borderCard,
                          width: _rightButtonDown ? 2 : 1,
                        ),
                        boxShadow: _rightButtonDown
                            ? [
                                BoxShadow(
                                  color: NexusTheme.accentIndigo.withAlpha(140),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('⚡', style: TextStyle(fontSize: 16)),
                          const SizedBox(width: 8),
                          Text(
                            _rightButtonDown
                                ? 'CLICK DX (TENUTO 🟣)'
                                : 'CLICK DX',
                            style: TextStyle(
                              color: _rightButtonDown
                                  ? Colors.black
                                  : Colors.white,
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
                color: _leftButtonDown
                    ? NexusTheme.successGreen
                    : NexusTheme.textTertiary,
                fontWeight: _leftButtonDown
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyButton(String label) {
    final isModifier = label == 'Ctrl' || label == 'Alt' || label == 'Win';
    final isActive =
        (label == 'Ctrl' && _ctrlActive) ||
        (label == 'Alt' && _altActive) ||
        (label == 'Win' && _winActive);

    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: isActive
            ? NexusTheme.accentIndigo
            : NexusTheme.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
      ),
      onPressed: () {
        HapticFeedback.lightImpact();
        if (label == '⌨️') {
          RemoteKeyboardModal.show(context);
        } else if (isModifier) {
          setState(() {
            if (label == 'Ctrl') {
              _ctrlActive = !_ctrlActive;
              if (_ctrlActive) _pinHeldTarget();
              NexusFfiBridge.instance.sendKeyboardKey(
                'Control',
                isDown: _ctrlActive,
                targetPeerId: _targetPeerId,
              );
            } else if (label == 'Alt') {
              _altActive = !_altActive;
              if (_altActive) _pinHeldTarget();
              NexusFfiBridge.instance.sendKeyboardKey(
                'Alt',
                isDown: _altActive,
                targetPeerId: _targetPeerId,
              );
            } else if (label == 'Win') {
              _winActive = !_winActive;
              if (_winActive) _pinHeldTarget();
              NexusFfiBridge.instance.sendKeyboardKey(
                'Win',
                isDown: _winActive,
                targetPeerId: _targetPeerId,
              );
            }
          });
        } else {
          NexusFfiBridge.instance.sendKeyboardKey(
            label,
            targetPeerId: _targetPeerId,
          );
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          final targetName = LanSyncService.instance.targetDeviceDisplayName;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⌨️ Tasto $label inviato al PC ($targetName)'),
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
}

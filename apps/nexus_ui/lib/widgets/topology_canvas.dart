import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'spatial_grid_painter.dart';

/// The viewport is shared-coordinate based and stays still until explicitly fitted.
class TopologyCanvas extends StatefulWidget {
  const TopologyCanvas({
    super.key,
    required this.points,
    required this.names,
    required this.localId,
    required this.onMove,
    required this.onDragging,
  });
  final Map<String, Offset> points;
  final Map<String, String> names;
  final String localId;
  final void Function(String, Offset) onMove;
  final ValueChanged<bool> onDragging;
  @override
  State<TopologyCanvas> createState() => _TopologyCanvasState();
}

class _TopologyCanvasState extends State<TopologyCanvas> {
  Size? _size;
  Offset _origin = Offset.zero;
  double _scale = 1;
  String? _active;
  int? _pointer;
  Offset _down = Offset.zero;
  Offset _start = Offset.zero;
  Offset? _preview;

  @override
  void didUpdateWidget(covariant TopologyCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_active == null &&
        !widget.points.keys.toSet().containsAll(oldWidget.points.keys)) {
      _size = null;
    }
    if (_active == null &&
        !oldWidget.points.keys.toSet().containsAll(widget.points.keys)) {
      _size = null;
    }
  }

  void _fit(Size size) {
    _size = size;
    final points = widget.points.values;
    if (points.isEmpty) return;
    var bounds = Rect.fromPoints(points.first, points.first);
    for (final point in points) {
      bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
    }
    _scale = math.min(
      1,
      math.min(
        math.max(1, size.width - 120) / math.max(1, bounds.width),
        math.max(1, size.height - 140) / math.max(1, bounds.height),
      ),
    );
    _origin = size.center(Offset.zero) - bounds.center * _scale;
  }

  void _finish({bool cancel = false}) {
    final id = _active;
    final point = _preview;
    _active = null;
    _pointer = null;
    _preview = null;
    widget.onDragging(false);
    if (!cancel && id != null && point != null && point != _start) {
      widget.onMove(id, point);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 300,
    key: const ValueKey('topology-canvas'),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_size != size && _active == null) _fit(size);
        final ids = widget.points.keys.toList()..sort();
        if (_active != null) {
          ids.remove(_active);
          ids.add(_active!);
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: CustomPaint(painter: const SpatialGridPainter()),
              ),
              for (final id in ids) _node(id, size),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  tooltip: 'Inquadra tutti i dispositivi',
                  onPressed: _active == null
                      ? () => setState(() => _fit(size))
                      : null,
                  icon: const Icon(Icons.fit_screen, color: Colors.white70),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget _node(String id, Size size) {
    final point = id == _active ? _preview! : widget.points[id]!;
    final screen = _origin + point * _scale;
    final local = id == widget.localId;
    return Positioned(
      key: ValueKey(id),
      left: screen.dx - 48,
      top: screen.dy - 36,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Listener(
          onPointerDown: (e) {
            if (_pointer != null || (e.buttons & kPrimaryButton) == 0) return;
            _pointer = e.pointer;
            _active = id;
            _down = e.position;
            _start = widget.points[id]!;
            _preview = _start;
            widget.onDragging(true);
            setState(() {});
          },
          onPointerMove: (e) {
            if (e.pointer != _pointer) return;
            final screen = _origin + _start * _scale + e.position - _down;
            final clamped = Offset(
              screen.dx.clamp(48, math.max(48, size.width - 48)),
              screen.dy.clamp(36, math.max(36, size.height - 36)),
            );
            setState(() => _preview = (clamped - _origin) / _scale);
          },
          onPointerUp: (e) {
            if (e.pointer == _pointer) _finish();
          },
          onPointerCancel: (e) {
            if (e.pointer == _pointer) _finish(cancel: true);
          },
          child: RawGestureDetector(
            key: ValueKey('topology-peer-$id'),
            behavior: HitTestBehavior.opaque,
            gestures: {
              EagerGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                    EagerGestureRecognizer.new,
                    (_) {},
                  ),
            },
            child: Container(
              width: 96,
              height: 72,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: local
                    ? const Color(0xFF3730A3)
                    : const Color(0xFF334155),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: local ? Colors.indigoAccent : Colors.blueGrey,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.names[id] ?? id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Text(
                    local ? 'Questo dispositivo' : 'Trascina',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                  const Icon(Icons.open_with, color: Colors.white70, size: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

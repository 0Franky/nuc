import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
  // D 116: anche il nodo attivo vive in un notifier: il cambio dell'attivo
  // ridisegna solo gli slot interessati, non l'intero canvas.
  final ValueNotifier<String?> _activeNotifier = ValueNotifier(null);
  String? get _active => _activeNotifier.value;
  set _active(String? value) => _activeNotifier.value = value;
  int? _pointer;
  Offset _down = Offset.zero;
  Offset _start = Offset.zero;
  // D 116: la posizione del nodo attivo vive in un notifier, cosi' il
  // pointer move ricostruisce solo il nodo trascinato e non tutto il canvas.
  final ValueNotifier<Offset?> _previewNotifier = ValueNotifier(null);
  Offset? get _preview => _previewNotifier.value;
  set _preview(Offset? value) => _previewNotifier.value = value;
  // Distanza massima (px schermo) percorsa dal puntatore nel drag corrente.
  double _travel = 0;
  // D 114: scala adattiva con minimo reale. I nodi hanno dimensione
  // costante (96x72): sotto questa soglia le distanze verrebbero compresse
  // fino a sovrapporre i nodi, rendendoli difficili da afferrare.
  static const double _minScale = 0.25;
  // Soglia (px schermo) sotto la quale il rilascio non produce onMove.
  double _slop = kTouchSlop;
  // L'insieme dei peer e' cambiato durante un drag: refit a fine drag.
  bool _needsFit = false;
  // Posizione rilasciata, mostrata finche' il genitore non aggiorna points.
  String? _pendingId;
  Offset? _pendingPoint;
  Timer? _pendingTimer;

  @override
  void didUpdateWidget(covariant TopologyCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pendingId;
    if (pending != null &&
        widget.points[pending] != oldWidget.points[pending]) {
      _clearPending();
    }
    final active = _active;
    if (active != null && !widget.points.containsKey(active)) {
      // Il peer trascinato non esiste piu': annulla il drag senza onMove.
      _active = null;
      _pointer = null;
      _preview = null;
      _needsFit = false;
      _size = null;
      final onDragging = widget.onDragging;
      Future.microtask(() => onDragging(false));
    }
    if (!setEquals(oldWidget.points.keys.toSet(), widget.points.keys.toSet())) {
      if (_active == null) {
        _size = null;
      } else {
        _needsFit = true;
      }
    }
  }

  void _clearPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingId = null;
    _pendingPoint = null;
  }

  void _setPending(String id, Offset point) {
    _pendingTimer?.cancel();
    _pendingId = id;
    _pendingPoint = point;
    _pendingTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(_clearPending);
    });
  }

  Offset _displayed(String id) => id == _active
      ? _preview!
      : (id == _pendingId ? _pendingPoint! : widget.points[id]!);

  @override
  void dispose() {
    _pendingTimer?.cancel();
    // Se il widget viene smontato durante un trascinamento, il genitore
    // resterebbe bloccato in stato "dragging". Lo notifichiamo fuori dalla
    // fase di finalizzazione dell'albero (dove setState non e' ammesso).
    if (_active != null) {
      _active = null;
      _pointer = null;
      _preview = null;
      final onDragging = widget.onDragging;
      Future.microtask(() => onDragging(false));
    }
    _previewNotifier.dispose();
    _activeNotifier.dispose();
    super.dispose();
  }

  void _fit(Size size) {
    _size = size;
    final points = widget.points.values;
    if (points.isEmpty) return;
    var bounds = Rect.fromPoints(points.first, points.first);
    for (final point in points) {
      bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
    }
    _scale = math.max(
      _minScale,
      math.min(
        1,
        math.min(
          math.max(1, size.width - 120) / math.max(1, bounds.width),
          math.max(1, size.height - 140) / math.max(1, bounds.height),
        ),
      ),
    );
    _origin = size.center(Offset.zero) - bounds.center * _scale;
  }

  void _finish({bool cancel = false}) {
    final id = _active;
    final point = _preview;
    _pointer = null;
    final moved = !cancel &&
        id != null &&
        point != null &&
        _travel > _slop &&
        ((point - _start) * _scale).distance > _slop;
    // Il pending va impostato prima di azzerare l'attivo: lo slot che si
    // ridisegna mostra subito la posizione rilasciata.
    if (moved) _setPending(id, point);
    _active = null;
    _preview = null;
    widget.onDragging(false);
    if (moved) widget.onMove(id, point);
    if (_needsFit) {
      _needsFit = false;
      _size = null;
      if (mounted) setState(() {});
    }
  }

  // Spostamento accessibile (azioni semantiche), in pixel schermo.
  void _nudge(String id, Offset screenDelta) {
    if (_active != null || !widget.points.containsKey(id)) return;
    final base = id == _pendingId ? _pendingPoint! : widget.points[id]!;
    final point = base + screenDelta / _scale;
    _setPending(id, point);
    widget.onMove(id, point);
    setState(() {});
  }

  Widget _semantics(String id, Widget child) {
    const step = 40.0;
    return Semantics(
      label: widget.names[id] ?? id,
      hint: 'Dispositivo spostabile',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Sposta a sinistra'): () =>
            _nudge(id, const Offset(-step, 0)),
        const CustomSemanticsAction(label: 'Sposta a destra'): () =>
            _nudge(id, const Offset(step, 0)),
        const CustomSemanticsAction(label: 'Sposta in alto'): () =>
            _nudge(id, const Offset(0, -step)),
        const CustomSemanticsAction(label: 'Sposta in basso'): () =>
            _nudge(id, const Offset(0, step)),
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 300,
    key: const ValueKey('topology-canvas'),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Con vincoli non limitati (es. in una Row senza Expanded) usa una
        // dimensione finita, altrimenti _origin diventerebbe infinito.
        final size = Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : 600,
          constraints.hasBoundedHeight ? constraints.maxHeight : 300,
        );
        if (_size != size && _active == null) _fit(size);
        final ids = widget.points.keys.toList()..sort();
        // D 116: slot e griglia sono istanze create una volta per build del
        // canvas; al cambio dell'attivo si riordina solo lo Stack e gli slot
        // non coinvolti restituiscono il widget gia' costruito.
        final slots = <String, Widget>{
          for (final id in ids) id: _slot(id, size),
        };
        final grid = Positioned.fill(
          child: CustomPaint(painter: const SpatialGridPainter()),
        );
        return SizedBox.fromSize(
          size: size,
          child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ValueListenableBuilder<String?>(
            valueListenable: _activeNotifier,
            builder: (context, active, _) {
              final order = [...ids];
              if (active != null && order.remove(active)) order.add(active);
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  grid,
                  for (final id in order) slots[id]!,
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      tooltip: 'Inquadra tutti i dispositivi',
                      onPressed: active == null
                          ? () => setState(() => _fit(size))
                          : null,
                      icon: const Icon(Icons.fit_screen, color: Colors.white70),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        );
      },
    ),
  );

  // D 116: uno slot ascolta l'attivo e, solo se e' il proprio nodo, anche la
  // preview; altrimenti riusa il nodo costruito dal canvas (stessa istanza).
  Widget _slot(String id, Size size) {
    final idle = id == _active ? null : _node(id, size);
    return ValueListenableBuilder<String?>(
      key: ValueKey('topology-slot-$id'),
      valueListenable: _activeNotifier,
      builder: (context, active, _) {
        final still = active == id
            ? null
            : (id == _pendingId || idle == null ? _node(id, size) : idle);
        return ValueListenableBuilder<Offset?>(
          valueListenable: _previewNotifier,
          child: still,
          builder: (context, _, child) => child ?? _node(id, size),
        );
      },
    );
  }

  // D 114: con la scala minima un layout molto esteso puo' superare l'area;
  // il limite ai bordi tiene comunque ogni nodo visibile e afferrabile.
  Offset _toScreen(Offset point, Size size) {
    final raw = _origin + point * _scale;
    return Offset(
      raw.dx.clamp(48.0, math.max(48.0, size.width - 48)),
      raw.dy.clamp(36.0, math.max(36.0, size.height - 36)),
    );
  }

  Widget _node(String id, Size size) {
    final point = _displayed(id);
    final screen = _toScreen(point, size);
    final local = id == widget.localId;
    return Positioned(
      key: ValueKey(id),
      left: screen.dx - 48,
      top: screen.dy - 36,
      child: _semantics(
        id,
        MouseRegion(
        cursor: id == _active
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        child: Listener(
          onPointerDown: (e) {
            if (_pointer != null || (e.buttons & kPrimaryButton) == 0) return;
            _pointer = e.pointer;
            _active = id;
            _down = e.position;
            _start = id == _pendingId ? _pendingPoint! : widget.points[id]!;
            _slop = computeHitSlop(e.kind, null);
            _preview = _start;
            _travel = 0;
            widget.onDragging(true);
          },
          onPointerMove: (e) {
            if (e.pointer != _pointer) return;
            _travel = math.max(_travel, (e.position - _down).distance);
            final screen = _toScreen(_start, size) + e.position - _down;
            final clamped = Offset(
              screen.dx.clamp(48, math.max(48, size.width - 48)),
              screen.dy.clamp(36, math.max(36, size.height - 36)),
            );
            _preview = (clamped - _origin) / _scale;
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
                    () => EagerGestureRecognizer(
                      allowedButtonsFilter: (buttons) =>
                          buttons == kPrimaryButton,
                    ),
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
      ),
    );
  }
}

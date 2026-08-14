import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum _CanvasTool { pen, eraser, arrow, circle, triangle, text, select }

class _Mark {
  _Mark({
    required this.tool,
    required this.points,
    required this.color,
    this.text = '',
    this.width = 5,
  });

  _CanvasTool tool;
  List<Offset> points;
  Color color;
  String text;
  double width;

  _Mark copy() => _Mark(
        tool: tool,
        points: List<Offset>.of(points),
        color: color,
        text: text,
        width: width,
      );
}

class CanvasEditorDialog extends StatefulWidget {
  const CanvasEditorDialog({required this.imagePath, super.key});

  final String imagePath;

  @override
  State<CanvasEditorDialog> createState() => _CanvasEditorDialogState();
}

class _CanvasEditorDialogState extends State<CanvasEditorDialog> {
  ui.Image? image;
  final List<_Mark> marks = <_Mark>[];
  final List<_Mark> undo = <_Mark>[];
  _CanvasTool tool = _CanvasTool.pen;
  Color color = Colors.red;
  int? selected;
  _Mark? clipboard;
  Offset? start;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final decoded = await completer.future;
    if (mounted) setState(() => image = decoded);
  }

  Offset _normal(Offset point, Size size) => Offset(
        (point.dx / size.width).clamp(0, 1),
        (point.dy / size.height).clamp(0, 1),
      );

  Offset _canvasPoint(Offset point, Size size) =>
      Offset(point.dx * size.width, point.dy * size.height);

  void _start(DragStartDetails details, Size size) {
    final point = _normal(details.localPosition, size);
    start = point;
    if (tool == _CanvasTool.select) {
      selected = _find(point, size);
      setState(() {});
      return;
    }
    if (tool == _CanvasTool.eraser) {
      _erase(point, size);
      return;
    }
    if (tool == _CanvasTool.text) return;
    setState(() {
      undo.addAll(marks.map((mark) => mark.copy()));
      marks.add(_Mark(tool: tool, points: <Offset>[point], color: color));
    });
  }

  void _update(DragUpdateDetails details, Size size) {
    final point = _normal(details.localPosition, size);
    if (tool == _CanvasTool.eraser) {
      _erase(point, size);
      return;
    }
    if (tool == _CanvasTool.pen && marks.isNotEmpty) {
      setState(() => marks.last.points.add(point));
    } else if (tool == _CanvasTool.arrow ||
        tool == _CanvasTool.circle ||
        tool == _CanvasTool.triangle) {
      setState(() => marks.last.points = <Offset>[start!, point]);
    }
  }

  void _end(DragEndDetails details, Size size) {
    if (tool == _CanvasTool.eraser || tool == _CanvasTool.select) return;
    if (tool == _CanvasTool.text && start != null) _addText(start!, size);
    start = null;
  }

  int? _find(Offset point, Size size) {
    final target = _canvasPoint(point, size);
    for (var index = marks.length - 1; index >= 0; index--) {
      final mark = marks[index];
      final points = mark.points.map((value) => _canvasPoint(value, size)).toList();
      final tolerance = math.max(18.0, mark.width + 12);
      if (points.length == 1 && (points.first - target).distance < tolerance) {
        return index;
      }
      for (var pointIndex = 1; pointIndex < points.length; pointIndex++) {
        if (_distanceToSegment(target, points[pointIndex - 1], points[pointIndex]) < tolerance) {
          return index;
        }
      }
      if ((mark.tool == _CanvasTool.circle || mark.tool == _CanvasTool.triangle) && points.length > 1) {
        if (_distanceToSegment(target, points.last, points.first) < tolerance) return index;
      }
    }
    return null;
  }

  double _distanceToSegment(Offset point, Offset start, Offset end) {
    final direction = end - start;
    final lengthSquared = direction.dx * direction.dx + direction.dy * direction.dy;
    if (lengthSquared == 0) return (point - start).distance;
    final projection = ((point.dx - start.dx) * direction.dx + (point.dy - start.dy) * direction.dy) / lengthSquared;
    final t = projection.clamp(0.0, 1.0);
    final closest = Offset(start.dx + direction.dx * t, start.dy + direction.dy * t);
    return (point - closest).distance;
  }

  void _erase(Offset point, Size size) {
    final found = _find(point, size);
    if (found != null) setState(() => marks.removeAt(found));
  }

  Future<void> _addText(Offset point, Size size) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Text einfügen'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Text'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Einfügen')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null || value.trim().isEmpty) return;
    setState(() {
      undo.addAll(marks.map((mark) => mark.copy()));
      marks.add(_Mark(tool: _CanvasTool.text, points: <Offset>[point], color: color, text: value.trim()));
    });
  }

  void _copy() {
    if (selected != null && selected! < marks.length) clipboard = marks[selected!].copy();
  }

  void _paste() {
    final item = clipboard?.copy();
    if (item == null) return;
    setState(() {
      item.points = item.points.map((point) => Offset((point.dx + .04).clamp(0, 1), (point.dy + .04).clamp(0, 1))).toList();
      marks.add(item);
      selected = marks.length - 1;
    });
  }

  Future<void> _save() async {
    final source = image;
    if (source == null) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(source.width.toDouble(), source.height.toDouble());
    canvas.drawImage(source, Offset.zero, Paint());
    _AnnotationPainter(marks, source).paint(canvas, size);
    final rendered = await recorder.endRecording().toImage(source.width, source.height);
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) await File(widget.imagePath).writeAsBytes(data.buffer.asUint8List());
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final source = image;
    if (source == null) {
      return const Dialog(child: SizedBox(width: 500, height: 300, child: Center(child: CircularProgressIndicator())));
    }
    final ratio = source.width / source.height;
    return Dialog(
      child: SizedBox(
        width: 1000,
        height: 760,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: <Widget>[
              Row(children: <Widget>[
                const Expanded(child: Text('Bild bearbeiten', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                IconButton(onPressed: marks.isEmpty ? null : () => setState(() { marks.removeLast(); }), icon: const Icon(Icons.undo)),
                IconButton(onPressed: _copy, icon: const Icon(Icons.copy)),
                IconButton(onPressed: _paste, icon: const Icon(Icons.content_paste)),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: <Widget>[
                _tool(Icons.brush, _CanvasTool.pen, 'Stift'),
                _tool(Icons.auto_fix_normal, _CanvasTool.eraser, 'Radierer'),
                _tool(Icons.arrow_forward, _CanvasTool.arrow, 'Pfeil'),
                _tool(Icons.circle_outlined, _CanvasTool.circle, 'Kreis'),
                _tool(Icons.change_history, _CanvasTool.triangle, 'Dreieck'),
                _tool(Icons.text_fields, _CanvasTool.text, 'Text'),
                _tool(Icons.ads_click, _CanvasTool.select, 'Markieren'),
                for (final value in <Color>[Colors.red, Colors.yellow, Colors.green, Colors.blue, Colors.white, Colors.black])
                  IconButton(onPressed: () => setState(() => color = value), icon: Icon(Icons.circle, color: value)),
              ]),
              const SizedBox(height: 12),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: ratio,
                    child: LayoutBuilder(builder: (context, constraints) {
                      final size = Size(constraints.maxWidth, constraints.maxHeight);
                      return GestureDetector(
                        onPanStart: (details) => _start(details, size),
                        onPanUpdate: (details) => _update(details, size),
                        onPanEnd: (details) => _end(details, size),
                        onTapUp: (details) {
                          final point = _normal(details.localPosition, size);
                          if (tool == _CanvasTool.select) {
                            setState(() => selected = _find(point, size));
                          } else if (tool == _CanvasTool.text) {
                            _addText(point, size);
                          }
                        },
                        child: CustomPaint(painter: _AnnotationPainter(marks, source, selected: selected)),
                      );
                    }),
                  ),
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
                const SizedBox(width: 8),
                ElevatedButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Übernehmen')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tool(IconData icon, _CanvasTool value, String label) => Tooltip(
        message: label,
        child: IconButton(onPressed: () => setState(() => tool = value), color: tool == value ? Colors.orange : null, icon: Icon(icon)),
      );
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter(this.marks, this.image, {this.selected});
  final List<_Mark> marks;
  final ui.Image image;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), Offset.zero & size, Paint());
    for (var index = 0; index < marks.length; index++) _drawMark(canvas, size, marks[index], index == selected);
  }

  void _drawMark(Canvas canvas, Size size, _Mark mark, bool highlight) {
    if (mark.points.isEmpty) return;
    final points = mark.points.map((point) => Offset(point.dx * size.width, point.dy * size.height)).toList();
    final paint = Paint()..color = mark.color..style = PaintingStyle.stroke..strokeWidth = mark.width..strokeCap = StrokeCap.round;
    if (highlight) paint.color = Colors.orange;
    if (mark.tool == _CanvasTool.pen) {
      canvas.drawPoints(ui.PointMode.polygon, points, paint);
    } else if (mark.tool == _CanvasTool.arrow && points.length > 1) {
      canvas.drawLine(points.first, points.last, paint);
      final direction = points.last - points.first;
      final angle = direction.direction;
      final head = Path()
        ..moveTo(points.last.dx - 18 * math.cos(angle - .5), points.last.dy - 18 * math.sin(angle - .5))
        ..lineTo(points.last.dx, points.last.dy)
        ..lineTo(points.last.dx - 18 * math.cos(angle + .5), points.last.dy - 18 * math.sin(angle + .5));
      canvas.drawPath(head, paint);
    } else if (mark.tool == _CanvasTool.circle && points.length > 1) {
      canvas.drawOval(Rect.fromPoints(points.first, points.last), paint);
    } else if (mark.tool == _CanvasTool.triangle && points.length > 1) {
      final rect = Rect.fromPoints(points.first, points.last);
      final path = Path()..moveTo(rect.center.dx, rect.top)..lineTo(rect.right, rect.bottom)..lineTo(rect.left, rect.bottom)..close();
      canvas.drawPath(path, paint);
    } else if (mark.tool == _CanvasTool.text) {
      TextPainter(text: TextSpan(text: mark.text, style: TextStyle(color: mark.color, fontSize: size.width / 32, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout(maxWidth: size.width * .8)..paint(canvas, points.first);
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => true;
}
